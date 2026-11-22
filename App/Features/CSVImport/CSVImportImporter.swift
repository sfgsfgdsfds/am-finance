import Foundation
import SwiftData

/// The rows of one successful import — kept per account so the last batch
/// can be undone with a single confirmation.
struct CSVImportBatch: Equatable, Codable, Sendable {
    var ids: [UUID]
    var importedAt: Date
}

/// Storage seam for the remembered last import batch — UserDefaults in
/// the app, in-memory in tests.
protocol CSVImportBatchStoring: Sendable {
    func batch(for accountID: UUID) -> CSVImportBatch?
    func setBatch(_ batch: CSVImportBatch, for accountID: UUID)
    func clearBatch(for accountID: UUID)
}

/// One JSON blob `[accountUUID: batch]` in UserDefaults.
final class CSVImportBatchStore: CSVImportBatchStoring, @unchecked Sendable {
    static let key = "csvImport.lastBatches"

    let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    private var all: [String: CSVImportBatch] {
        get {
            guard let data = defaults.data(forKey: Self.key),
                  let decoded = try? JSONDecoder().decode(
                      [String: CSVImportBatch].self, from: data)
            else { return [:] }
            return decoded
        }
        set {
            defaults.set(try? JSONEncoder().encode(newValue), forKey: Self.key)
        }
    }

    func batch(for accountID: UUID) -> CSVImportBatch? {
        all[accountID.uuidString]
    }

    func setBatch(_ batch: CSVImportBatch, for accountID: UUID) {
        var copy = all
        copy[accountID.uuidString] = batch
        all = copy
    }

    func clearBatch(for accountID: UUID) {
        var copy = all
        copy.removeValue(forKey: accountID.uuidString)
        all = copy
    }
}

/// Volatile `CSVImportBatchStoring` for tests and previews.
final class CSVImportInMemoryBatchStore: CSVImportBatchStoring, @unchecked Sendable {
    private var batches: [UUID: CSVImportBatch] = [:]

    init() {}

    func batch(for accountID: UUID) -> CSVImportBatch? {
        batches[accountID]
    }

    func setBatch(_ batch: CSVImportBatch, for accountID: UUID) {
        batches[accountID] = batch
    }

    func clearBatch(for accountID: UUID) {
        batches.removeValue(forKey: accountID)
    }
}

/// What one import did.
struct CSVImportOutcome: Equatable, Sendable {
    var inserted = 0
    var skippedDuplicates = 0
}

/// Inserts parsed statement rows as `LedgerTransaction`s.
///
/// Dedupe is by `externalID` against every "csv"-sourced row already in
/// the ledger plus the tombstones kept by the shared sync state store —
/// a row deleted through `LedgerTransactionDeletion` never comes back on
/// a re-import, and importing the same file twice inserts nothing.
/// Matching `WalletSyncRule`s categorize/convert rows exactly like the
/// bank sync does; anything left unmatched stays `needsReview`.
///
/// One save covers the whole batch, and the inserted ids are remembered
/// per account for "Hoàn tác lần nhập gần nhất".
@MainActor
struct CSVImportImporter {
    let context: ModelContext
    let ruleStore: any WalletSyncRuleStoring
    let stateStore: any WalletSyncStateStoring
    let batchStore: any CSVImportBatchStoring

    init(
        context: ModelContext,
        ruleStore: any WalletSyncRuleStoring = WalletSyncRuleStore(),
        stateStore: any WalletSyncStateStoring = WalletSyncStateStore(),
        batchStore: any CSVImportBatchStoring = CSVImportBatchStore()
    ) {
        self.context = context
        self.ruleStore = ruleStore
        self.stateStore = stateStore
        self.batchStore = batchStore
    }

