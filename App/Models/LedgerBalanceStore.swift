import CoreData
import Foundation
import SwiftData
import FinanceCore

/// One signed movement on an account — the cached equivalent of one row in
/// `account.transactions` or `account.incomingTransfers`. Keeping `kind`,
/// `isSource` and `amount` lets every derived view (balance, card entries,
/// receivable FIFO, delete-eligibility) reproduce the old per-relationship
/// numbers exactly, including self-transfers.
struct LedgerAccountEntry: Equatable, Sendable {
    let transactionID: UUID
    let date: Date
    let kind: TransactionKind
    /// True when the account is the transaction's source (`account`),
    /// false when it is the transfer destination (`toAccount`).
    let isSource: Bool
    /// Positive magnitude in đồng.
    let amount: Int64
    /// `LedgerMath.delta` for this account's role — the value balances use.
    let delta: Int64
}

/// Everything the ledger can say about every account, computed in one pass
/// over the transaction table. `movements` keeps every role entry (a
/// self-transfer touches the account twice, like the old two-relationship
/// walks); `entries` is the deduplicated non-zero variant the card and
/// balance-trend readers used to build per call.
struct LedgerAggregate: Equatable, Sendable {
    var balances: [UUID: Int64] = [:]
    /// All role entries per account, ascending by date.
    var movements: [UUID: [LedgerAccountEntry]] = [:]
    /// Deduplicated (source wins), non-zero entries per account,
    /// ascending by date — same content as `account.creditCardEntries`
    /// and `account.balanceTrendEntries`.
    var entries: [UUID: [LedgerAccountEntry]] = [:]
    /// Accounts touched by at least one transaction — mirrors
    /// `!transactions.isEmpty || !incomingTransfers.isEmpty`.
    var activeIDs: Set<UUID> = []
}

/// A cheap, notification-free fingerprint of the two inputs the aggregate
/// reads: the transaction table (row count + newest `updatedAt`) and the
/// account table (row count + an order-free fold of each account's id,
/// opening balance and created stamp). Everything is read through
/// `fetchCount` and limit-1 fetches plus the (small) account table scan,
/// so the check stays O(accounts) even on a 30k-row ledger.
///
/// Coverage: every in-place edit path stamps `updatedAt` (editor, inbox
/// accept, sync rules and transfer conversion, AI suggestions, backup
/// restore), inserts/deletes move the row count, and opening-balance
/// edits move `accountChecksum`. One residual is documented for the
/// report: a merge-restore that overwrites a row whose backup stamp is
/// not the table's newest leaves the fingerprint unchanged — the save
/// notifications cover that case.
struct LedgerFingerprint: Equatable, Sendable {
    var transactionCount = 0
    /// `max(LedgerTransaction.updatedAt)` — `.distantPast` on an empty table.
    var newestTransactionStamp = Date.distantPast
    var accountCount = 0
    /// Order-free fold of `id` + `openingBalance` + `createdAt` over the
    /// account table — catches inserts, deletes and opening-balance edits.
    var accountChecksum: Int64 = 0

    /// Reads the fingerprint off `context`. Fetches see pending changes
    /// on that context, so unsaved edits count too — a pending mutation
    /// already makes the committed aggregate stale for readers on the
    /// same context.
    static func read(in context: ModelContext) throws -> LedgerFingerprint {
        var fingerprint = LedgerFingerprint()
        fingerprint.transactionCount = try context.fetchCount(
            FetchDescriptor<LedgerTransaction>())
        var newest = FetchDescriptor<LedgerTransaction>(
            sortBy: [SortDescriptor(
                \LedgerTransaction.updatedAt, order: .reverse)])
        newest.fetchLimit = 1
        if let stamp = try context.fetch(newest).first?.updatedAt {
            fingerprint.newestTransactionStamp = stamp
        }
        fingerprint.accountCount = try context.fetchCount(
            FetchDescriptor<Account>())
        var checksum: Int64 = 0
        for account in try context.fetch(FetchDescriptor<Account>()) {
            checksum &+= account.openingBalance &* 31
                &+ Int64(account.id.hashValue)
                &+ Int64(
                    truncatingIfNeeded:
                        account.createdAt.timeIntervalSince1970.bitPattern)
        }
        fingerprint.accountChecksum = checksum
        return fingerprint
    }
}

