import Combine
import CoreData
import FinanceCore
import Foundation
import SwiftData
import SwiftUI

/// The two first-sync directions — which side's data replaces the other
/// before two-way sync is switched on.
enum FinanceSyncEnableMode: String, Equatable, Sendable {
    /// "Đưa dữ liệu iPhone lên web" — the phone's copy replaces the
    /// server's (`FinanceSyncBootstrap.uploadReplace`).
    case upload
    /// "Tải dữ liệu từ web về iPhone" — the server's copy replaces the
    /// phone's (`FinanceSyncBootstrap.downloadReplace`).
    case download
}

/// App-facing owner of the finance sync machinery: the engine, the
/// first-sync bootstrap and the shadow store — all behind a single
/// MainActor surface the views and schedulers talk to.
///
/// Mirrors `WalletSyncCoordinator`: `syncNow` is single-flight (callers
/// arriving mid-run piggyback on the in-flight task), `syncIfStale`
/// gates on the last successful sync, and automatic callers no-op while
/// disabled or signed out. On top of that it owns the first-sync flow
/// (`probe` + `enable(mode:)`), the pause/resume/disconnect lifecycle,
/// the ~3 s debounced sync after local saves, and Vietnamese error text
/// for the settings screen.
///
/// `enabled` and `configured` are distinct: `enabled` is the sync
/// switch; `configured` means a first sync completed and the shadow
/// still exists — "Tạm dừng" is configured-but-disabled, while a fresh
/// or disconnected device is neither and shows the first-sync choice.
@MainActor
@Observable
final class FinanceSyncCoordinator {
    /// Whether two-way sync is currently switched on — mirrored from the
    /// shadow state on every `refreshState`.
    private(set) var enabled = false
    /// A first sync completed and the shadow still exists — the settings
    /// screen shows the run/pause/disconnect controls instead of the
    /// first-sync choice.
    private(set) var configured = false
    private(set) var isSyncing = false
    /// A first-sync bootstrap (upload/download replace) is running.
    private(set) var isBootstrapping = false
    private(set) var lastSyncAt: Date?
    /// Counters of the most recent finished cycle.
    private(set) var lastReport: FinanceSyncReport?
    /// Counters of the most recent successful bootstrap.
    private(set) var lastBootstrapReport: FinanceSyncBootstrapReport?
    /// Vietnamese user-facing text of the last failure — from
    /// `errorText`, or the shadow's persisted copy after a relaunch.
    private(set) var lastError: String?
    /// Records the server refused (`422` index ≥ 0), parked until their
    /// local content changes.
    private(set) var quarantined: [SyncQuarantineSnapshot] = []
    /// Server base URL shown on the Máy chủ screen
    /// (`https://finance.ledinhdai.com/api`).
    let serverDisplay: String

    private let engine: FinanceSyncEngine
    private let bootstrap: FinanceSyncBootstrap
    private let shadow: SyncShadowStore
    private let isSignedIn: @Sendable () async -> Bool
    private var inFlight: Task<Bool, Never>?
    private var debounceTask: Task<Void, Never>?
    /// A local save arrived mid-sync — one follow-up pass covers it.
    private var pendingLocalSave = false
    /// The next sync must run a FULL scan — set by `.dataResetCompleted`,
    /// whose wipe+reseed the QUICK scan's `updatedAt` window must not trust.
    private var pendingFullScan = false
    /// Online-only: a user save starts a cycle immediately, and a `422`
    /// quarantines the row only long enough to reload server truth.
    var instantWrites = false
    /// False after a wait/push/pull transport failure, until a request
    /// succeeds. The online gate blocks editing while this is false.
    private(set) var isOnline = true
    /// "Máy chủ từ chối thay đổi: …" — set when an online push is rejected.
    private(set) var rejectionReason: String?
    /// A rejected online push must reload the store once the coalesced
    /// follow-up has had a chance to send the edits that were valid.
    private var rejectionReloadPending = false
    /// Fired on the offline/online transition. The online store mirrors
    /// `isOnline` onto the gate.
    var onOnlineChange: (@MainActor (Bool) -> Void)?
    /// Fired once after a cycle (and its coalesced follow-up) quarantined
    /// at least one record while `instantWrites` is on. The argument is
    /// the alert text. The online store reloads from the export.
    var onRejectedPush: (@MainActor (String) async -> Void)?
    private var liveTask: Task<Void, Never>?
    private var liveGeneration = 0
    /// The shadow state has been read at least once — `performSync`
    /// refreshes once before gating so an early trigger after launch is
    /// not dropped by a still-unloaded `enabled`.
    private var stateLoaded = false
    private var resetObserver: (any NSObjectProtocol)?
    private var saveObservers: [any NSObjectProtocol] = []
    private var saveCenter: NotificationCenter = .default

