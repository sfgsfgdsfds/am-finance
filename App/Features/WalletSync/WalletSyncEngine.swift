import Foundation
import SwiftData
import FinanceCore

/// Imported/skipped counts for one linked account.
struct WalletSyncAccountResult: Equatable, Sendable {
    var sessionID: Int
    var inserted = 0
    var skippedExisting = 0
    var skippedTooOld = 0
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
}

/// Naming for auto-created linked accounts: "VPBank *1234".
enum WalletSyncNaming {
    static func accountName(bank: String, maskedNumber: String) -> String {
        let masked = maskedNumber.trimmingCharacters(in: .whitespacesAndNewlines)
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
@MainActor
struct WalletSyncEngine {
    /// `externalSource` marker on linked accounts and imported rows.
    static let externalSource = "wallet.amx.vn"

    let api: any WalletSyncAPI
    let stateStore: any WalletSyncStateStoring
    let ruleStore: any WalletSyncRuleStoring
    let context: ModelContext
    /// Page size per fetch — the server's maximum is 500.
    var pageSize = 500

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

    /// App accounts linked to the wallet, keyed by server session id.
    static func linkedAccounts(
        context: ModelContext
    ) -> [(sessionID: Int, account: Account)] {
        let accounts = (try? context.fetch(FetchDescriptor<Account>())) ?? []
        return accounts.compactMap { account in
            guard account.externalSource == externalSource,
                  let raw = account.externalAccountID,
                  let sessionID = Int(raw)
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
    @discardableResult
    func syncAll(now: Date = .now) async throws -> WalletSyncSummary {
        let linked = Self.linkedAccounts(context: context)
        guard !linked.isEmpty else { throw WalletSyncError.noLinkedAccounts }
        var summary = WalletSyncSummary()
        for (sessionID, account) in linked {
            summary.accounts.append(
                try await syncAccount(sessionID: sessionID, account: account, now: now))
        }
        return summary
    }

    /// One account's page loop: fetch → insert → save → advance cursor.
    private func syncAccount(
        sessionID: Int, account: Account, now: Date
    ) async throws -> WalletSyncAccountResult {
        var state = stateStore.state(for: sessionID)
        var cursor = state.cursor
        var result = WalletSyncAccountResult(sessionID: sessionID)
        var known = knownExternalIDs(of: account)
        let rules = ruleStore.loadRules()
        let categories = Dictionary(
            ((try? context.fetch(FetchDescriptor<LedgerCategory>())) ?? []).map { ($0.id, $0) },
            uniquingKeysWith: { first, _ in first })
        let businesses = Dictionary(
            ((try? context.fetch(FetchDescriptor<Business>())) ?? []).map { ($0.id, $0) },
            uniquingKeysWith: { first, _ in first })
        let accounts = Dictionary(
            ((try? context.fetch(FetchDescriptor<Account>())) ?? []).map { ($0.id, $0) },
            uniquingKeysWith: { first, _ in first })

        while true {
            let page = try await api.transactions(
                sessionID: sessionID, afterID: cursor, limit: pageSize)

            for item in page.items where item.sessionId == sessionID {
                let externalID = String(item.id)
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
                WalletSyncRuleApplier.apply(
                    to: transaction,
                    rules: rules,
                    categories: categories,
                    businesses: businesses,
                    accounts: accounts
                )
                result.inserted += 1
            }

            // Commit the page first; the cursor only advances after a
            // successful save, so a crash or API failure next page cannot
            // skip rows.
            try context.save()

            let previous = cursor
            if let next = page.meta.nextAfterId ?? page.items.last?.id,
               next > cursor {
                cursor = next
            }
            state.cursor = cursor
            state.lastSyncAt = now
            stateStore.setState(state, for: sessionID)

            // A cursor that cannot advance would page forever.
            guard page.meta.hasMore, cursor > previous else { break }
        }
        return result
    }

    /// Every `externalID` the account already holds — as source and, for
    /// rows converted to transfers, as destination too.
    private func knownExternalIDs(of account: Account) -> Set<String> {
        var known = Set<String>()
        for transaction in (account.transactions ?? []) + (account.incomingTransfers ?? []) {
            guard transaction.externalSource == Self.externalSource,
                  let id = transaction.externalID else { continue }
            known.insert(id)
        }
        return known
    }

    /// Overflow-safe |amount|: Int64.min has no positive counterpart.
    private func magnitude(of amount: Int64) -> Int64 {
        amount == Int64.min ? Int64.max : abs(amount)
    }
}