/// Computes a `LedgerAggregate` off the main actor on its own context —
/// the standard `ModelActor` pattern keeps the store responsive while a
/// large ledger re-aggregates.
@ModelActor
private actor LedgerAggregateFetcher {
    func compute() throws -> (LedgerAggregate, LedgerFingerprint) {
        // The fingerprint is read BEFORE the walk: a save landing mid-pass
        // leaves the stamp describing an older state than the aggregate
        // may already contain, so the next `refreshIfStale` re-triggers
        // instead of signing off on half-read data.
        let fingerprint = try LedgerFingerprint.read(in: modelContext)
        var aggregate = LedgerAggregate()
        for account in try modelContext.fetch(FetchDescriptor<Account>()) {
            aggregate.balances[account.id] = account.openingBalance
        }
        var descriptor = FetchDescriptor<LedgerTransaction>(
            sortBy: [SortDescriptor(\LedgerTransaction.date)]
        )
        descriptor.relationshipKeyPathsForPrefetching = [
            \LedgerTransaction.account, \LedgerTransaction.toAccount
        ]
        for transaction in try modelContext.fetch(descriptor) {
            if let source = transaction.account {
                let delta = LedgerMath.delta(
                    kind: transaction.kind,
                    amount: transaction.amount,
                    role: .source
                )
                aggregate.activeIDs.insert(source.id)
                // `movements` mirrors `transactions`/`incomingTransfers`:
                // every role row, even when its delta is 0 — the old
                // receivable walk counts any row that touched the account.
                let movement = LedgerAccountEntry(
                    transactionID: transaction.id,
                    date: transaction.date,
                    kind: transaction.kind,
                    isSource: true,
                    amount: transaction.amount,
                    delta: delta
                )
                aggregate.movements[source.id, default: []].append(movement)
                if delta != 0 {
                    aggregate.balances[source.id, default: 0] += delta
                    aggregate.entries[source.id, default: []].append(movement)
                }
            }
            if let destination = transaction.toAccount {
                let delta = LedgerMath.delta(
                    kind: transaction.kind,
                    amount: transaction.amount,
                    role: .destination
                )
                aggregate.activeIDs.insert(destination.id)
                let movement = LedgerAccountEntry(
                    transactionID: transaction.id,
                    date: transaction.date,
                    kind: transaction.kind,
                    isSource: false,
                    amount: transaction.amount,
                    delta: delta
                )
                aggregate.movements[destination.id, default: []].append(movement)
                if delta != 0 {
                    aggregate.balances[destination.id, default: 0] += delta
                    // The destination entry of a self-transfer duplicates the
                    // source entry just appended — the old dedupe kept the
                    // source occurrence, so skip it here too.
                    if aggregate.entries[destination.id]?.last?.transactionID
                        != transaction.id {
                        aggregate.entries[destination.id, default: []].append(movement)
                    }
                }
            }
        }
        return (aggregate, fingerprint)
    }
}

/// Thread-safe ledger version — `didSave` fires synchronously on the
/// saving context's actor (main or a worker), and the version must move
/// in that instant, not after a hop to the main actor, or a read between
/// `save()` and the hop would serve the stale aggregate.
private final class LedgerVersion: @unchecked Sendable {
    private var value = 0
    private let lock = NSLock()

    func bump() {
        lock.lock()
        value += 1
        lock.unlock()
    }

    var current: Int {
        lock.lock()
        defer { lock.unlock() }
        return value
    }
}

/// Shared per-container cache of every account's balance and per-account
/// ledger entries. Replaces the per-render `account.balance` walk over both
/// relationship arrays with one pass over the transaction table, recomputed
/// off the main actor.
///
/// Reads are always correct: while the cached aggregate is stale — or
/// merely suspected stale, since the data can move without a notification
/// reaching us — accessors fall back to the straightforward
/// per-relationship computation, so no view ever shows a wrong number.
///
/// Invalidation is three-layered (iOS 17's SwiftData posts no
/// `ModelContext.didSave` reliably — fixed in iOS 18 — and the owner's
/// phone runs 17.6.1):
/// 1. Notifications: `ModelContext.didSave`, plus the Core Data
///    notifications SwiftData's store still emits on iOS 17 —
///    `NSManagedObjectContextDidSave` and `NSPersistentStoreRemoteChange`.
/// 2. `refreshIfStale`: a cheap `LedgerFingerprint` comparison — row
///    counts, newest `updatedAt`, an opening-balance checksum — run on
///    every read (throttled to `fingerprintInterval`), on scene
///    activation, and after app-side saves through `saveAndCheck`.
/// 3. Fallback: any suspected-stale read returns `account.balance` et al.
///    until a fresh aggregate lands — never the old cached value.
@MainActor @Observable
final class LedgerBalanceStore {
    /// The aggregate snapshot views render from — observed so views
    /// re-evaluate when a fresh pass lands.
    private(set) var aggregate: LedgerAggregate?
    /// Bumped on the main actor whenever a save lands on this container —
    /// views watch it to re-pull paged data; reads never consult it.
    private(set) var changeCount = 0
    /// The synchronous side of invalidation — bumped inside `didSave`
    /// itself, on whatever actor the save ran on.
    private let ledgerVersion = LedgerVersion()