    /// Debounce between a local save and the auto-sync it triggers —
    /// coalesces bursts of edits; tests shrink it. Ignored while
    /// `instantWrites` is on (online mode pushes on the save itself).
    var localSaveDebounce: Duration = .seconds(3)
    /// Long-poll hold passed to `GET /v1/sync/wait`. Tests shrink it.
    var liveWaitTimeout: TimeInterval = 25
    /// First pause after a wait/push/pull transport failure. Doubles up
    /// to `liveBackoffMaximum`.
    var liveBackoffInitial: Duration = .seconds(1)
    var liveBackoffMaximum: Duration = .seconds(30)
    /// After a wait that reported new seqs but the cycle pulled nothing —
    /// keeps a server that answers 200 instantly from spinning.
    var liveEmptyPullDelay: Duration = .seconds(1)
    /// `syncIfStale` window — a fresher `lastSyncAt` skips the cycle.
    var staleInterval: TimeInterval = 60

    init(
        engine: FinanceSyncEngine,
        bootstrap: FinanceSyncBootstrap,
        shadow: SyncShadowStore,
        isSignedIn: @escaping @Sendable () async -> Bool,
        serverDisplay: String,
        notificationCenter: NotificationCenter = .default
    ) {
        self.engine = engine
        self.bootstrap = bootstrap
        self.shadow = shadow
        self.isSignedIn = isSignedIn
        self.serverDisplay = serverDisplay
        Task { await self.refreshState() }
        resetObserver = notificationCenter.addObserver(
            forName: .dataResetCompleted, object: nil, queue: nil
        ) { [weak self] _ in
            Task { @MainActor in self?.noteDataReset() }
        }
    }

    // MARK: - Queries for the settings screen

    /// Sign-in probe — the shared WalletLink session in the app, a fake
    /// provider under the UI-test server.
    func checkSignedIn() async -> Bool {
        await isSignedIn()
    }

    /// First-sync inputs — server emptiness, local counts, shadow state.
    func probe() async throws -> FinanceSyncProbe {
        try await bootstrap.probe()
    }

    /// Reloads enabled/lastSyncAt/quarantines from the shadow — run after
    /// every operation and whenever the settings screen appears. Writes
    /// only land on real changes: every assignment on an `@Observable`
    /// property invalidates the views tracking it, and the routine
    /// triggers would otherwise churn the tree on every 60 s tick even
    /// while sync sits disabled.
    func refreshState() async {
        stateLoaded = true
        if let state = try? await shadow.state() {
            if enabled != state.isEnabled { enabled = state.isEnabled }
            if lastSyncAt != state.lastSyncAt {
                lastSyncAt = state.lastSyncAt
            }
            // The shadow keeps the raw failure text; the coordinator's
            // mapped text wins while both describe the same failure.
            if lastError == nil, let error = state.lastError {
                lastError = error
            }
            let entries = (try? await shadow.entryCount()) ?? 0
            let isConfigured = entries > 0 || state.pullCursor > 0
            if configured != isConfigured { configured = isConfigured }
        }
        if let quarantines = try? await shadow.quarantines(),
           quarantined != quarantines {
            quarantined = quarantines
        }
    }

    // MARK: - Sync

    /// One cycle unless one is already running — concurrent callers get
    /// the in-flight run's result. Returns false without side effects
    /// when disabled or signed out. `fullScan` forces a FULL local hash
    /// pass — the manual "Đồng bộ ngay".
    ///
    /// A save that landed mid-cycle (`pendingLocalSave`) becomes exactly
    /// one follow-up: an immediate `syncNow` in online mode, a fresh
    /// debounce otherwise. The follow-up runs only after `inFlight` is
    /// cleared, so it cannot piggyback on the cycle that already passed
    /// its diff.
    @discardableResult
    func syncNow(fullScan: Bool = false) async -> Bool {
        if let inFlight { return await inFlight.value }
        let task = Task { await performSync(fullScan: fullScan) }
        inFlight = task
        let result = await task.value
        inFlight = nil
        if pendingLocalSave, enabled, !isBootstrapping {
            pendingLocalSave = false
            if instantWrites {
                _ = await syncNow()
            } else {
                armDebounce()
            }
        }
        if rejectionReloadPending {
            rejectionReloadPending = false
            await refreshState()
            let reason = Self.rejectionText(quarantined)
            rejectionReason = reason
            await onRejectedPush?(reason)
        }
        return result
    }

