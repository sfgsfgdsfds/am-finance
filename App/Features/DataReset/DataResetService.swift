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
/// Both levels act on the server: the service builds the backup-v5
/// document the ledger should become (level A = the current store with
/// every transaction removed; level B = `SeedData` defaults only), POSTs
/// it to `v1/backup/import` (REPLACE) and the caller reloads the online
/// store from the export. Device-local state that is not in the backup
/// — import cursors and tombstones, CSV memory, Agent conversations, and
/// on level B the rest of the owned defaults — is cleared only after the
/// import succeeds. When no server hook is set (previews and plain UI
/// tests), the same document is restored into the local context instead.
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
    /// POST the encoded backup-v5 document (`v1/backup/import` REPLACE).
    /// Nil in previews and plain UI tests — the document is restored
    /// locally instead. A throw leaves the device untouched.
    var importReplace: ((Data) async throws -> Void)?
    /// Runs after a successful import and the device-local cleanup.
    /// Production posts `.dataResetCompleted` and reloads from the
    /// export. Nil when the document was applied locally.
    var reload: ((DataResetSummary) async throws -> Void)?

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
        self.importReplace = nil
        self.reload = nil
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

    // MARK: - Document

    /// The backup-v5 document the server should hold after `level`.
    /// Level A is the current store with transactions removed (import
    /// memory is device-local and is not part of the document). Level B
    /// is a freshly seeded store — default categories, businesses and
    /// the "Tiền mặt" account, nothing else.
    func resultingDocument(
        for level: DataResetLevel,
        in context: ModelContext,
        now: Date = .now
    ) throws -> BackupDocument {
        switch level {
        case .transactions:
            var document = try BackupCodec.document(
                context: context, exportedAt: now)
            document.transactions = []
            return document
        case .everything:
            let scratch = try AppModelContainer.make(inMemory: true)
            let seeded = ModelContext(scratch)
            try SeedData.seedIfNeeded(context: seeded)
            return try BackupCodec.document(context: seeded, exportedAt: now)
        }
    }

    // MARK: - Apply

    /// Level A — transactions gone on the server, everything else kept.
    /// Then clears the bank-import memory (cursors back to the start,
    /// tombstones gone) while account links and their import-from dates
    /// survive, and wipes Agent conversations.
    @discardableResult
    func resetTransactions(
        in context: ModelContext
    ) async throws -> DataResetSummary {
        try await apply(.transactions, in: context)
    }

    /// Level B — the server is replaced by the seed document. Also
    /// clears every app-owned device state: wallet sync links/cursors/
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
        try await apply(.everything, in: context)
    }

    private func apply(
        _ level: DataResetLevel, in context: ModelContext
    ) async throws -> DataResetSummary {
        let summary = try plannedSummary(for: level, in: context)
        let document = try resultingDocument(for: level, in: context)
        if let importReplace {
            do {
                try await importReplace(try BackupCodec.encode(document))
            } catch {
                throw DataResetError.failed(error)
            }
        } else {
            do {
                _ = try BackupRestorer.restore(
                    document, mode: .replace, into: context)
            } catch {
                context.rollback()
                throw DataResetError.failed(error)
            }
        }
        switch level {
        case .transactions:
            resetImportMemory(in: context)
        case .everything:
            clearOwnedState()
            await removePendingReminders()
        }
        if let reload {
            do {
                try await reload(summary)
            } catch let error as DataResetError {
                throw error
            } catch {
                throw DataResetError.failed(error)
            }
        }
        return summary
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
