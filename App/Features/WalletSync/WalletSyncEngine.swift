import Foundation
import SwiftData
import FinanceCore

/// Imported/skipped counts for one linked account.
struct WalletSyncAccountResult: Equatable, Sendable {
    /// Server session UUID of the linked account.
    var sessionID: String
    var inserted = 0
    var skippedExisting = 0
    var skippedTooOld = 0
    /// The rows this account committed, in import order — for callers
    /// (background refresh) that need to know exactly which transactions
    /// a sync inserted without re-reading the store.
    var insertedRows: [WalletSyncInsertedTransaction] = []
}

/// A bank row a sync just inserted — enough for local notifications and
/// tests without handing out the SwiftData object.
struct WalletSyncInsertedTransaction: Equatable, Sendable {
    /// The server's transaction UUID — stable, unique per import.
    var externalID: String
    /// Server session UUID of the linked account the row landed on.
    var sessionID: String
    /// Display name of the app account at insert time ("VPBank *1234").
    var accountName: String
    /// The server's signed amount — positive is money in, negative out.
    var signedAmount: Int64
    var date: Date
    /// The bank note, "" when the server sent none.
    var note: String
}

/// Result of `WalletSyncEngine.syncAll` — one entry per linked account.
struct WalletSyncSummary: Equatable, Sendable {
    var accounts: [WalletSyncAccountResult] = []

    var totalInserted: Int {
        accounts.reduce(0) { $0 + $1.inserted }
    }

    var totalSkipped: Int {
        accounts.reduce(0) { $0 + $1.skippedExisting + $1.skippedTooOld }
    }

    /// Every row the run committed, across all linked accounts.
    var insertedRows: [WalletSyncInsertedTransaction] {
        accounts.flatMap(\.insertedRows)
    }
}

/// Naming for auto-created linked accounts: "VPBank *1234".
enum WalletSyncNaming {
    static func accountName(bank: String, maskedNumber: String?) -> String {
        let masked = maskedNumber?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return masked.isEmpty ? bank : "\(bank) \(masked)"
    }
}

/// Pulls new VPBank transactions from wallet.amx.vn into the ledger.
///
/// For every linked account the engine pages forward from the stored
/// cursor, filters out rows older than the link's import-from date and rows
/// already imported, inserts the rest, applies the auto-rules — then saves
/// and only then advances the cursor. Pages are committed one at a time, so
/// a failure mid-sync never loses or duplicates rows.
///
/// Self-healing: two rows written by different server processes in the
/// same millisecond can become visible out of id order, which a pure id
/// cursor would miss forever. So each account also rescans from the "0"
/// cursor — at most once every `fullRescanInterval`, or whenever the
/// caller forces it. Dedupe by `externalID` keeps the rescan idempotent.
///
/// The engine is actor-agnostic: it works on whichever `ModelContext` it
/// is given, so the foreground coordinator hands it a worker context and
/// a 30k-row import never blocks the UI. `@unchecked Sendable` because a
/// `ModelContext` is only safe on one executor at a time — each call site
/// owns its context for the duration of the sync (worker or runner).
struct WalletSyncEngine: @unchecked Sendable {
    /// `externalSource` marker on linked accounts and imported rows.
    static let externalSource = "wallet.amx.vn"
    /// Minimum gap between two automatic full rescans — one day.
    static let fullRescanInterval: TimeInterval = 24 * 60 * 60

    let api: any WalletSyncAPI
    let stateStore: any WalletSyncStateStoring
    let ruleStore: any WalletSyncRuleStoring
    let context: ModelContext
    /// Page size per fetch — the server's maximum is 500.
    var pageSize = 500
    /// Fired after each page is committed — lets a caller collect the rows
    /// that actually landed even when a later page fails and `syncAll`
    /// throws (those committed rows are still new imports).
    var onPageCommitted: (@Sendable ([WalletSyncInsertedTransaction]) -> Void)?