    /// Sync only when the last successful sync is older than the window
    /// (default `staleInterval`, one minute).
    @discardableResult
    func syncIfStale(maxAge: TimeInterval? = nil) async -> Bool {
        let window = maxAge ?? staleInterval
        if let lastSyncAt, Date.now.timeIntervalSince(lastSyncAt) < window {
            return false
        }
        return await syncNow()
    }

    /// Sync after a local save. Online mode (`instantWrites`) starts a
    /// cycle on the save itself — no debounce. Either way, saves that
    /// land while a cycle is in flight collapse into one follow-up
    /// (`pendingLocalSave`) instead of a loop.
    func noteLocalSave() {
        guard enabled, !isBootstrapping else { return }
        if inFlight != nil || isSyncing {
            pendingLocalSave = true
            return
        }
        if instantWrites {
            Task { [weak self] in await self?.syncNow() }
            return
        }
        armDebounce()
    }

    /// Starts listening for REAL user edits of the app store — saves the
    /// sync engine did not originate and that touch a synced entity — and
    /// feeds each into `noteLocalSave()`. See `FinanceSyncSaveFilter` for
    /// why the engine's own app-store saves and the shadow store's saves
    /// must not count (they made every cycle schedule the next one).
    /// Idempotent. The observers are synchronous (`queue: nil`) so the
    /// engine-origin mark is still readable when the filter runs.
    func startObservingLocalSaves(center: NotificationCenter = .default) {
        guard saveObservers.isEmpty else { return }
        let container = engine.modelContainer
        let handler: @Sendable (Notification) -> Void = { [weak self] notification in
            guard FinanceSyncSaveFilter.isUserSave(
                notification, container: container) else { return }
            Task { @MainActor in self?.noteLocalSave() }
        }
        for name in [ModelContext.didSave, Notification.Name.NSManagedObjectContextDidSave] {
            saveObservers.append(center.addObserver(
                forName: name, object: nil, queue: nil, using: handler))
        }
        saveCenter = center
    }

    /// Detaches the observers `startObservingLocalSaves` added.
    func stopObservingLocalSaves() {
        for observer in saveObservers {
            saveCenter.removeObserver(observer)
        }
        saveObservers.removeAll()
    }

    // MARK: - First sync and lifecycle

    /// "Bật đồng bộ" — runs the chosen bootstrap mode; sync is enabled
    /// only on success (the bootstrap's last step), so a failed run is
    /// safely resumable.
    @discardableResult
    func enable(mode: FinanceSyncEnableMode) async -> Bool {
        guard !isBootstrapping else { return false }
        // A stray auto-sync may still be winding down — wait it out;
        // the bootstrap replaces the shadow wholesale anyway. The
        // yield matters: awaiting an already-finished task returns
        // without rescheduling, so a bare loop would starve the main
        // actor slot `syncNow`'s defer needs to clear `inFlight`.
        while let inFlight {
            _ = await inFlight.value
            await Task.yield()
        }
        guard !isSyncing else { return false }
        guard await isSignedIn() else {
            lastError = Self.errorText(FinanceSyncError.unauthorized)
            return false
        }
        isBootstrapping = true
        defer { isBootstrapping = false }
        do {
            let report: FinanceSyncBootstrapReport
            switch mode {
            case .upload:
                report = try await bootstrap.uploadReplace()
            case .download:
                report = try await bootstrap.downloadReplace()
            }
            lastBootstrapReport = report
            lastReport = report.sync
            lastError = nil
            if mode == .download {
                // The whole local store was just replaced — post the same
                // root-rebuild signal "Xoá dữ liệu" uses so no screen
                // keeps references to deleted objects.
                NotificationCenter.default.post(
                    name: .dataResetCompleted, object: nil)
            }
            await refreshState()
            return true
        } catch {
            lastError = Self.errorText(error)
            await refreshState()
            return false
        }
    }