    /// Mutable housekeeping kept off the observation surface — reads
    /// happen inside view bodies, and mutating a tracked property there
    /// would trigger "modifying state during view update" warnings.
    /// Also holds the things `deinit` releases, since a nonisolated
    /// deinit cannot touch MainActor-isolated state.
    private let housekeeping: Housekeeping

    /// How long after the last save before a re-aggregation starts —
    /// coalesces the per-page saves of a large import into one pass.
    var debounceNanos: UInt64 = 150_000_000

    /// Minimum spacing between automatic fingerprint checks — reads call
    /// `refreshIfStale` unconditionally and this keeps the cost at one
    /// small query burst a second. Tests set `.zero` so every read checks.
    var fingerprintInterval: Duration = .seconds(1)

    private final class Housekeeping: @unchecked Sendable {
        var refreshTask: Task<Void, Never>?
        var saveObservers: [NSObjectProtocol] = []
        var aggregatedVersion = -1
        /// The fingerprint the current `aggregate` was built from —
        /// `refreshIfStale` compares the live table against it.
        var aggregatedFingerprint: LedgerFingerprint?
        /// A fingerprint seen that does not match `aggregatedFingerprint`
        /// — non-nil means the cache is suspect even when no notification
        /// ever bumped `ledgerVersion` (the iOS 17 blind spot).
        var suspectFingerprint: LedgerFingerprint?
        /// `mainContext.hasChanges` at the last check — unsaved writes on
        /// the UI context make the committed aggregate stale for readers
        /// on that context regardless of what the store-level queries see.
        var pendingSuspect = false
        /// Throttle stamp for `refreshIfStale`.
        var lastFingerprintCheck: ContinuousClock.Instant?
        let container: ModelContainer
        let fetcher: LedgerAggregateFetcher

        init(container: ModelContainer) {
            self.container = container
            self.fetcher = LedgerAggregateFetcher(modelContainer: container)
        }
    }

    /// `observesSaveNotifications` is the iOS-17 simulation seam: tests
    /// pass false so only the fingerprint path can catch mutations —
    /// exactly what the owner's phone sees when SwiftData stays silent.
    init(container: ModelContainer, observesSaveNotifications: Bool = true) {
        self.housekeeping = Housekeeping(container: container)
        let container = self.housekeeping.container
        let ledgerVersion = self.ledgerVersion
        guard observesSaveNotifications else { return }
        // Channel 1 — SwiftData's own notification (unreliable on iOS 17,
        // fixed in iOS 18). `didSave` posts on the saving context's actor;
        // only saves on this container's contexts matter, and the version
        // bump is synchronous so a read between `save()` and the
        // MainActor hop already sees the cache as stale.
        housekeeping.saveObservers.append(
            NotificationCenter.default.addObserver(
                forName: ModelContext.didSave,
                object: nil,
                queue: nil
            ) { [weak self] notification in
                guard let context = notification.object as? ModelContext,
                      context.container === container else { return }
                ledgerVersion.bump()
                Task { @MainActor [weak self] in
                    self?.noteSave()
                }
            })
        // Channel 2 — the Core Data save notification SwiftData's
        // underlying contexts still post on iOS 17. Its object is an
        // `NSManagedObjectContext`, not a `ModelContext`, so it cannot be
        // matched to this container: any in-process save bumps every
        // store, and the extra pass is simply coalesced away.
        housekeeping.saveObservers.append(
            NotificationCenter.default.addObserver(
                forName: .NSManagedObjectContextDidSave,
                object: nil,
                queue: nil
            ) { [weak self] _ in
                ledgerVersion.bump()
                Task { @MainActor [weak self] in
                    self?.noteSave()
                }
            })
        // Channel 3 — store-level remote changes (persistent history /
        // CloudKit if it is ever switched on; inert otherwise).
        housekeeping.saveObservers.append(
            NotificationCenter.default.addObserver(
                forName: .NSPersistentStoreRemoteChange,
                object: nil,
                queue: nil
            ) { [weak self] _ in
                ledgerVersion.bump()
                Task { @MainActor [weak self] in
                    self?.noteSave()
                }
            })
    }

