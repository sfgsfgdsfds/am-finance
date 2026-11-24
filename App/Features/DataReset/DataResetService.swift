import Foundation
import SwiftData

/// The two reset levels offered on `DataResetView`.
enum DataResetLevel: Equatable, Sendable {
    /// "Xoá toàn bộ giao dịch" — transactions only; everything else stays.
    case transactions
    /// "Xoá tất cả, về trạng thái ban đầu" — every model row, then reseed.
    case everything
}

/// Per-model row counts a reset deletes — gathered BEFORE the deletion so
/// the screen can show exact numbers and the success notice can report
/// what actually went.
struct DataResetSummary: Equatable, Sendable {
    /// One line per deleted model type, in `AppSchema` order.
    struct Row: Equatable, Sendable {
        /// Swift type name ("LedgerTransaction") — matches
        /// `String(describing:)` of the metatype, used by the schema
        /// coverage test.
        var modelName: String
        /// Vietnamese label for count text ("giao dịch").
        var displayName: String
        var count: Int
    }

    var rows: [Row] = []

    var total: Int { rows.reduce(0) { $0 + $1.count } }

    /// Deleted `LedgerTransaction` rows — level A's whole summary.
    var transactions: Int { count(of: "LedgerTransaction") }

    func count(of modelName: String) -> Int {
        rows.first { $0.modelName == modelName }?.count ?? 0
    }

    /// "1 tài khoản · 21 danh mục · 5 giao dịch" — empty types are left
    /// out; an entirely empty store reads "0 mục".
    var breakdownText: String {
        let parts = rows.filter { $0.count > 0 }
            .map { "\($0.count) \($0.displayName)" }
        return parts.isEmpty ? "0 mục" : parts.joined(separator: " · ")
    }
}

/// A failed reset — the message is shown verbatim in the error alert.
enum DataResetError: LocalizedError {
    case failed(any Error)

    var errorDescription: String? {
        switch self {
        case .failed(let error):
            return "Không xoá được dữ liệu: \(error.localizedDescription)"
        }
    }
}

/// The typed-confirmation rule: the destructive button enables only when
/// the input folds to "xoa" — "XOA", "XOÁ", "xoá"… all match through the
/// shared name normalizer (case- and diacritic-insensitive).
enum DataResetConfirmation {
    static func matches(_ input: String) -> Bool {
        SettingsNameNormalizer.fold(input) == "xoa"
    }
}

extension Notification.Name {
    /// Posted after a successful reset so the app can rebuild its root
    /// view tree — every screen drops references to deleted objects and
    /// the "Tổng quan" tab comes back selected.
    static let dataResetCompleted = Notification.Name(
        "vn.amx.finance.dataResetCompleted")
}

/// Performs the two "Xoá dữ liệu" resets.
///
/// Every model deletion lands in one context `save()`: level A deletes
/// `LedgerTransaction` rows directly (no tombstones — imports must come
/// back) and commits; level B calls `BackupRestorer.deleteAllRows` and
/// `SeedData.seedIfNeeded`, whose own save commits deletions and seed
/// inserts together — so both levels are atomic and a failure rolls back
/// with nothing deleted. The UserDefaults-backed stores are cleared only
/// after the commit (they cannot roll back anyway).
///
/// `save`/`seed` are seams: tests inject a throwing closure to prove a
/// failed commit deletes nothing. `seed` is where level B's commit really
/// happens — `SeedData.seedIfNeeded` wraps `context.save()`.
@MainActor
struct DataResetService {
    /// `@AppStorage` key of the quick-add editor's last-used account —
    /// written inside `TransactionEditorView`.
    static let lastUsedAccountDefaultsKey = "lastUsedTransactionAccountID"
    /// `@AppStorage` key of the last JSON export stamp — written inside
    /// `BackupView`.
    static let lastBackupDefaultsKey = "backupLastExportAt"

    /// The model types level B deletes, in `AppSchema` order — used for
    /// the summary rows and asserted against `AppSchema.allModels` by the
    /// coverage test, which fails if the schema grows past the reset.
    /// `BackupRestorer.deleteAllRows` performs the actual deletion and
    /// must stay in step with this list.
    static let resetModelSpecs: [(modelName: String, displayName: String)] = [
        ("Account", "tài khoản"),
        ("LedgerCategory", "danh mục"),
        ("Business", "mảng kinh doanh"),
        ("LedgerTransaction", "giao dịch"),
        ("LoanRateChange", "đợt đổi lãi suất"),
        ("Budget", "ngân sách"),
        ("RecurringRule", "quy tắc lặp lại"),
        ("RentalUnit", "phòng cho thuê"),
        ("RentalLease", "hợp đồng thuê"),
    ]

