import Testing
import Foundation
import SwiftData
import FinanceCore
@testable import AMFinance

/// Minimal `ReminderNotificationCentering` fake — records removals and
/// keeps a mutable pending queue, like `ReminderFakeCenter` in
/// RemindersTests but only the parts the reset uses.
private final class DataResetFakeCenter: ReminderNotificationCentering,
    @unchecked Sendable {
    var pending: [String] = []
    var removed: [String] = []

    func authorizationStatus() async -> ReminderAuthorizationStatus { .authorized }
    func requestAuthorization() async throws -> Bool { true }
    func pendingRequestIdentifiers() async -> [String] { pending }
    func removePendingRequests(withIdentifiers identifiers: [String]) {
        removed += identifiers
        let drop = Set(identifiers)
        pending.removeAll { drop.contains($0) }
    }
    func schedule(
        _ notification: ReminderPlannedNotification, calendar: Calendar
    ) async throws {
        pending.append(notification.id)
    }
    func scheduleTest(
        identifier: String, title: String, body: String,
        inSeconds seconds: TimeInterval
    ) async throws {
        pending.append(identifier)
    }
}

private enum DataResetTestError: Error {
    case commitFailed
}

@MainActor
struct DataResetTests {

    private let calendar = AppCalendar.vietnam

    private func makeContext() throws -> ModelContext {
        ModelContext(try AppModelContainer.make(inMemory: true))
    }

    private func makeDefaults() -> UserDefaults {
        UserDefaults(suiteName: "DataResetTests.\(UUID().uuidString)")!
    }

    private func makeService(
        defaults: UserDefaults,
        stateStore: WalletSyncInMemoryStateStore =
            WalletSyncInMemoryStateStore(),
        ruleStore: WalletSyncInMemoryRuleStore =
            WalletSyncInMemoryRuleStore(),
        mappingStore: CSVImportInMemoryMappingStore =
            CSVImportInMemoryMappingStore(),
        batchStore: CSVImportInMemoryBatchStore =
            CSVImportInMemoryBatchStore(),
        reminderCenter: any ReminderNotificationCentering =
            DataResetFakeCenter(),
        conversationStore: AIAgentConversationStore =
            AIAgentConversationStore(
                directory: FileManager.default.temporaryDirectory
                    .appendingPathComponent(
                        "DataResetTests-conv-\(UUID().uuidString)",
                        isDirectory: true))
    ) -> DataResetService {
        DataResetService(
            stateStore: stateStore,
            ruleStore: ruleStore,
            mappingStore: mappingStore,
            batchStore: batchStore,
            basisStore: LoanInterestBasisStore(defaults: defaults),
            reminderSettings: ReminderSettingsStore(defaults: defaults),
            reminderCenter: reminderCenter,
            conversationStore: conversationStore,
            defaults: defaults)
    }