    deinit {
        housekeeping.refreshTask?.cancel()
        for observer in housekeeping.saveObservers {
            NotificationCenter.default.removeObserver(observer)
        }
    }

    /// Explicit invalidation for flows that bypass a context save.
    func invalidate() {
        ledgerVersion.bump()
        noteSave()
    }

    /// Kicks the first refresh — views fall back to the straight walk until
    /// it lands, so this never blocks launch rendering.
    func warmUp() {
        scheduleRefresh()
    }

    private func noteSave() {
        changeCount += 1
        scheduleRefresh()
    }

    private var isFresh: Bool {
        aggregate != nil
            && housekeeping.aggregatedVersion == ledgerVersion.current
            && housekeeping.suspectFingerprint == nil
            && !housekeeping.pendingSuspect
    }

    /// The notification-free staleness check: re-read the fingerprint and
    /// compare it with the one the current aggregate was built from. A
    /// mismatch marks the cache suspect *synchronously* — the very next
    /// read already falls back to the relationship walk — and schedules
    /// one re-aggregation; a match clears any earlier suspicion (a
    /// rolled-back pending change looks identical to a reverted store).
    ///
    /// Runs on `mainContext`, so pending unsaved edits on the UI context
    /// count too. Called from every read path (throttled to
    /// `fingerprintInterval`), from the scene-activation hook and after
    /// `saveAndCheck`. Pass `force: true` to skip the throttle. Returns
    /// true when a fingerprint was actually read.
    @discardableResult
    func refreshIfStale(force: Bool = false) -> Bool {
        let now = ContinuousClock.now
        if !force,
           let last = housekeeping.lastFingerprintCheck,
           now - last < fingerprintInterval { return false }
        housekeeping.lastFingerprintCheck = now
        let context = housekeeping.container.mainContext
        housekeeping.pendingSuspect = context.hasChanges
        guard housekeeping.aggregatedFingerprint != nil else { return true }
        guard let fingerprint = try? LedgerFingerprint.read(in: context)
        else {
            // Unverifiable is suspect: `transactionCount: -1` can never
            // match a real fingerprint, so `isFresh` stays false until a
            // check succeeds and the walk keeps answering reads.
            if housekeeping.suspectFingerprint == nil {
                housekeeping.suspectFingerprint =
                    LedgerFingerprint(transactionCount: -1)
                ledgerVersion.bump()
                scheduleRefresh()
            }
            return true
        }
        if fingerprint == housekeeping.aggregatedFingerprint {
            housekeeping.suspectFingerprint = nil
        } else if housekeeping.suspectFingerprint != fingerprint {
            // First sighting of this new table state — mark + schedule.
            // `changeCount`/`aggregate` are observed state, so the
            // observable side (`noteSave`) hops to the next main-actor
            // turn; `isFresh` is already false via `suspectFingerprint`.
            housekeeping.suspectFingerprint = fingerprint
            ledgerVersion.bump()
            Task { @MainActor [weak self] in
                self?.noteSave()
            }
        }
        return true
    }

    /// Saves `context`, then runs the fingerprint check inline — the
    /// post-save trigger for writes the app's own code performs through
    /// a context on this store's container. The check only invalidates
    /// when ledger data actually moved, so a save touching unrelated
    /// models stays free.
    func saveAndCheck(_ context: ModelContext) throws {
        try context.save()
        refreshIfStale(force: true)
    }