    let stateStore: any WalletSyncStateStoring
    let ruleStore: any WalletSyncRuleStoring
    let mappingStore: any CSVImportMappingStoring
    let batchStore: any CSVImportBatchStoring
    let basisStore: LoanInterestBasisStore
    let reminderSettings: ReminderSettingsStore
    let reminderCenter: any ReminderNotificationCentering
    /// Saved Agent conversations — they hold ledger excerpts, so both
    /// levels wipe them.
    let conversationStore: AIAgentConversationStore
    /// Plain defaults for the two `@AppStorage` scalars — the last-used
    /// account and the last-backup stamp have no store type of their own.
    let defaults: UserDefaults
    /// Commit seam — production saves the context; a test throws here to
    /// simulate a failed level-A save.
    var save: (ModelContext) throws -> Void = { try $0.save() }
    /// Reseed seam — production runs `SeedData.seedIfNeeded`; a test
    /// throws here to simulate level B's commit failing.
    var seed: (ModelContext) throws -> Void = {
        try SeedData.seedIfNeeded(context: $0)
    }

    init(
        stateStore: any WalletSyncStateStoring = WalletSyncStateStore(),
        ruleStore: any WalletSyncRuleStoring = WalletSyncRuleStore(),
        mappingStore: any CSVImportMappingStoring = CSVImportMappingStore(),
        batchStore: any CSVImportBatchStoring = CSVImportBatchStore(),
        basisStore: LoanInterestBasisStore = LoanInterestBasisStore(),
        reminderSettings: ReminderSettingsStore = ReminderSettingsStore(),
        reminderCenter: any ReminderNotificationCentering =
            ReminderUserNotificationCenter(),
        conversationStore: AIAgentConversationStore = .live(),
        defaults: UserDefaults = .standard
    ) {
        self.stateStore = stateStore
        self.ruleStore = ruleStore
        self.mappingStore = mappingStore
        self.batchStore = batchStore
        self.basisStore = basisStore
        self.reminderSettings = reminderSettings
        self.reminderCenter = reminderCenter
        self.conversationStore = conversationStore
        self.defaults = defaults
    }

    // MARK: - Counts

    /// Exactly what each level will delete — the screen shows these
    /// counts before the user confirms, so they must match the real
    /// deletion pass.
    func plannedSummary(
        for level: DataResetLevel, in context: ModelContext
    ) throws -> DataResetSummary {
        switch level {
        case .transactions:
            return DataResetSummary(rows: [DataResetSummary.Row(
                modelName: "LedgerTransaction",
                displayName: "giao dịch",
                count: try context.fetchCount(
                    FetchDescriptor<LedgerTransaction>())
            )])
        case .everything:
            return DataResetSummary(rows: [
                .init(modelName: "Account", displayName: "tài khoản",
                      count: try context.fetchCount(FetchDescriptor<Account>())),
                .init(modelName: "LedgerCategory", displayName: "danh mục",
                      count: try context.fetchCount(FetchDescriptor<LedgerCategory>())),
                .init(modelName: "Business", displayName: "mảng kinh doanh",
                      count: try context.fetchCount(FetchDescriptor<Business>())),
                .init(modelName: "LedgerTransaction", displayName: "giao dịch",
                      count: try context.fetchCount(FetchDescriptor<LedgerTransaction>())),
                .init(modelName: "LoanRateChange", displayName: "đợt đổi lãi suất",
                      count: try context.fetchCount(FetchDescriptor<LoanRateChange>())),
                .init(modelName: "Budget", displayName: "ngân sách",
                      count: try context.fetchCount(FetchDescriptor<Budget>())),
                .init(modelName: "RecurringRule", displayName: "quy tắc lặp lại",
                      count: try context.fetchCount(FetchDescriptor<RecurringRule>())),
                .init(modelName: "RentalUnit", displayName: "phòng cho thuê",
                      count: try context.fetchCount(FetchDescriptor<RentalUnit>())),
                .init(modelName: "RentalLease", displayName: "hợp đồng thuê",
                      count: try context.fetchCount(FetchDescriptor<RentalLease>())),
            ])
        }
    }

    // MARK: - Level A