    /// "Tạm dừng" — sync off, shadow kept; `resume()` continues
    /// incrementally from the stored cursor and hashes.
    func pause() async {
        debounceTask?.cancel()
        try? await shadow.setEnabled(false)
        enabled = false
    }

    /// "Tiếp tục" — sync back on; kicks a cycle so a pause window's
    /// edits do not wait for the next timer.
    func resume() async {
        try? await shadow.setEnabled(true)
        enabled = true
        Task { await self.syncNow() }
    }

    /// "Ngắt kết nối" — disable and wipe shadow + quarantine; re-enabling
    /// needs the first-sync choice again. Local and server data are
    /// untouched.
    func disconnect() async {
        debounceTask?.cancel()
        pendingLocalSave = false
        // Flip the flag before the hops so a cycle triggered meanwhile
        // bails on the gate instead of writing into the wiped shadow.
        enabled = false
        try? await shadow.setEnabled(false)
        // A cycle already in flight keeps running past the flag — wait
        // it out so its shadow writes cannot land after the wipe. See
        // `enable` for why the yield is needed in this drain loop.
        while let inFlight {
            _ = await inFlight.value
            await Task.yield()
        }
        try? await shadow.wipeAll()
        lastReport = nil
        lastBootstrapReport = nil
        lastError = nil
        await refreshState()
    }

    // MARK: - Internals

    private func performSync(fullScan: Bool) async -> Bool {
        if !stateLoaded { await refreshState() }
        guard enabled else { return false }
        guard await isSignedIn() else { return false }
        isSyncing = true
        let succeeded: Bool
        var reportQuarantined = 0
        do {
            let scan = fullScan || pendingFullScan
            let report = try await engine.syncOnce(fullScan: scan)
            pendingFullScan = false
            lastReport = report
            lastError = nil
            reportQuarantined = report.quarantined
            succeeded = true
        } catch {
            if !Self.isCancellation(error) {
                lastError = Self.errorText(error)
                if Self.isNetwork(error) { setOnline(false) }
            }
            succeeded = false
        }
        isSyncing = false
        if succeeded {
            setOnline(true)
            if instantWrites, reportQuarantined > 0 {
                // Consumed by `syncNow` after a coalesced follow-up, so a
                // valid edit saved during this cycle still reaches the
                // server before the reload throws the rejected row away.
                rejectionReloadPending = true
            }
        }
        await refreshState()
        return succeeded
    }

    private func armDebounce() {
        debounceTask?.cancel()
        debounceTask = Task { [weak self, delay = localSaveDebounce] in
            try? await Task.sleep(for: delay)
            guard !Task.isCancelled, let self else { return }
            await self.runDebounced()
        }
    }

    private func runDebounced() async {
        _ = await syncNow()
        if pendingLocalSave {
            pendingLocalSave = false
            armDebounce()
        }
    }

    /// `.dataResetCompleted`: the wipe+reseed is a wholesale local change
    /// that must propagate to the web on the next sync — force a FULL
    /// scan so the QUICK scan's `updatedAt` window cannot hide it.
    private func noteDataReset() {
        debounceTask?.cancel()
        pendingLocalSave = false
        pendingFullScan = true
        if lastReport != nil { lastReport = nil }
        Task { await self.refreshState() }
    }

    private func setOnline(_ online: Bool) {
        guard isOnline != online else { return }
        isOnline = online
        onOnlineChange?(online)
    }

    /// Alert copy for a rejected online push. `entries` is the shadow's
    /// quarantine list (already refreshed).
    static func rejectionText(_ entries: [SyncQuarantineSnapshot]) -> String {
        let messages = entries.map(\.message).filter { !$0.isEmpty }
        let detail = messages.isEmpty
            ? "dữ liệu không hợp lệ"
            : messages.joined(separator: "; ")
        return "Máy chủ từ chối thay đổi: \(detail)"
    }

    static func isNetwork(_ error: Error) -> Bool {
        if isCancellation(error) { return false }
        if let syncError = error as? FinanceSyncError {
            if case .transport = syncError { return true }
            return false
        }
        return error is URLError
    }

    static func isCancellation(_ error: Error) -> Bool {
        if error is CancellationError { return true }
        if let urlError = error as? URLError, urlError.code == .cancelled {
            return true
        }
        return false
    }

    // MARK: - Live updates