    private func scheduleRefresh() {
        guard housekeeping.refreshTask == nil else { return }
        let debounceNanos = debounceNanos
        housekeeping.refreshTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: debounceNanos)
            guard !Task.isCancelled else { return }
            await self?.refresh()
            self?.housekeeping.refreshTask = nil
        }
    }

    /// One re-aggregation pass on the background context. When the ledger
    /// moved while the pass ran the result is stale before it lands — mark
    /// and run again so the cache always converges.
    private func refresh() async {
        let version = ledgerVersion.current
        guard !Task.isCancelled,
              let computed = try? await housekeeping.fetcher.compute()
        else { return }
        aggregate = computed.0
        housekeeping.aggregatedFingerprint = computed.1
        housekeeping.aggregatedVersion = version
        if housekeeping.suspectFingerprint == computed.1 {
            // The flagged table state is exactly what this pass read.
            housekeeping.suspectFingerprint = nil
        }
        if ledgerVersion.current != version {
            scheduleRefresh()
        }
    }

    /// Synchronous refresh on the caller's context — tests measure and
    /// assert against this exact single-pass computation. The fingerprint
    /// is taken before the walk for the same mid-pass-save safety the
    /// fetcher uses.
    func refresh(context: ModelContext) throws {
        let fingerprint = try LedgerFingerprint.read(in: context)
        var aggregate = LedgerAggregate()
        for account in try context.fetch(FetchDescriptor<Account>()) {
            aggregate.balances[account.id] = account.openingBalance
        }
        var descriptor = FetchDescriptor<LedgerTransaction>(
            sortBy: [SortDescriptor(\LedgerTransaction.date)]
        )
        descriptor.relationshipKeyPathsForPrefetching = [
            \LedgerTransaction.account, \LedgerTransaction.toAccount
        ]
        for transaction in try context.fetch(descriptor) {
            if let source = transaction.account {
                let delta = LedgerMath.delta(
                    kind: transaction.kind,
                    amount: transaction.amount,
                    role: .source
                )
                aggregate.activeIDs.insert(source.id)
                let movement = LedgerAccountEntry(
                    transactionID: transaction.id,
                    date: transaction.date,
                    kind: transaction.kind,
                    isSource: true,
                    amount: transaction.amount,
                    delta: delta
                )
                aggregate.movements[source.id, default: []].append(movement)
                if delta != 0 {
                    aggregate.balances[source.id, default: 0] += delta
                    aggregate.entries[source.id, default: []].append(movement)
                }
            }
            if let destination = transaction.toAccount {
                let delta = LedgerMath.delta(
                    kind: transaction.kind,
                    amount: transaction.amount,
                    role: .destination
                )
                aggregate.activeIDs.insert(destination.id)
                let movement = LedgerAccountEntry(
                    transactionID: transaction.id,
                    date: transaction.date,
                    kind: transaction.kind,
                    isSource: false,
                    amount: transaction.amount,
                    delta: delta
                )
                aggregate.movements[destination.id, default: []].append(movement)
                if delta != 0 {
                    aggregate.balances[destination.id, default: 0] += delta
                    if aggregate.entries[destination.id]?.last?.transactionID
                        != transaction.id {
                        aggregate.entries[destination.id, default: []].append(movement)
                    }
                }
            }
        }
        self.aggregate = aggregate
        housekeeping.aggregatedFingerprint = fingerprint
        housekeeping.aggregatedVersion = ledgerVersion.current
        if housekeeping.suspectFingerprint == fingerprint {
            housekeeping.suspectFingerprint = nil
        }
    }

    // MARK: - Reads

    /// The account's ledger balance: cached when fresh, the old
    /// relationship walk while stale — identical numbers either way.
    func balance(of account: Account) -> Int64 {
        refreshIfStale()
        guard isFresh else {
            scheduleRefresh()
            return account.balance
        }
        return aggregate?.balances[account.id] ?? account.balance
    }

    /// Cached balance for an account id, or nil while stale — for callers
    /// that already resolved the id and have their own fallback.
    func cachedBalance(of accountID: UUID) -> Int64? {
        refreshIfStale()
        guard isFresh else {
            scheduleRefresh()
            return nil
        }
        return aggregate?.balances[accountID]
    }

    /// Deduplicated non-zero entries — same values `creditCardEntries`
    /// and `balanceTrendEntries` produced by walking the relationships.
    func entries(of account: Account) -> [LedgerAccountEntry] {
        refreshIfStale()
        guard isFresh else {
            scheduleRefresh()
            return account.fallbackLedgerEntries
        }
        return aggregate?.entries[account.id] ?? []
    }

    /// Every role entry including self-transfer duplicates and zero-delta
    /// rows — the input `ReceivableSnapshot` semantics require.
    func movements(of account: Account) -> [LedgerAccountEntry] {
        refreshIfStale()
        guard isFresh else {
            scheduleRefresh()
            return account.fallbackLedgerMovements
        }
        return aggregate?.movements[account.id] ?? []
    }

    /// `AccountGrouping.canDelete` from the cache.
    func hasActivity(of account: Account) -> Bool {
        refreshIfStale()
        guard isFresh else {
            scheduleRefresh()
            return !AccountGrouping.canDelete(account)
        }
        return aggregate?.activeIDs.contains(account.id) ?? false
    }

    /// `creditCardEntries` equivalent.
    func creditCardEntries(of account: Account) -> [CreditCardEntry] {
        entries(of: account).map { CreditCardEntry(date: $0.date, delta: $0.delta) }
    }

    /// `balanceTrendEntries` equivalent.
    func balanceTrendEntries(of account: Account) -> [BalanceHistoryEntry] {
        entries(of: account).map { BalanceHistoryEntry(date: $0.date, delta: $0.delta) }
    }

    /// `ReceivableSnapshot.make(account:)` from cached movements.
    func receivableSnapshot(of account: Account) -> ReceivableSnapshot {
        var advances: [ReceivableMovement] = []
        var settlements: [ReceivableMovement] = []
        if account.openingBalance > 0 {
            advances.append(ReceivableMovement(
                date: account.createdAt, amount: account.openingBalance))
        } else if account.openingBalance < 0 {
            settlements.append(ReceivableMovement(
                date: account.createdAt,
                amount: account.openingBalance == Int64.min
                    ? Int64.max : -account.openingBalance))
        }
        for entry in movements(of: account) {
            let movement = ReceivableMovement(date: entry.date, amount: entry.amount)
            if entry.isSource {
                if entry.kind == .income {
                    advances.append(movement)
                } else {
                    settlements.append(movement)
                }
            } else {
                advances.append(movement)
            }
        }
        return ReceivableSnapshot.make(advances: advances, settlements: settlements)
    }
}