    /// Every `externalID` the import must not write again: rows already
    /// imported (on any account — a moved row still blocks) plus deleted
    /// ones tombstoned for this source.
    func knownIDs() -> Set<String> {
        let source = CSVImportDeduper.externalSource
        let rows = (try? context.fetch(FetchDescriptor<LedgerTransaction>(
            predicate: #Predicate { $0.externalSource == source }))) ?? []
        var known = Set(rows.compactMap(\.externalID))
        known.formUnion(stateStore.tombstonedIDs(source: source))
        return known
    }

    /// Assigns ids and splits drafts into importable vs. already-known —
    /// the numbers step 3 shows before the user confirms.
    func prepare(
        drafts: [CSVImportDraft],
        account: Account,
        calendar: Calendar = AppCalendar.vietnam
    ) -> (importable: [CSVImportDraft], skipped: Int) {
        var assigned = drafts
        CSVImportDeduper.assignIDs(
            to: &assigned, accountID: account.id, calendar: calendar)
        return CSVImportDeduper.droppingDuplicates(
            of: assigned, known: knownIDs())
    }

    /// Inserts the importable drafts in one save. Returns what happened;
    /// inserting zero rows still replaces the remembered batch (with an
    /// empty one), since the previous undo target is then stale anyway.
    @discardableResult
    func `import`(
        drafts: [CSVImportDraft],
        into account: Account,
        calendar: Calendar = AppCalendar.vietnam
    ) throws -> CSVImportOutcome {
        let (importable, skipped) = prepare(drafts: drafts, account: account,
                                            calendar: calendar)
        let rules = ruleStore.loadRules()
        let categories = Dictionary(
            ((try? context.fetch(FetchDescriptor<LedgerCategory>())) ?? [])
                .map { ($0.id, $0) },
            uniquingKeysWith: { first, _ in first })
        let businesses = Dictionary(
            ((try? context.fetch(FetchDescriptor<Business>())) ?? [])
                .map { ($0.id, $0) },
            uniquingKeysWith: { first, _ in first })
        let accounts = Dictionary(
            ((try? context.fetch(FetchDescriptor<Account>())) ?? [])
                .map { ($0.id, $0) },
            uniquingKeysWith: { first, _ in first })

        var insertedIDs: [UUID] = []
        for draft in importable {
            let transaction = LedgerTransaction(
                kind: draft.signedAmount >= 0 ? .income : .expense,
                amount: draft.signedAmount == Int64.min
                    ? Int64.max : abs(draft.signedAmount),
                date: draft.date,
                note: draft.note,
                account: account,
                needsReview: true
            )
            transaction.externalSource = CSVImportDeduper.externalSource
            transaction.externalID = draft.externalID
            context.insert(transaction)
            WalletSyncRuleApplier.apply(
                to: transaction,
                rules: rules,
                categories: categories,
                businesses: businesses,
                accounts: accounts)
            insertedIDs.append(transaction.id)
        }

        try context.save()
        batchStore.setBatch(
            CSVImportBatch(ids: insertedIDs, importedAt: .now),
            for: account.id)
        return CSVImportOutcome(
            inserted: insertedIDs.count, skippedDuplicates: skipped)
    }

    /// Deletes the remembered last batch for `account`, row by row
    /// through the shared delete helper so the ids are tombstoned and a
    /// later import does not resurrect them. Returns the count deleted.
    @discardableResult
    func undoLastBatch(for account: Account) -> Int {
        guard let batch = batchStore.batch(for: account.id),
              !batch.ids.isEmpty
        else { return 0 }
        let source = CSVImportDeduper.externalSource
        let ids = Set(batch.ids)
        let rows = (try? context.fetch(FetchDescriptor<LedgerTransaction>(
            predicate: #Predicate { $0.externalSource == source }))) ?? []
        var deleted = 0
        for row in rows where ids.contains(row.id) {
            LedgerTransactionDeletion.delete(
                row, in: context, tombstones: stateStore)
            deleted += 1
        }
        try? context.save()
        batchStore.clearBatch(for: account.id)
        return deleted
    }
}