    /// A temp-directory conversation store holding one saved record —
    /// the reset levels must erase it.
    private func makeConversationStore(
        _ name: String
    ) throws -> AIAgentConversationStore {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(
                "DataResetTests-\(name)-\(UUID().uuidString)",
                isDirectory: true)
        try FileManager.default.createDirectory(
            at: directory, withIntermediateDirectories: true)
        let store = AIAgentConversationStore(directory: directory)
        var state = AIAgentConversationState()
        state.messages.append(AIAgentChatMessage(
            kind: .user, text: "lịch sử"))
        state.messages.append(AIAgentChatMessage(
            kind: .assistant, text: "trả lời"))
        let record = try #require(
            AIAgentConversationStore.makeRecord(for: state))
        store.save(record)
        try #require(store.list().count == 1)
        return store
    }

    private func fetchAll<T: PersistentModel>(
        _ type: T.Type, in context: ModelContext
    ) throws -> [T] {
        try context.fetch(FetchDescriptor<T>())
    }

    /// A wallet-linked bank account: the `externalSource`/`externalAccountID`
    /// pair is the link level A must keep.
    @discardableResult
    private func linkedAccount(
        in context: ModelContext,
        sessionID: String,
        openingBalance: Int64
    ) -> Account {
        let account = Account(
            name: "VPBank *1234", kind: .bank,
            openingBalance: openingBalance)
        account.externalSource = WalletSyncEngine.externalSource
        account.externalAccountID = sessionID
        context.insert(account)
        return account
    }

    // MARK: - Level A

    @Test func levelARemovesOnlyTransactions() async throws {
        let context = try makeContext()
        try SeedData.seedIfNeeded(context: context)
        let defaults = makeDefaults()
        let states = WalletSyncInMemoryStateStore()
        let rules = WalletSyncInMemoryRuleStore()
        let mappings = CSVImportInMemoryMappingStore()
        let batches = CSVImportInMemoryBatchStore()
        let conversations = try makeConversationStore("levelA")
        let service = makeService(
            defaults: defaults, stateStore: states, ruleStore: rules,
            mappingStore: mappings, batchStore: batches,
            conversationStore: conversations)

        let sessionID = "sess-1"
        let bank = linkedAccount(
            in: context, sessionID: sessionID, openingBalance: 5_000_000)
        let cash = try #require(
            try fetchAll(Account.self, in: context).first { $0.kind == .cash })
        let category = try #require(
            try fetchAll(LedgerCategory.self, in: context).first {
                $0.kind == .expense
            })
        context.insert(LedgerTransaction(
            kind: .expense, amount: 150_000,
            account: bank, category: category))
        context.insert(LedgerTransaction(
            kind: .income, amount: 3_000_000,
            account: cash, category: category))
        // Other models that must survive level A.
        let loan = Account(name: "Vay", kind: .loan, openingBalance: -1_000_000)
        context.insert(loan)
        context.insert(LoanRateChange(
            fromInstallment: 2, annualRatePercent: 9, account: loan))
        context.insert(Budget(monthlyLimit: 1_000_000, category: category))
        context.insert(RecurringRule(
            title: "Thuê nhà", kind: .expense, amount: 5_000_000,
            account: cash, category: category,
            frequency: .monthly, startDate: .now))
        let unit = RentalUnit(name: "Phòng 101")
        context.insert(unit)
        context.insert(RentalLease(tenantName: "A", unit: unit))
        try context.save()

        // Import memory: sync state with cursor + importFrom, tombstones
        // for both sources, a remembered CSV batch. Rules and mappings
        // exist too — level A keeps them.
        let importFrom = calendar.startOfDay(
            for: calendar.date(byAdding: .day, value: -30, to: .now)!)
        states.setState(WalletSyncAccountState(
            cursor: "cur-99", importFrom: importFrom,
            lastSyncAt: .now, lastFullRescanAt: .now), for: sessionID)
        states.recordTombstones(["w1", "w2"],
                                source: WalletSyncEngine.externalSource)
        states.recordTombstones(["c1"], source: CSVImportDeduper.externalSource)
        batches.setBatch(
            CSVImportBatch(ids: [UUID()], importedAt: .now), for: bank.id)
        rules.saveRules([WalletSyncRule(
            keyword: "cafe", action: .category(category.id))])
        mappings.saveMapping(
            CSVImportSavedMapping(
                from: CSVImportMapping(
                    dateColumn: 0, amountColumn: 1, descriptionColumn: 2),
                headers: ["d", "a", "n"]),
            for: bank.id)

        let summary = try await service.resetTransactions(in: context)

        // Transactions gone — every other model untouched.
        #expect(summary.transactions == 2)
        #expect(summary.total == 2)
        #expect(try fetchAll(LedgerTransaction.self, in: context).isEmpty)
        #expect(
            try context.fetchCount(FetchDescriptor<LoanRateChange>()) == 1)
        #expect(try context.fetchCount(FetchDescriptor<Budget>()) == 1)
        #expect(
            try context.fetchCount(FetchDescriptor<RecurringRule>()) == 1)
        #expect(try context.fetchCount(FetchDescriptor<RentalUnit>()) == 1)
        #expect(try context.fetchCount(FetchDescriptor<RentalLease>()) == 1)
        #expect(try context.fetchCount(FetchDescriptor<LedgerCategory>())
            == 21)

        // Balance falls back to the opening balance; the link survives.
        let reloaded = try #require(
            try fetchAll(Account.self, in: context).first { $0.id == bank.id })
        #expect(reloaded.balance == 5_000_000)
        #expect(reloaded.externalSource == WalletSyncEngine.externalSource)
        #expect(reloaded.externalAccountID == sessionID)

        // Cursors + tombstones cleared; link state kept with importFrom.
        let state = states.state(for: sessionID)
        #expect(state.cursor == WalletSyncAccountState.startCursor)
        #expect(state.importFrom == importFrom)
        #expect(state.lastSyncAt == nil)
        #expect(state.lastFullRescanAt == nil)
        #expect(states.tombstonedIDs(
            source: WalletSyncEngine.externalSource).isEmpty)
        #expect(states.tombstonedIDs(
            source: CSVImportDeduper.externalSource).isEmpty)

        // CSV batch memory gone; rules and mappings kept.
        #expect(batches.batch(for: bank.id) == nil)
        #expect(rules.loadRules().count == 1)
        #expect(mappings.mapping(for: bank.id) != nil)

        // The saved Agent conversations are wiped — they quoted the
        // deleted ledger rows.
        #expect(conversations.list().isEmpty)
    }

    // MARK: - Level B

    @Test func levelBLeavesOnlySeedRowsAndClearsStores() async throws {
        let context = try makeContext()
        try SeedData.seedIfNeeded(context: context)
        let defaults = makeDefaults()
        let states = WalletSyncInMemoryStateStore()
        let rules = WalletSyncInMemoryRuleStore()
        let mappings = CSVImportInMemoryMappingStore()
        let batches = CSVImportInMemoryBatchStore()
        let center = DataResetFakeCenter()
        let basisStore = LoanInterestBasisStore(defaults: defaults)
        let reminderSettings = ReminderSettingsStore(defaults: defaults)
        let conversations = try makeConversationStore("levelB")
        let service = DataResetService(
            stateStore: states, ruleStore: rules, mappingStore: mappings,
            batchStore: batches, basisStore: basisStore,
            reminderSettings: reminderSettings, reminderCenter: center,
            conversationStore: conversations,
            defaults: defaults)

        // Extra rows on top of the seed — one of every model.
        let bank = linkedAccount(
            in: context, sessionID: "sess-1", openingBalance: 5_000_000)
        let loan = Account(name: "Vay", kind: .loan)
        context.insert(loan)
        context.insert(LedgerCategory(
            name: "Cafe", kind: .expense, sortOrder: 99))
        context.insert(Business(name: "Thêm", sortOrder: 9))
        context.insert(LedgerTransaction(
            kind: .expense, amount: 10_000, account: bank))
        context.insert(LoanRateChange(
            fromInstallment: 3, annualRatePercent: 8, account: loan))
        context.insert(Budget(monthlyLimit: 500_000))
        context.insert(RecurringRule(
            title: "R", kind: .expense, amount: 1,
            frequency: .monthly, startDate: .now))
        let unit = RentalUnit(name: "P1")
        context.insert(unit)
        context.insert(RentalLease(tenantName: "T", unit: unit))
        try context.save()

        // Every store the level must clear.
        states.setState(WalletSyncAccountState(
            cursor: "cur-1", importFrom: .now, lastSyncAt: .now),
            for: "sess-1")
        states.recordTombstones(
            ["t1"], source: WalletSyncEngine.externalSource)
        rules.saveRules([WalletSyncRule(
            keyword: "x", action: .business(UUID()))])
        mappings.saveMapping(
            CSVImportSavedMapping(
                from: CSVImportMapping(dateColumn: 0),
                headers: ["d"]),
            for: bank.id)
        batches.setBatch(
            CSVImportBatch(ids: [UUID()], importedAt: .now), for: bank.id)
        basisStore.set(.monthly, for: loan.id)
        defaults.set(bank.id.uuidString,
                     forKey: DataResetService.lastUsedAccountDefaultsKey)
        defaults.set(Date.now.timeIntervalSince1970,
                     forKey: DataResetService.lastBackupDefaultsKey)
        reminderSettings.saveBudgetWarningLog(ReminderBudgetWarningLog(
            monthKey: "2026-11", budgetIDs: [UUID()]))
        center.pending = [
            "\(ReminderPlanner.identifierPrefix)debt.a.0",
            "\(ReminderPlanner.identifierPrefix)recurring.b.0",
            "some.other.notification",
        ]

        // Stores the level must KEEP — sign-in config, reminder
        // settings, app-lock settings.
        let configStore = WalletLinkConfigStore(defaults: defaults)
        var config = WalletLinkConfig.default
        config.clientID = "cli_test"
        configStore.save(config)
        var keptReminders = ReminderSettings.default
        keptReminders.isEnabled = true
        keptReminders.notificationHour = 7
        reminderSettings.save(keptReminders)
        let lockStore = AppLockSettingsStore(defaults: defaults)
        lockStore.save(AppLockSettings(
            isEnabled: true, delay: .fiveMinutes,
            hideInAppSwitcher: false))

        let summary = try await service.resetEverything(in: context)

        // Exactly the seed rows are back — compare against a freshly
        // seeded oracle store so the test survives seed edits.
        let oracle = try makeContext()
        try SeedData.seedIfNeeded(context: oracle)
        let seedAccounts = try oracle.fetchCount(FetchDescriptor<Account>())
        let seedCategories = try oracle.fetchCount(
            FetchDescriptor<LedgerCategory>())
        let seedBusinesses = try oracle.fetchCount(
            FetchDescriptor<Business>())
        #expect(try context.fetchCount(FetchDescriptor<Account>())
            == seedAccounts)
        #expect(try context.fetchCount(FetchDescriptor<LedgerCategory>())
            == seedCategories)
        #expect(try context.fetchCount(FetchDescriptor<Business>())
            == seedBusinesses)
        #expect(try context.fetchCount(FetchDescriptor<LedgerTransaction>())
            == 0)
        #expect(try context.fetchCount(FetchDescriptor<LoanRateChange>())
            == 0)
        #expect(try context.fetchCount(FetchDescriptor<Budget>()) == 0)
        #expect(try context.fetchCount(FetchDescriptor<RecurringRule>())
            == 0)
        #expect(try context.fetchCount(FetchDescriptor<RentalUnit>()) == 0)
        #expect(try context.fetchCount(FetchDescriptor<RentalLease>()) == 0)
        #expect(try fetchAll(Account.self, in: context)
            .map(\.name) == ["Tiền mặt"])

        // The reported summary counts the rows as they were before.
        #expect(summary.count(of: "Account") == 3)
        #expect(summary.count(of: "LedgerCategory") == 22)
        #expect(summary.count(of: "Business") == 4)
        #expect(summary.count(of: "LedgerTransaction") == 1)
        #expect(summary.count(of: "LoanRateChange") == 1)
        #expect(summary.count(of: "Budget") == 1)
        #expect(summary.count(of: "RecurringRule") == 1)
        #expect(summary.count(of: "RentalUnit") == 1)
        #expect(summary.count(of: "RentalLease") == 1)

        // Wallet sync state: links, cursors and tombstones all gone.
        #expect(states.lastSyncAt == nil)
        #expect(states.state(for: "sess-1") == WalletSyncAccountState())
        #expect(states.tombstonedIDs(
            source: WalletSyncEngine.externalSource).isEmpty)
        // Auto-categorization rules, CSV mappings and batches gone.
        #expect(rules.loadRules().isEmpty)
        #expect(mappings.mapping(for: bank.id) == nil)
        #expect(batches.batch(for: bank.id) == nil)
        // The saved Agent conversations are wiped too.
        #expect(conversations.list().isEmpty)
        // Per-loan interest basis, last-used account, last-backup stamp.
        #expect(defaults.object(
            forKey: "loanInterestBasis.\(loan.id.uuidString)") == nil)
        #expect(basisStore.basis(for: loan.id) == .actual365)
        #expect(defaults.object(
            forKey: DataResetService.lastUsedAccountDefaultsKey) == nil)
        #expect(defaults.object(
            forKey: DataResetService.lastBackupDefaultsKey) == nil)
        // Budget warning log + pending reminders removed.
        #expect(reminderSettings.loadBudgetWarningLog()
            == .empty)
        #expect(center.pending == ["some.other.notification"])
        #expect(Set(center.removed) == Set([
            "\(ReminderPlanner.identifierPrefix)debt.a.0",
            "\(ReminderPlanner.identifierPrefix)recurring.b.0",
        ]))

        // Kept on purpose: sign-in config, reminder + app-lock settings.
        #expect(configStore.load().clientID == "cli_test")
        #expect(reminderSettings.load().isEnabled)
        #expect(reminderSettings.load().notificationHour == 7)
        let lock = lockStore.load()
        #expect(lock.isEnabled)
        #expect(lock.delay == .fiveMinutes)
        #expect(lock.hideInAppSwitcher == false)
    }

    // MARK: - Planned counts

    @Test func plannedSummaryMatchesDeletion() async throws {
        let context = try makeContext()
        try SeedData.seedIfNeeded(context: context)
        let service = makeService(defaults: makeDefaults())

        let cash = try #require(
            try fetchAll(Account.self, in: context).first)
        for _ in 0..<3 {
            context.insert(LedgerTransaction(
                kind: .expense, amount: 1_000, account: cash))
        }
        try context.save()

        let plannedA = try service.plannedSummary(
            for: .transactions, in: context)
        let plannedB = try service.plannedSummary(
            for: .everything, in: context)
        #expect(plannedA.transactions == 3)
        #expect(plannedB.total == 1 + 21 + 3 + 3)

        let doneB = try await service.resetEverything(in: context)
        // Counts shown before the reset equal what was deleted.
        #expect(doneB == plannedB)
    }

    // MARK: - Failure keeps everything

    @Test func failedLevelASaveDeletesNothing() async throws {
        let context = try makeContext()
        try SeedData.seedIfNeeded(context: context)
        let states = WalletSyncInMemoryStateStore()
        var service = makeService(
            defaults: makeDefaults(), stateStore: states)

        let cash = try #require(
            try fetchAll(Account.self, in: context).first)
        context.insert(LedgerTransaction(
            kind: .expense, amount: 5_000, account: cash))
        try context.save()
        states.recordTombstones(
            ["t1"], source: WalletSyncEngine.externalSource)

        service.importReplace = { _ in throw DataResetTestError.commitFailed }
        await #expect(throws: DataResetError.self) {
            try await service.resetTransactions(in: context)
        }
        #expect(
            try context.fetchCount(FetchDescriptor<LedgerTransaction>())
                == 1)
        // Import memory untouched too — cleanup only runs after the
        // commit succeeds.
        #expect(states.tombstonedIDs(
            source: WalletSyncEngine.externalSource) == ["t1"])
    }

    @Test func failedLevelBCommitDeletesNothing() async throws {
        let context = try makeContext()
        try SeedData.seedIfNeeded(context: context)
        let defaults = makeDefaults()
        let states = WalletSyncInMemoryStateStore()
        var service = makeService(
            defaults: defaults, stateStore: states)
        states.recordTombstones(
            ["t1"], source: WalletSyncEngine.externalSource)
        let before = try service.plannedSummary(
            for: .everything, in: context)

        service.importReplace = { _ in throw DataResetTestError.commitFailed }
        await #expect(throws: DataResetError.self) {
            _ = try await service.resetEverything(in: context)
        }

        // The rollback restored every model; the store state is intact.
        let after = try service.plannedSummary(
            for: .everything, in: context)
        #expect(after == before)
        #expect(states.tombstonedIDs(
            source: WalletSyncEngine.externalSource) == ["t1"])
    }

    // MARK: - Schema coverage

    /// Fails when `AppSchema` gains a model the reset does not delete —
    /// the spec list and the schema must stay in step (the deletion
    /// itself lives in `BackupRestorer.deleteAllRows`).
    @Test func schemaCoversEveryResetModel() {
        let reset = Set(DataResetService.resetModelSpecs.map(\.modelName))
        let schema = Set(AppSchema.allModels.map { String(describing: $0) })
        #expect(reset == schema)
    }

    // MARK: - Confirmation rule

    @Test func confirmationAcceptsXoaCaseInsensitively() {
        // Anything folding to "xoa" matches — including "XOÁ" and stray
        // accents ("XÓA"), which the normalizer strips.
        for ok in ["XOA", "xoa", "XoA", "XOÁ", "xoá", " Xoa ", "XÓA"] {
            #expect(DataResetConfirmation.matches(ok), "\(ok) should match")
        }
        for bad in ["", "XO", "XOAA", "XOB"] {
            #expect(!DataResetConfirmation.matches(bad),
                    "\(bad) should not match")
        }
    }

    // MARK: - Document building

    /// Level A is the current ledger with transactions removed. Accounts,
    /// categories and the other models stay; import memory is not part
    /// of the document (it is device-local).
    @Test func levelADocumentDropsTransactionsOnly() throws {
        let context = try makeContext()
        try SeedData.seedIfNeeded(context: context)
        let service = makeService(defaults: makeDefaults())
        let cash = try #require(try fetchAll(Account.self, in: context).first)
        context.insert(LedgerTransaction(
            kind: .expense, amount: 12_000, account: cash))
        context.insert(Budget(monthlyLimit: 50_000, category: try #require(
            try fetchAll(LedgerCategory.self, in: context).first)))
        try context.save()

        let full = try BackupCodec.document(context: context)
        let document = try service.resultingDocument(
            for: .transactions, in: context)
        #expect(full.transactions.count == 1)
        #expect(document.transactions.isEmpty)
        #expect(document.accounts.map(\.id) == full.accounts.map(\.id))
        #expect(document.categories.map(\.id) == full.categories.map(\.id))
        #expect(document.businesses.map(\.id) == full.businesses.map(\.id))
        #expect(document.budgets.map(\.id) == full.budgets.map(\.id))
        #expect(document.loanRateChanges.isEmpty)
        #expect(document.recurringRules.isEmpty)
    }

    /// Level B is exactly a fresh seed: default categories, businesses
    /// and "Tiền mặt", and none of the user's extra rows.
    @Test func levelBDocumentIsSeedDefaultsOnly() throws {
        let context = try makeContext()
        try SeedData.seedIfNeeded(context: context)
        let service = makeService(defaults: makeDefaults())
        context.insert(Account(name: "Thêm", kind: .bank))
        context.insert(LedgerCategory(
            name: "Cafe", kind: .expense, sortOrder: 99))
        let cash = try #require(try fetchAll(Account.self, in: context)
            .first { $0.name == "Tiền mặt" })
        context.insert(LedgerTransaction(
            kind: .expense, amount: 1, account: cash))
        try context.save()

        let oracle = try makeContext()
        try SeedData.seedIfNeeded(context: oracle)
        let expected = try BackupCodec.document(context: oracle)
        let document = try service.resultingDocument(
            for: .everything, in: context)

        #expect(document.accounts.map(\.id) == expected.accounts.map(\.id))
        #expect(document.accounts.map(\.name) == ["Tiền mặt"])
        #expect(document.categories.map(\.id) == expected.categories.map(\.id))
        #expect(document.businesses.map(\.id) == expected.businesses.map(\.id))
        #expect(document.transactions.isEmpty)
        #expect(document.budgets.isEmpty)
        #expect(document.loanRateChanges.isEmpty)
        #expect(document.recurringRules.isEmpty)
        #expect(document.rentalUnits.isEmpty)
        #expect(document.rentalLeases.isEmpty)
    }

    /// Level A posts the transaction-free document as a REPLACE import.
    /// The server export that comes back has no transactions; a failed
    /// import would have left the local row in place (covered above).
    @Test func levelAImportReplacesServerTransactions() async throws {
        let context = try makeContext()
        try SeedData.seedIfNeeded(context: context)
        let cash = try #require(try fetchAll(Account.self, in: context).first)
        context.insert(LedgerTransaction(
            kind: .expense, amount: 9_000, account: cash))
        try context.save()

        let server = FakeSyncServer()
        let api = syncTestClient(for: server)
        var service = makeService(defaults: makeDefaults())
        service.importReplace = { body in
            _ = try await api.importBackup(body)
        }
        service.reload = { _ in
            let snapshot = try await api.exportSnapshot()
            #expect(snapshot.document.transactions.isEmpty)
            #expect(snapshot.document.accounts.map(\.name).contains("Tiền mặt"))
        }
        _ = try await service.resetTransactions(in: context)
        let snapshot = try await api.exportSnapshot()
        #expect(snapshot.document.transactions.isEmpty)
        #expect(!snapshot.document.accounts.isEmpty)
    }

    /// Level B's import is the seed document only — the extra local
    /// account never reaches the server.
    @Test func levelBImportReplacesServerWithSeed() async throws {
        let context = try makeContext()
        try SeedData.seedIfNeeded(context: context)
        context.insert(Account(name: "Không được lên server", kind: .bank))
        try context.save()

        let server = FakeSyncServer()
        let api = syncTestClient(for: server)
        var service = makeService(defaults: makeDefaults())
        service.importReplace = { body in
            _ = try await api.importBackup(body)
        }
        _ = try await service.resetEverything(in: context)
        let snapshot = try await api.exportSnapshot()
        #expect(snapshot.document.accounts.map(\.name) == ["Tiền mặt"])
        #expect(snapshot.document.transactions.isEmpty)
        #expect(snapshot.document.categories.count == 21)
        let oracle = try makeContext()
        try SeedData.seedIfNeeded(context: oracle)
        let expected = try BackupCodec.document(context: oracle)
        #expect(snapshot.document.businesses.map(\.id)
            == expected.businesses.map(\.id))
    }

}