    /// One long-poll loop. No-op when one is already running. Online mode
    /// starts it while the scene is active and the store is ready; leaving
    /// the foreground cancels it (`stopLiveUpdates`).
    func startLiveUpdates() {
        guard liveTask == nil else { return }
        let generation = liveGeneration
        liveTask = Task { [weak self] in
            await self?.runLiveUpdates(generation: generation)
        }
    }

    /// Cancels the long-poll. An in-flight cycle is left to finish — the
    /// wait itself is what gets cancelled. A later `startLiveUpdates`
    /// begins a fresh loop; the old one exits because its generation no
    /// longer matches.
    func stopLiveUpdates() {
        liveGeneration += 1
        liveTask?.cancel()
        liveTask = nil
    }

    /// Waits on the shadow pull cursor. 200 → one cycle, then loop; 204 →
    /// loop; a transport failure marks the connection offline and backs
    /// off from `liveBackoffInitial` to `liveBackoffMaximum`. A 200 whose
    /// cycle pulled nothing sleeps `liveEmptyPullDelay` so an instant
    /// answer cannot spin. Coming back online always runs a cycle, so an
    /// edit saved just before the drop still pushes.
    private func runLiveUpdates(generation: Int) async {
        var backoff = liveBackoffInitial
        while !Task.isCancelled, liveGeneration == generation {
            let cursor = (try? await shadow.pullCursor()) ?? 0
            do {
                let advanced = try await engineAPI().wait(
                    cursor: cursor, timeout: liveWaitTimeout)
                guard !Task.isCancelled, liveGeneration == generation else { return }
                let wasOffline = !isOnline
                setOnline(true)
                backoff = liveBackoffInitial
                if let seq = advanced, seq > cursor {
                    let ok = await syncDetached()
                    guard !Task.isCancelled, liveGeneration == generation else { return }
                    if !isOnline {
                        backoff = await sleepBackoff(backoff)
                        continue
                    }
                    if !ok || (lastReport?.pulled ?? 0) == 0 {
                        try await Task.sleep(for: liveEmptyPullDelay)
                    }
                } else if wasOffline {
                    _ = await syncDetached()
                    guard !Task.isCancelled, liveGeneration == generation else { return }
                    if !isOnline { backoff = await sleepBackoff(backoff) }
                }
            } catch is CancellationError {
                return
            } catch {
                if Task.isCancelled || Self.isCancellation(error)
                    || liveGeneration != generation { return }
                if Self.isNetwork(error) { setOnline(false) }
                backoff = await sleepBackoff(backoff)
            }
        }
    }

    /// `syncNow` on its own task so cancelling the long-poll (backgrounding)
    /// does not abort a push that is already on the wire.
    private func syncDetached() async -> Bool {
        await Task { @MainActor [weak self] in
            await self?.syncNow() ?? false
        }.value
    }

    private func engineAPI() -> FinanceSyncAPIClient {
        engine.api
    }

    /// Sleeps the current delay and returns the next one (doubled, capped).
    /// Cancellation ends the sleep early; the caller rechecks the task.
    private func sleepBackoff(_ backoff: Duration) async -> Duration {
        let doubled = backoff * 2
        let next = doubled > liveBackoffMaximum ? liveBackoffMaximum : doubled
        try? await Task.sleep(for: backoff)
        return next
    }

    /// Vietnamese one-liner for a sync failure — the user-facing mapping
    /// of `FinanceSyncError` (and everything else verbatim).
    static func errorText(_ error: Error) -> String {
        if let syncError = error as? FinanceSyncError {
            switch syncError {
            case .unauthorized:
                return "Chưa đăng nhập hoặc phiên đã hết hạn — mở Kết nối ví AMX để đăng nhập lại."
            case .transport:
                return "Mất kết nối tới máy chủ đồng bộ — kiểm tra mạng rồi thử lại."
            case .validation(let detail):
                let field = detail.field.isEmpty ? "?" : detail.field
                return "Máy chủ từ chối bản ghi (\(field)): \(detail.message)"
            case .conflict, .idempotencyKeyReused, .tooLarge,
                 .http, .decoding:
                return syncError.localizedDescription
            }
        }
        return error.localizedDescription
    }
}