    init(
        api: any WalletSyncAPI,
        stateStore: any WalletSyncStateStoring,
        ruleStore: any WalletSyncRuleStoring,
        context: ModelContext
    ) {
        self.api = api
        self.stateStore = stateStore
        self.ruleStore = ruleStore
        self.context = context
    }

    // MARK: - Lookups

    /// App accounts linked to the wallet, keyed by server session UUID.
    static func linkedAccounts(
        context: ModelContext
    ) -> [(sessionID: String, account: Account)] {
        let accounts = (try? context.fetch(FetchDescriptor<Account>())) ?? []
        return accounts.compactMap { account in
            guard account.externalSource == externalSource,
                  let sessionID = account.externalAccountID,
                  !sessionID.isEmpty
            else { return nil }
            return (sessionID, account)
        }
        .sorted { $0.sessionID < $1.sessionID }
    }

    /// Rows still waiting for the user to categorize them.
    static func pendingReviewCount(context: ModelContext) -> Int {
        (try? context.fetchCount(FetchDescriptor<LedgerTransaction>(
            predicate: #Predicate { $0.needsReview == true }))) ?? 0
    }

    /// Rows the sync ever imported — they keep the marker after unlinking.
    static func importedCount(context: ModelContext) -> Int {
        let source = externalSource
        return (try? context.fetchCount(FetchDescriptor<LedgerTransaction>(
            predicate: #Predicate { $0.externalSource == source }))) ?? 0
    }

    // MARK: - Sync

    /// Syncs every linked account, in session-id order. The first API or
    /// save error aborts the whole run; earlier pages stay committed.
    /// `fullRescan` forces every account to re-read from the "0" cursor —
    /// the manual "Đồng bộ lại toàn bộ" action.
    @discardableResult
    func syncAll(now: Date = .now, fullRescan: Bool = false) async throws -> WalletSyncSummary {
        let linked = Self.linkedAccounts(context: context)
        guard !linked.isEmpty else { throw WalletSyncError.noLinkedAccounts }
        // One fetch per sync: every externalID ever imported (on any
        // account) or tombstoned blocks a re-import.
        var known = knownExternalIDs()
        // Per-sync rule + lookup fetches — once, not per linked account.
        let rules = WalletSyncCompiledRules(rules: ruleStore.loadRules())
        let categories = Dictionary(
            ((try? context.fetch(FetchDescriptor<LedgerCategory>())) ?? []).map { ($0.id, $0) },
            uniquingKeysWith: { first, _ in first })
        let businesses = Dictionary(
            ((try? context.fetch(FetchDescriptor<Business>())) ?? []).map { ($0.id, $0) },
            uniquingKeysWith: { first, _ in first })
        let accounts = Dictionary(
            ((try? context.fetch(FetchDescriptor<Account>())) ?? []).map { ($0.id, $0) },
            uniquingKeysWith: { first, _ in first })
        var summary = WalletSyncSummary()
        for (sessionID, account) in linked {
            summary.accounts.append(
                try await syncAccount(
                    sessionID: sessionID, account: account, now: now,
                    fullRescan: fullRescan, known: &known,
                    rules: rules, categories: categories,
                    businesses: businesses, accounts: accounts))
        }
        return summary
    }

    /// One account's page loop: fetch → insert → save → advance cursor.
    private func syncAccount(
        sessionID: String, account: Account, now: Date, fullRescan: Bool,
        known: inout Set<String>,
        rules: WalletSyncCompiledRules,
        categories: [UUID: LedgerCategory],
        businesses: [UUID: Business],
        accounts: [UUID: Account]
    ) async throws -> WalletSyncAccountResult {
        var state = stateStore.state(for: sessionID)
        // A nil `lastFullRescanAt` means this account never scanned from
        // the start — the first sync after linking counts as the rescan.
        let rescan = fullRescan || state.lastFullRescanAt
            .map({ now.timeIntervalSince($0) >= Self.fullRescanInterval }) ?? true
        var cursor = rescan ? WalletSyncAccountState.startCursor : state.cursor
        var result = WalletSyncAccountResult(sessionID: sessionID)

        while true {
            // Honours task expiration between committed pages — a
            // background run can be cut short at any point.
            try Task.checkCancellation()
            let page = try await api.transactions(
                sessionID: sessionID, afterID: cursor, limit: pageSize)

            var pageInserted: [WalletSyncInsertedTransaction] = []
            for item in page.items where item.sessionId == sessionID {
                let externalID = item.id
                if let importFrom = state.importFrom,
                   item.transactionDate < importFrom {
                    result.skippedTooOld += 1
                    continue
                }
                if !known.insert(externalID).inserted {
                    result.skippedExisting += 1
                    continue
                }
                let transaction = LedgerTransaction(
                    kind: item.amount > 0 ? .income : .expense,
                    amount: magnitude(of: item.amount),
                    date: item.transactionDate,
                    note: item.note ?? "",
                    account: account,
                    needsReview: true
                )
                transaction.externalSource = Self.externalSource
                transaction.externalID = externalID
                context.insert(transaction)
                rules.apply(
                    to: transaction,
                    categories: categories,
                    businesses: businesses,
                    accounts: accounts
                )
                result.inserted += 1
                pageInserted.append(WalletSyncInsertedTransaction(
                    externalID: externalID,
                    sessionID: sessionID,
                    accountName: account.name,
                    signedAmount: item.amount,
                    date: item.transactionDate,
                    note: item.note ?? ""))
            }

            // Commit the page first; the cursor only advances after a
            // successful save, so a crash or API failure next page cannot
            // skip rows.
            try context.save()
            result.insertedRows.append(contentsOf: pageInserted)
            onPageCommitted?(pageInserted)

            let previous = cursor
            // `next_after_id` echoes the sent cursor on an empty page —
            // the `>` check keeps the cursor from ever moving backwards.
            if page.meta.nextAfterId > cursor {
                cursor = page.meta.nextAfterId
            }
            state.cursor = cursor
            state.lastSyncAt = now
            stateStore.setState(state, for: sessionID)

            // A cursor that cannot advance would page forever.
            guard page.meta.hasMore, cursor > previous else { break }
        }
        // Only a completed rescan counts — a failed one restarts from the
        // beginning next time, which dedupe makes safe.
        if rescan {
            state.lastFullRescanAt = now
            stateStore.setState(state, for: sessionID)
        }
        return result
    }

    /// Every `externalID` the ledger already holds for this source, on
    /// any account — a row the user moved to another account still blocks
    /// a duplicate — plus every tombstoned id, so a deleted import is
    /// never resurrected.
    private func knownExternalIDs() -> Set<String> {
        let source = Self.externalSource
        let rows = (try? context.fetch(FetchDescriptor<LedgerTransaction>(
            predicate: #Predicate { $0.externalSource == source }))) ?? []
        var known = Set(rows.compactMap(\.externalID))
        known.formUnion(stateStore.tombstonedIDs(source: source))
        return known
    }

    /// Overflow-safe |amount|: Int64.min has no positive counterpart.
    private func magnitude(of amount: Int64) -> Int64 {
        amount == Int64.min ? Int64.max : abs(amount)
    }
}

/// A `ModelActor` that runs `WalletSyncEngine.syncAll` on its own context
/// and executor — the foreground import path. Everything the engine
/// touches (linked accounts, inserted rows, page saves) stays on the
/// worker's context; the main actor only awaits the summary.
@ModelActor
actor WalletSyncWorker {
    func syncAll(
        api: any WalletSyncAPI,
        stateStore: any WalletSyncStateStoring,
        ruleStore: any WalletSyncRuleStoring,
        now: Date = .now,
        fullRescan: Bool = false
    ) async throws -> WalletSyncSummary {
        let engine = WalletSyncEngine(
            api: api,
            stateStore: stateStore,
            ruleStore: ruleStore,
            context: modelContext
        )
        return try await engine.syncAll(now: now, fullRescan: fullRescan)
    }
}