private extension Account {
    /// Straight relationship walk producing the deduplicated non-zero
    /// entries — the stale-cache fallback, identical to
    /// `creditCardEntries`/`balanceTrendEntries` semantics.
    var fallbackLedgerEntries: [LedgerAccountEntry] {
        var seen = Set<UUID>()
        var result: [LedgerAccountEntry] = []
        for transaction in (transactions ?? []) + (incomingTransfers ?? []) {
            guard seen.insert(transaction.id).inserted else { continue }
            let isSource = transaction.account === self
            let delta = LedgerMath.delta(
                kind: transaction.kind,
                amount: transaction.amount,
                role: isSource ? .source : .destination
            )
            guard delta != 0 else { continue }
            result.append(LedgerAccountEntry(
                transactionID: transaction.id,
                date: transaction.date,
                kind: transaction.kind,
                isSource: isSource,
                amount: transaction.amount,
                delta: delta
            ))
        }
        // Stable date sort — same ordering `balanceTrendEntries` produces.
        return result
            .enumerated()
            .sorted { lhs, rhs in
                lhs.element.date == rhs.element.date
                    ? lhs.offset < rhs.offset
                    : lhs.element.date < rhs.element.date
            }
            .map(\.element)
    }

    /// Straight relationship walk producing every role entry — the
    /// stale-cache fallback matching `ReceivableSnapshot.make(account:)`.
    var fallbackLedgerMovements: [LedgerAccountEntry] {
        var result: [LedgerAccountEntry] = []
        for transaction in transactions ?? [] {
            result.append(LedgerAccountEntry(
                transactionID: transaction.id,
                date: transaction.date,
                kind: transaction.kind,
                isSource: true,
                amount: transaction.amount,
                delta: LedgerMath.delta(
                    kind: transaction.kind,
                    amount: transaction.amount,
                    role: .source
                )
            ))
        }
        for transaction in incomingTransfers ?? [] {
            result.append(LedgerAccountEntry(
                transactionID: transaction.id,
                date: transaction.date,
                kind: transaction.kind,
                isSource: false,
                amount: transaction.amount,
                delta: LedgerMath.delta(
                    kind: transaction.kind,
                    amount: transaction.amount,
                    role: .destination
                )
            ))
        }
        return result.sorted { $0.date < $1.date }
    }
}

/// One `LedgerBalanceStore` per `ModelContainer` so every view and every
/// context of the same store share the cache without environment plumbing.
@MainActor
enum LedgerBalanceStores {
    private static var stores: [ObjectIdentifier: LedgerBalanceStore] = [:]

    static func shared(for container: ModelContainer) -> LedgerBalanceStore {
        let key = ObjectIdentifier(container)
        if let store = stores[key] { return store }
        let store = LedgerBalanceStore(container: container)
        stores[key] = store
        return store
    }

    /// Removes the cached store for a container — tests use it to reset.
    static func remove(_ container: ModelContainer) {
        stores.removeValue(forKey: ObjectIdentifier(container))
    }
}