/// Everything `FinanceSyncCoordinator.live` wires together — the online
/// launch pipeline drives the same engine/bootstrap/shadow the
/// coordinator owns.
@MainActor
struct FinanceSyncStack {
    let api: FinanceSyncAPIClient
    let shadow: SyncShadowStore
    let engine: FinanceSyncEngine
    let bootstrap: FinanceSyncBootstrap
    let coordinator: FinanceSyncCoordinator
    let isSignedIn: @Sendable () async -> Bool
}

extension FinanceSyncCoordinator {
    /// The app's coordinator — see `makeStack`.
    static func live(
        container: ModelContainer,
        session: WalletLinkSession = .shared,
        defaults: UserDefaults = .standard,
        inMemoryShadow: Bool? = nil
    ) throws -> FinanceSyncCoordinator {
        try makeStack(
            container: container, session: session, defaults: defaults,
            inMemoryShadow: inMemoryShadow).coordinator
    }

    /// The app's coordinator stack: the shared WalletLink session for
    /// auth, the configured base URL, the shadow store (in-memory under
    /// `-uiTestInMemoryStore`, or whenever `inMemoryShadow` is true — the
    /// online-only launch — so no `FinanceSync.store` file is ever
    /// opened), and the ledger invalidation hook. Under the DEBUG-only
    /// `-uiTestFakeSyncServer` flag the API points at the in-app fake
    /// and sign-in is faked too.
    static func makeStack(
        container: ModelContainer,
        session: WalletLinkSession = .shared,
        defaults: UserDefaults = .standard,
        inMemoryShadow: Bool? = nil
    ) throws -> FinanceSyncStack {
        let arguments = ProcessInfo.processInfo.arguments
        let inMemoryStore = inMemoryShadow
            ?? arguments.contains("-uiTestInMemoryStore")
        let shadow = SyncShadowStore(
            modelContainer: try FinanceSyncSchema.makeContainer(
                inMemory: inMemoryStore))
        let config = FinanceSyncConfigStore(defaults: defaults).load()

        let api: FinanceSyncAPIClient
        let signedIn: @Sendable () async -> Bool
        let serverDisplay: String
        #if DEBUG
        if FinanceSyncUITestSupport.enabled(arguments: arguments) {
            let fake = FinanceSyncUITestServer.shared
            api = FinanceSyncAPIClient(
                baseURL: fake.baseURL,
                tokenProvider: FinanceSyncUITestSupport.TokenProvider(),
                urlSession: fake.session)
            signedIn = { true }
            serverDisplay = fake.baseURL.absoluteString
        } else {
            let baseURL = try config.resolved()
            api = FinanceSyncAPIClient(
                baseURL: baseURL, tokenProvider: session)
            signedIn = {
                if case .signedIn = await session.status { return true }
                return false
            }
            serverDisplay = baseURL.absoluteString
        }
        #else
        let baseURL = try config.resolved()
        api = FinanceSyncAPIClient(baseURL: baseURL, tokenProvider: session)
        signedIn = {
            if case .signedIn = await session.status { return true }
            return false
        }
        serverDisplay = baseURL.absoluteString
        #endif

        let engine = FinanceSyncEngine(
            modelContainer: container, api: api, shadow: shadow)
        let bootstrap = FinanceSyncBootstrap(
            modelContainer: container, api: api, engine: engine,
            shadow: shadow)
        let coordinator = FinanceSyncCoordinator(
            engine: engine, bootstrap: bootstrap, shadow: shadow,
            isSignedIn: signedIn, serverDisplay: serverDisplay)
        // Pulled writes commit on the engine's background context — on
        // iOS 17 the `didSave` notification may never arrive, so the
        // engine's own hook invalidates the balance cache directly
        // (mirrors the bootstrap's restore commit).
        let ledgerHook: @Sendable () -> Void = {
            Task { @MainActor in
                LedgerBalanceStores.shared(for: container).invalidate()
            }
        }
        Task {
            await engine.addLocalStoreChangeHook(ledgerHook)
            await bootstrap.addLocalStoreChangeHook(ledgerHook)
            await FinanceSyncMainContextRefresher.install(
                on: engine, container: container)
        }
        return FinanceSyncStack(
            api: api, shadow: shadow, engine: engine,
            bootstrap: bootstrap, coordinator: coordinator,
            isSignedIn: signedIn)
    }
}