    /// Deletes every `LedgerTransaction` in one save. Accounts keep their
    /// opening balance (the balance falls back to it), and every other
    /// model plus all settings stay. Then clears the bank-import memory —
    /// sync cursors back to the start and all tombstones gone — while the
    /// account links and their import-from dates survive, so the next
    /// sync re-imports history instead of resurrecting nothing.
    @discardableResult
    func resetTransactions(in context: ModelContext) throws -> DataResetSummary {
        do {
            let rows = try context.fetch(FetchDescriptor<LedgerTransaction>())
            for row in rows { context.delete(row) }
            try save(context)
            resetImportMemory(in: context)
            return DataResetSummary(rows: [DataResetSummary.Row(
                modelName: "LedgerTransaction",
                displayName: "giao dịch",
                count: rows.count
            )])
        } catch {
            context.rollback()
            throw DataResetError.failed(error)
        }
    }

    // MARK: - Level B

    /// Deletes every row of every model in `AppSchema`, then reseeds the
    /// defaults. `SeedData.seedIfNeeded`'s own `save()` is the level's
    /// single commit — it covers the pending deletions and the inserted
    /// seed rows atomically; the `save` seam after it normally has
    /// nothing left to write. On any failure `rollback` restores the
    /// store untouched.
    ///
    /// Also clears every app-owned state: wallet sync links/cursors/
    /// tombstones, auto-categorization rules, CSV mappings and undo
    /// batches, per-loan interest-basis keys, the saved Agent
    /// conversations, the last-used account, the last-backup stamp,
    /// the budget warning log and pending reminder notifications.
    /// Kept on purpose: the wallet sign-in and client id,
    /// reminder settings, app lock settings.
    @discardableResult
    func resetEverything(
        in context: ModelContext
    ) async throws -> DataResetSummary {
        do {
            let summary = try plannedSummary(for: .everything, in: context)
            try BackupRestorer.deleteAllRows(in: context)
            try seed(context)
            try save(context)
            clearOwnedState()
            await removePendingReminders()
            return summary
        } catch {
            context.rollback()
            throw DataResetError.failed(error)
        }
    }

    // MARK: - Store cleanup

    /// Level A: a re-import must see history again, so every stored sync
    /// state is dropped and re-created for the still-linked sessions with
    /// the start cursor — `importFrom` survives, `lastSyncAt` and the
    /// rescan stamp do not. Tombstones die with the wipe, so previously
    /// deleted rows import again too. The CSV "Hoàn tác lần nhập" memory
    /// also goes (its rows are gone anyway), and so do the saved Agent
    /// conversations — they quote ledger rows that no longer exist.
    private func resetImportMemory(in context: ModelContext) {
        var kept: [(sessionID: String, state: WalletSyncAccountState)] = []
        for (sessionID, _) in WalletSyncEngine.linkedAccounts(
            context: context
        ) {
            kept.append((sessionID, WalletSyncAccountState(
                importFrom: stateStore.state(for: sessionID).importFrom)))
        }
        stateStore.removeAll()
        for (sessionID, state) in kept {
            stateStore.setState(state, for: sessionID)
        }
        batchStore.removeAllBatches()
        // Agent history quotes ledger rows that no longer exist.
        conversationStore.deleteAll()
    }

    /// Level B: all app-owned UserDefaults state returns to first-launch.
    /// Wallet sign-in config, reminder settings and app-lock settings are
    /// deliberately not in this list.
    private func clearOwnedState() {
        stateStore.removeAll()
        ruleStore.saveRules([])
        mappingStore.removeAllMappings()
        batchStore.removeAllBatches()
        basisStore.removeAll()
        conversationStore.deleteAll()
        defaults.removeObject(forKey: Self.lastUsedAccountDefaultsKey)
        defaults.removeObject(forKey: Self.lastBackupDefaultsKey)
        // The warning log references budgets that no longer exist.
        reminderSettings.saveBudgetWarningLog(.empty)
    }

    /// Level B: pending reminder requests point at deleted debts, rules
    /// and budgets — remove ours, leave other apps' requests alone.
    private func removePendingReminders() async {
        let pending = await reminderCenter.pendingRequestIdentifiers()
        let ours = pending.filter {
            $0.hasPrefix(ReminderPlanner.identifierPrefix)
        }
        if !ours.isEmpty {
            reminderCenter.removePendingRequests(withIdentifiers: ours)
        }
    }
}