extension FinanceSyncProbe {
    /// True when the phone holds only seedable entities — no
    /// transactions, budgets, rules, rentals or rate changes — so a
    /// download-replace can lose nothing but seed data.
    var seedOnly: Bool {
        for entity in [SyncEntity.transaction, .budget, .recurringRule,
                       .rentalUnit, .rentalLease, .loanRateChange]
        where (localCounts[entity] ?? 0) > 0 { return false }
        return true
    }

    /// The suggested first-sync direction: upload when the server is
    /// empty (nothing on the web to lose), download when the phone is
    /// seed-only (nothing local to lose). Nil when both sides hold real
    /// data — the user must pick.
    var recommendedMode: FinanceSyncEnableMode? {
        if serverEmpty { return .upload }
        if seedOnly { return .download }
        return nil
    }
}

/// SwiftUI environment plumbing for the one app-level coordinator —
/// a key-based entry so a nil value is representable (unit tests and a
/// failed `.live` both leave the screen in its unavailable state).
private struct FinanceSyncEnvironmentKey: EnvironmentKey {
    static let defaultValue: FinanceSyncCoordinator? = nil
}

extension EnvironmentValues {
    /// The app-level `FinanceSyncCoordinator`, injected on the root —
    /// nil in previews, unit tests and after a failed `live` build.
    var financeSync: FinanceSyncCoordinator? {
        get { self[FinanceSyncEnvironmentKey.self] }
        set { self[FinanceSyncEnvironmentKey.self] = newValue }
    }
}

/// Auto-sync attached to the root view: `syncIfStale` on appear, on
/// every `.active` scene phase and every 60 s while active, plus the
/// debounced (~3 s) sync after local saves. Save notifications are the
/// same pair `LedgerBalanceStore` listens to — `ModelContext.didSave`
/// plus the Core Data save notification SwiftData still emits on
/// iOS 17 — so the trigger is best-effort on iOS 17 like everything
/// else. Only real user edits count: `startObservingLocalSaves` drops
/// the engine's own saves and the shadow store's (`FinanceSyncSaveFilter`).
///
/// Inertness is structural, not just guarded: under
/// `-uiTestInMemoryStore` the modifier attaches NOTHING — no timer
/// subscription, no notification observers — so a UI-test run does zero
/// sync work even when a coordinator exists (the `-uiTestFakeSyncServer`
/// tests drive sync through explicit buttons, keeping reports
/// deterministic). The exception is `-uiTestOnline`: that launch
/// keeps the triggers so a quick-add is pushed to the in-app fake.
/// A disabled sync is nearly as inert: the timer and
/// phase/save triggers only ever fire while `coordinator.enabled` —
/// reading an `@Observable` property inside an action is untracked, so
/// these checks never re-render the root.
private struct FinanceSyncAutoRefreshModifier: ViewModifier {
    let coordinator: FinanceSyncCoordinator?

    @Environment(\.scenePhase) private var scenePhase
    private let timer = Timer.publish(every: 60, on: .main, in: .common)
        .autoconnect()

    private var automaticTriggersEnabled: Bool {
        if !AppLockSettingsStore.isUITestLaunch() { return true }
        #if DEBUG
        // Online UI tests must push a quick-add. Every other in-memory
        // launch stays inert so smoke tests stay deterministic.
        return FinanceSyncUITestSupport.onlineEnabled(
            arguments: ProcessInfo.processInfo.arguments)
        #else
        return false
        #endif
    }

    func body(content: Content) -> some View {
        if automaticTriggersEnabled {
            content
                .task {
                    await coordinator?.syncIfStale()
                }
                .onChange(of: scenePhase) { _, phase in
                    guard phase == .active,
                          let coordinator, coordinator.enabled
                    else { return }
                    Task { await coordinator.syncIfStale() }
                }
                .onReceive(timer) { _ in
                    guard scenePhase == .active,
                          let coordinator, coordinator.enabled
                    else { return }
                    Task { await coordinator.syncIfStale() }
                }
                .onAppear {
                    coordinator?.startObservingLocalSaves()
                }
        } else {
            content
        }
    }
}

extension View {
    /// Runs the finance sync while this view is on screen — see
    /// `FinanceSyncCoordinator.syncIfStale` and `noteLocalSave`.
    func financeSyncAutoRefresh(
        _ coordinator: FinanceSyncCoordinator? = nil
    ) -> some View {
        modifier(FinanceSyncAutoRefreshModifier(coordinator: coordinator))
    }
}
