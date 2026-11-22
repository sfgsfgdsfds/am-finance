import Testing
import Foundation
import SwiftData
import FinanceCore
@testable import AMFinance

/// Tests for the wallet sync feature: page-by-page import, idempotent
/// cursor handling, import-from filtering, auto rules (diacritics,
/// direction, dead targets, transfer conversion), unlink semantics and the
/// coordinator's concurrency guards. Everything runs on an in-memory
/// store with a fake API — no network, no real UserDefaults.
@Suite(.serialized)
@MainActor
struct WalletSyncTests {

    // MARK: - Test scaffolding

    /// Canned wallet API: `items[sessionID]` is the server's table,
    /// ascending by id string. Entries in `failOnAfterIDs` throw once — the
    /// call that carries that `after_id` — then recover, mimicking a flaky
    /// page.
    private final class WalletSyncFakeAPI: WalletSyncAPI, @unchecked Sendable {
        struct Call: Equatable {
            var sessionID: String
            var afterID: String
        }

        var accountsResult: [WalletAPIBankAccount] = []
        var items: [String: [WalletAPIBankTransaction]] = [:]
        var failOnAfterIDs: Set<String> = []
        var error: WalletAPIError = .network("fake")
        private(set) var calls: [Call] = []

        func accounts() async throws -> [WalletAPIBankAccount] {
            accountsResult
        }

        func transactions(
            sessionID: String, afterID: String, limit: Int
        ) async throws -> WalletAPITransactionPage {
            calls.append(Call(sessionID: sessionID, afterID: afterID))
            if failOnAfterIDs.contains(afterID) {
                failOnAfterIDs.remove(afterID)
                throw error
            }
            let all = (items[sessionID] ?? [])
                .filter { $0.id > afterID }
                .sorted { $0.id < $1.id }
            let slice = Array(all.prefix(limit))
            return WalletAPITransactionPage(
                items: slice,
                meta: WalletAPIPageMeta(
                    nextAfterId: slice.last?.id ?? afterID,
                    hasMore: all.count > slice.count,
                    serverTime: nil
                )
            )
        }
    }

    /// Mutable counter for closures — avoids `var` capture complaints.
    private final class WalletSyncCounter {
        var value = 0
    }

    /// The session UUID fixtures use — matches the doc's example.
    private static let sessionA = "11111111-1111-4111-8111-111111111111"

    /// A sortable UUID-shaped transaction id — `txID(1) < txID(2) < …`
    /// under plain string order, like the server's id ordering.
    private static func txID(_ n: Int) -> String {
        String(format: "00000000-0000-4000-8000-%012d", n)
    }

    private func makeContext() throws -> ModelContext {
        ModelContext(try AppModelContainer.make(inMemory: true))
    }

    private let baseDate = Date(timeIntervalSince1970: 1_763_900_000)

    private func bankTransaction(
        _ n: Int,
        sessionID: String = sessionA,
        amount: Int64,
        dayOffset: Int = 0,
        note: String? = nil
    ) -> WalletAPIBankTransaction {
        WalletAPIBankTransaction(
            id: Self.txID(n),
            sessionId: sessionID,
            bankTransactionId: String(format: "%032d", n),
            amount: amount,
            currency: "VND",
            transactionDate: baseDate.addingTimeInterval(
                Double(dayOffset) * 86_400 + Double(n)),
            note: note,
            counterpartyAccountMasked: nil,
            createdAt: nil
        )
    }

    @discardableResult
    private func linkedAccount(
        in context: ModelContext,
        sessionID: String = sessionA,
        openingBalance: Int64 = 0
    ) -> Account {
        let account = Account(
            name: "VPBank *1234", kind: .bank, openingBalance: openingBalance)
        account.externalSource = WalletSyncEngine.externalSource
        account.externalAccountID = sessionID
        context.insert(account)
        return account
    }

    private func makeEngine(
        api: WalletSyncFakeAPI,
        states: WalletSyncInMemoryStateStore,
        rules: WalletSyncInMemoryRuleStore = WalletSyncInMemoryRuleStore(),
        context: ModelContext,
        pageSize: Int = 500
    ) -> WalletSyncEngine {
        var engine = WalletSyncEngine(
            api: api, stateStore: states, ruleStore: rules, context: context)
        engine.pageSize = pageSize
        return engine
    }

    private func allTransactions(
        in context: ModelContext
    ) throws -> [LedgerTransaction] {
        try context.fetch(FetchDescriptor<LedgerTransaction>(
            sortBy: [SortDescriptor(\.date)]))
    }

    // MARK: - Import + mapping

    @Test func firstSyncImportsAndMapsFields() async throws {
        let context = try makeContext()
        let account = linkedAccount(in: context)
        let api = WalletSyncFakeAPI()
        api.items[Self.sessionA] = [
            bankTransaction(1, amount: 500_000, note: "LUONG THANG 11"),
            bankTransaction(2, amount: -150_000, note: nil),
            bankTransaction(3, amount: 100, note: "lãi"),
        ]
        let states = WalletSyncInMemoryStateStore()
        let engine = makeEngine(
            api: api, states: states, context: context)

        let summary = try await engine.syncAll()

        #expect(summary.totalInserted == 3)
        #expect(summary.accounts.count == 1)
        #expect(summary.accounts[0].sessionID == Self.sessionA)

        let rows = try allTransactions(in: context)
        #expect(rows.count == 3)

        let income = rows[0]
        #expect(income.kind == .income)
        #expect(income.amount == 500_000)
        #expect(income.note == "LUONG THANG 11")
        #expect(income.needsReview == true)
        #expect(income.externalSource == "wallet.amx.vn")
        #expect(income.externalID == Self.txID(1))
        #expect(income.account?.id == account.id)
        #expect(income.category == nil)

        let expense = rows[1]
        #expect(expense.kind == .expense)
        #expect(expense.amount == 150_000)   // absolute value
        #expect(expense.note == "")

        // Signed balance: +500k income −150k expense +0.001k.
        #expect(account.balance == 350_100)

        // Cursor persisted to the last row, sync stamped.
        #expect(states.state(for: Self.sessionA).cursor == Self.txID(3))
        #expect(states.state(for: Self.sessionA).lastSyncAt != nil)
        #expect(WalletSyncEngine.importedCount(context: context) == 3)
        #expect(WalletSyncEngine.pendingReviewCount(context: context) == 3)
    }

    @Test func secondSyncIsIdempotent() async throws {
        let context = try makeContext()
        linkedAccount(in: context)
        let api = WalletSyncFakeAPI()
        api.items[Self.sessionA] = [
            bankTransaction(1, amount: 100),
            bankTransaction(2, amount: -200),
        ]
        let states = WalletSyncInMemoryStateStore()
        let engine = makeEngine(api: api, states: states, context: context)

        _ = try await engine.syncAll()
        let again = try await engine.syncAll()

        // The cursor already points past row 2 — nothing new comes back.
        #expect(again.totalInserted == 0)
        #expect(again.totalSkipped == 0)
        #expect(try allTransactions(in: context).count == 2)
        #expect(api.calls.map(\.afterID) == ["0", Self.txID(2)])
    }

    @Test func cursorResetSkipsAlreadyImportedRows() async throws {
        // Relink/simulate a lost cursor: every fetched row is deduped by
        // externalID instead of re-inserted.
        let context = try makeContext()
        linkedAccount(in: context)
        let api = WalletSyncFakeAPI()
        api.items[Self.sessionA] = [
            bankTransaction(1, amount: 100),
            bankTransaction(2, amount: -200),
            bankTransaction(3, amount: 300),
        ]
        let states = WalletSyncInMemoryStateStore()
        let engine = makeEngine(api: api, states: states, context: context)
        _ = try await engine.syncAll()

        states.removeState(for: Self.sessionA)
        api.items[Self.sessionA]!.append(bankTransaction(4, amount: 400))
        let summary = try await engine.syncAll()

        #expect(summary.totalInserted == 1)
        #expect(summary.accounts[0].skippedExisting == 3)
        #expect(try allTransactions(in: context).count == 4)
        #expect(Set(try allTransactions(in: context).map(\.externalID)).count == 4)
    }

    @Test func failingPageKeepsCursorThenRecoversWithoutGaps() async throws {
        let context = try makeContext()
        linkedAccount(in: context)
        let api = WalletSyncFakeAPI()
        api.items[Self.sessionA] = [
            bankTransaction(1, amount: 10),
            bankTransaction(2, amount: 20),
            bankTransaction(3, amount: 30),
        ]
        // The page-2 request fails once.
        api.failOnAfterIDs = [Self.txID(2)]
        let states = WalletSyncInMemoryStateStore()
        let engine = makeEngine(
            api: api, states: states, context: context, pageSize: 2)

        do {
            _ = try await engine.syncAll()
            Issue.record("expected the second page to fail")
        } catch let error as WalletAPIError {
            #expect(error == .network("fake"))
        }

        // Page 1 is committed and the cursor stopped at its end — page 2's
        // data is neither skipped nor duplicated.
        #expect(states.state(for: Self.sessionA).cursor == Self.txID(2))
        #expect(try allTransactions(in: context).compactMap(\.externalID) == [Self.txID(1), Self.txID(2)])

        // The failed rescan never stamped lastFullRescanAt, so recovery
        // re-reads from the start — dedupe absorbs the repeated page.
        let recovered = try await engine.syncAll()
        #expect(recovered.totalInserted == 1)
        #expect(recovered.accounts[0].skippedExisting == 2)
        let rows = try allTransactions(in: context)
        #expect(rows.compactMap(\.externalID) == [Self.txID(1), Self.txID(2), Self.txID(3)])
        #expect(states.state(for: Self.sessionA).cursor == Self.txID(3))
        #expect(
            api.calls.map(\.afterID)
                == ["0", Self.txID(2), "0", Self.txID(2)])
    }

    @Test func importFromDateFiltersOldRows() async throws {
        let context = try makeContext()
        linkedAccount(in: context)
        let api = WalletSyncFakeAPI()
        api.items[Self.sessionA] = [
            bankTransaction(1, amount: 10, dayOffset: -40),
            bankTransaction(2, amount: 20, dayOffset: -5),
            bankTransaction(3, amount: 30, dayOffset: 0),
        ]
        let states = WalletSyncInMemoryStateStore()
        // Import only rows on/after 10 days ago.
        let cutoff = AppCalendar.vietnam.startOfDay(
            for: baseDate.addingTimeInterval(-10 * 86_400))
        states.setState(
            WalletSyncAccountState(importFrom: cutoff),
            for: Self.sessionA)
        let engine = makeEngine(api: api, states: states, context: context)

        let summary = try await engine.syncAll()

        #expect(summary.totalInserted == 2)
        #expect(summary.accounts[0].skippedTooOld == 1)
        #expect(try allTransactions(in: context).compactMap(\.externalID) == [Self.txID(2), Self.txID(3)])
        // …but the cursor still advanced past everything it saw.
        #expect(states.state(for: Self.sessionA).cursor == Self.txID(3))
    }

    @Test func syncWithoutLinkedAccountThrows() async throws {
        let context = try makeContext()
        let api = WalletSyncFakeAPI()
        let engine = makeEngine(
            api: api, states: WalletSyncInMemoryStateStore(), context: context)
        do {
            _ = try await engine.syncAll()
            Issue.record("expected noLinkedAccounts")
        } catch let error as WalletSyncError {
            #expect(error == .noLinkedAccounts)
        }
        #expect(api.calls.isEmpty)
    }

    // MARK: - Self-healing rescan

    /// The self-healing case: a row that becomes visible on the server
    /// with an id *behind* the stored cursor (two writers, same
    /// millisecond) can only be picked up by a rescan from "0" — and the
    /// rescan must not duplicate the rows already imported.
    @Test func rescanPicksUpLateOutOfOrderRowWithoutDuplicates() async throws {
        let context = try makeContext()
        linkedAccount(in: context)
        let api = WalletSyncFakeAPI()
        api.items[Self.sessionA] = [
            bankTransaction(1, amount: 100),
            bankTransaction(3, amount: 300),
        ]
        let states = WalletSyncInMemoryStateStore()
        let engine = makeEngine(api: api, states: states, context: context)
        let t0 = baseDate
        _ = try await engine.syncAll(now: t0)

        // A new server row appears with an id before the stored cursor.
        api.items[Self.sessionA]!.append(bankTransaction(2, amount: 200))

        // An ordinary sync inside the 24h window stays incremental and
        // cannot see it.
        let incremental = try await engine.syncAll(now: t0.addingTimeInterval(3600))
        #expect(incremental.totalInserted == 0)
        #expect(api.calls.map(\.afterID) == ["0", Self.txID(3)])

        // The forced rescan re-reads from "0" and picks it up.
        let rescan = try await engine.syncAll(
            now: t0.addingTimeInterval(3600), fullRescan: true)
        #expect(rescan.totalInserted == 1)
        #expect(rescan.accounts[0].skippedExisting == 2)

        let rows = try allTransactions(in: context)
        #expect(rows.compactMap(\.externalID) == [Self.txID(1), Self.txID(2), Self.txID(3)])
        #expect(Set(rows.compactMap(\.externalID)).count == 3)
        #expect(api.calls.map(\.afterID) == ["0", Self.txID(3), "0"])
    }

    /// The automatic rescan runs at most once every 24h per linked
    /// account: the second sync in the window is incremental, a sync past
    /// the window rescans, and the one after that is incremental again.
    @Test func autoRescanRunsAtMostOncePerDay() async throws {
        let context = try makeContext()
        linkedAccount(in: context)
        let api = WalletSyncFakeAPI()
        api.items[Self.sessionA] = [
            bankTransaction(1, amount: 100),
            bankTransaction(3, amount: 300),
        ]
        let states = WalletSyncInMemoryStateStore()
        let engine = makeEngine(api: api, states: states, context: context)
        let t0 = baseDate
        _ = try await engine.syncAll(now: t0)
        api.items[Self.sessionA]!.append(bankTransaction(2, amount: 200))

        // 1h later: inside the window — incremental only.
        _ = try await engine.syncAll(now: t0.addingTimeInterval(3_600))
        #expect(api.calls.map(\.afterID) == ["0", Self.txID(3)])
        #expect(try allTransactions(in: context).count == 2)

        // 25h after the first rescan: the rescan fires and finds the
        // late row.
        let t1 = t0.addingTimeInterval(25 * 3_600)
        let rescan = try await engine.syncAll(now: t1)
        #expect(rescan.totalInserted == 1)
        #expect(api.calls.map(\.afterID) == ["0", Self.txID(3), "0"])

        // Right after it: back to incremental — no second "0" call.
        _ = try await engine.syncAll(now: t1.addingTimeInterval(60))
        #expect(api.calls.map(\.afterID) == ["0", Self.txID(3), "0", Self.txID(3)])
        #expect(states.state(for: Self.sessionA).lastFullRescanAt == t1)
    }

    /// The import-from cutoff still applies during a rescan: a late row
    /// older than the link's start date is skipped, not imported.
    @Test func rescanStillRespectsImportFrom() async throws {
        let context = try makeContext()
        linkedAccount(in: context)
        let api = WalletSyncFakeAPI()
        api.items[Self.sessionA] = [
            bankTransaction(1, amount: 10, dayOffset: -40),
            bankTransaction(3, amount: 30, dayOffset: 0),
        ]
        let states = WalletSyncInMemoryStateStore()
        let cutoff = AppCalendar.vietnam.startOfDay(
            for: baseDate.addingTimeInterval(-10 * 86_400))
        states.setState(
            WalletSyncAccountState(importFrom: cutoff),
            for: Self.sessionA)
        let engine = makeEngine(api: api, states: states, context: context)
        _ = try await engine.syncAll(now: baseDate)
        #expect(try allTransactions(in: context).count == 1)

        // A late row appears behind the cursor — but it is also too old.
        api.items[Self.sessionA]!.append(
            bankTransaction(2, amount: 20, dayOffset: -40))
        let rescan = try await engine.syncAll(
            now: baseDate, fullRescan: true)

        #expect(rescan.totalInserted == 0)
        #expect(rescan.accounts[0].skippedTooOld == 2)
        #expect(rescan.accounts[0].skippedExisting == 1)
        #expect(
            try allTransactions(in: context).compactMap(\.externalID)
                == [Self.txID(3)])
    }

    // MARK: - Rules

    @Test func ruleMatchesCaseDiacriticAndDirection() {
        let anyID = UUID()
        let rule = WalletSyncRule(
            keyword: "an uong", direction: .moneyOut, action: .category(anyID))
        #expect(rule.matches(note: "AN UONG TRUA", moneyIn: false))
        #expect(rule.matches(note: "An Uống tối", moneyIn: false))
        #expect(rule.matches(note: "an uong", moneyIn: true) == false)
        #expect(rule.matches(note: "khac", moneyIn: false) == false)

        // Vietnamese "đ" folds to "d".
        let dien = WalletSyncRule(
            keyword: "dien", direction: .any, action: .category(anyID))
        #expect(dien.matches(note: "ĐIỆN lực tháng 11", moneyIn: false))
        #expect(dien.matches(note: "điện", moneyIn: true))

        // Direction "Tiền vào" only matches income.
        let inn = WalletSyncRule(
            keyword: "luong", direction: .moneyIn, action: .category(anyID))
        #expect(inn.matches(note: "LUONG T11", moneyIn: true))
        #expect(!inn.matches(note: "LUONG T11", moneyIn: false))
    }

    @Test func engineAppliesMatchingCategoryRule() async throws {
        let context = try makeContext()
        try SeedData.seedIfNeeded(context: context)
        linkedAccount(in: context)
        let food = try context.fetch(FetchDescriptor<LedgerCategory>())
            .first { $0.name == "Ăn uống" }!
        let api = WalletSyncFakeAPI()
        api.items[Self.sessionA] = [
            bankTransaction(1, amount: -155_000, note: "an uong trua"),
            bankTransaction(2, amount: -50_000, note: "ca phe"),
        ]
        let rules = WalletSyncInMemoryRuleStore(rules: [
            WalletSyncRule(
                keyword: "an uong", direction: .moneyOut,
                action: .category(food.id)),
        ])
        let engine = makeEngine(
            api: api, states: WalletSyncInMemoryStateStore(),
            rules: rules, context: context)

        _ = try await engine.syncAll()

        let rows = try allTransactions(in: context)
        #expect(rows[0].category?.id == food.id)
        #expect(rows[0].needsReview == false)
        #expect(rows[1].category == nil)
        #expect(rows[1].needsReview == true)
    }

    @Test func firstMatchingLiveRuleWinsAndDeadRulesAreSkipped() async throws {
        let context = try makeContext()
        try SeedData.seedIfNeeded(context: context)
        linkedAccount(in: context)
        let categories = try context.fetch(FetchDescriptor<LedgerCategory>())
        let food = categories.first { $0.name == "Ăn uống" }!
        let travel = categories.first { $0.name == "Di chuyển" }!
        let api = WalletSyncFakeAPI()
        api.items[Self.sessionA] = [bankTransaction(1, amount: -100, note: "an uong")]
        let rules = WalletSyncInMemoryRuleStore(rules: [
            // Dead target — the category id no longer exists.
            WalletSyncRule(
                keyword: "an uong", direction: .any,
                action: .category(UUID())),
            WalletSyncRule(
                keyword: "an uong", direction: .any, action: .category(food.id)),
            // Would also match but loses to the rule above.
            WalletSyncRule(
                keyword: "an", direction: .any, action: .category(travel.id)),
        ])
        let engine = makeEngine(
            api: api, states: WalletSyncInMemoryStateStore(),
            rules: rules, context: context)

        _ = try await engine.syncAll()
        let row = try #require(try allTransactions(in: context).first)
        #expect(row.category?.id == food.id)
        #expect(row.needsReview == false)
    }

    @Test func transferRuleConvertsAndMovesBothBalances() async throws {
        let context = try makeContext()
        let bank = linkedAccount(in: context, openingBalance: 1_000_000)
        let cash = Account(
            name: "Tiền mặt", kind: .cash, openingBalance: 0)
        context.insert(cash)
        let api = WalletSyncFakeAPI()
        api.items[Self.sessionA] = [
            bankTransaction(1, amount: -500_000, note: "RUT TIEN MAT"),
            bankTransaction(2, amount: 5_000_000, note: "CK NOI BO"),
        ]
        let rules = WalletSyncInMemoryRuleStore(rules: [
            WalletSyncRule(
                keyword: "rut tien", direction: .moneyOut,
                action: .transfer(cash.id)),
            WalletSyncRule(
                keyword: "ck noi bo", direction: .moneyIn,
                action: .transfer(cash.id)),
        ])
        let engine = makeEngine(
            api: api, states: WalletSyncInMemoryStateStore(),
            rules: rules, context: context)

        _ = try await engine.syncAll()
        let rows = try allTransactions(in: context)

        let out = rows[0]
        #expect(out.kind == .transfer)
        #expect(out.account?.id == bank.id)      // money left the bank
        #expect(out.toAccount?.id == cash.id)
        #expect(out.needsReview == false)
        #expect(out.category == nil)

        let inn = rows[1]
        #expect(inn.kind == .transfer)
        #expect(inn.account?.id == cash.id)      // money came from cash
        #expect(inn.toAccount?.id == bank.id)

        // Bank: 1M − 500k + 5M; cash: 0 + 500k − 5M.
        #expect(bank.balance == 5_500_000)
        #expect(cash.balance == -4_500_000)
    }

    @Test func businessRuleAssignsBusiness() async throws {
        let context = try makeContext()
        try SeedData.seedIfNeeded(context: context)
        linkedAccount(in: context)
        let business = try context.fetch(FetchDescriptor<Business>())
            .first { $0.name == "Căn hộ dịch vụ" }!
        let api = WalletSyncFakeAPI()
        api.items[Self.sessionA] = [
            bankTransaction(1, amount: 6_000_000, note: "TIEN PHONG T11"),
        ]
        let rules = WalletSyncInMemoryRuleStore(rules: [
            WalletSyncRule(
                keyword: "tien phong", direction: .moneyIn,
                action: .business(business.id)),
        ])
        let engine = makeEngine(
            api: api, states: WalletSyncInMemoryStateStore(),
            rules: rules, context: context)

        _ = try await engine.syncAll()
        let row = try #require(try allTransactions(in: context).first)
        #expect(row.business?.id == business.id)
        #expect(row.needsReview == false)
    }

    @Test func ruleWithDeletedCategoryIsIgnored() async throws {
        let context = try makeContext()
        linkedAccount(in: context)
        let api = WalletSyncFakeAPI()
        api.items[Self.sessionA] = [bankTransaction(1, amount: -100, note: "an uong")]
        let rules = WalletSyncInMemoryRuleStore(rules: [
            WalletSyncRule(
                keyword: "an uong", direction: .any,
                action: .category(UUID())),
        ])
        let engine = makeEngine(
            api: api, states: WalletSyncInMemoryStateStore(),
            rules: rules, context: context)

        _ = try await engine.syncAll()
        let row = try #require(try allTransactions(in: context).first)
        #expect(row.category == nil)
        #expect(row.needsReview == true)
    }

    // MARK: - Unlink

    @Test func unlinkKeepsImportedTransactions() async throws {
        let context = try makeContext()
        let account = linkedAccount(in: context)
        let api = WalletSyncFakeAPI()
        api.items[Self.sessionA] = [
            bankTransaction(1, amount: -100),
            bankTransaction(2, amount: 200),
        ]
        let states = WalletSyncInMemoryStateStore()
        let engine = makeEngine(api: api, states: states, context: context)
        _ = try await engine.syncAll()

        // Unlink exactly like the accounts screen does.
        account.externalSource = nil
        account.externalAccountID = nil
        try context.save()
        states.removeState(for: Self.sessionA)

        let rows = try allTransactions(in: context)
        #expect(rows.count == 2)
        #expect(rows.allSatisfy { $0.externalSource == "wallet.amx.vn" })
        #expect(WalletSyncEngine.linkedAccounts(context: context).isEmpty)

        // And a fresh sync now reports "nothing linked".
        do {
            _ = try await engine.syncAll()
            Issue.record("expected noLinkedAccounts after unlink")
        } catch let error as WalletSyncError {
            #expect(error == .noLinkedAccounts)
        }
    }

    // MARK: - Stores

    @Test func stateStoreRoundTripsThroughUserDefaults() throws {
        let suiteName = "WalletSyncTests.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let store = WalletSyncStateStore(defaults: defaults)
        #expect(store.state(for: Self.sessionA) == WalletSyncAccountState())

        let when = Date(timeIntervalSince1970: 1_700_000_000)
        store.setState(
            WalletSyncAccountState(cursor: Self.txID(42), importFrom: when, lastSyncAt: when, lastFullRescanAt: when),
            for: Self.sessionA)
        let reloaded = WalletSyncStateStore(defaults: defaults).state(for: Self.sessionA)
        #expect(reloaded.cursor == Self.txID(42))
        #expect(reloaded.lastFullRescanAt == when)
        #expect(reloaded.importFrom == when)
        #expect(store.lastSyncAt == when)

        store.removeState(for: Self.sessionA)
        #expect(store.state(for: Self.sessionA) == WalletSyncAccountState())
    }

    @Test func ruleStoreRoundTripsThroughUserDefaults() throws {
        let suiteName = "WalletSyncTests.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let store = WalletSyncRuleStore(defaults: defaults)
        #expect(store.loadRules().isEmpty)

        let rule = WalletSyncRule(
            keyword: "grab", direction: .moneyOut, action: .transfer(UUID()))
        store.saveRules([rule])
        #expect(WalletSyncRuleStore(defaults: defaults).loadRules() == [rule])
    }

    @Test func importFromDatesResolveOnce() {
        let now = Date(timeIntervalSince1970: 1_763_900_000)
        let calendar = AppCalendar.vietnam
        #expect(
            WalletSyncImportFrom.today.startDate(now: now, calendar: calendar)
            == calendar.startOfDay(for: now))
        #expect(
            WalletSyncImportFrom.allHistory.startDate(now: now, calendar: calendar)
            == nil)
        let thirty = WalletSyncImportFrom.last30Days
            .startDate(now: now, calendar: calendar)
        let expected = calendar.startOfDay(
            for: calendar.date(byAdding: .day, value: -30, to: now)!)
        #expect(thirty == expected)
    }

    // MARK: - Coordinator

    private func makeCoordinator(
        signedIn: Bool = true,
        linked: Bool = true,
        counter: WalletSyncCounter,
        runSync: (@MainActor (Bool) async throws -> WalletSyncSummary)? = nil,
        lastSyncAt: Date? = nil
    ) -> WalletSyncCoordinator {
        WalletSyncCoordinator(
            isSignedIn: { signedIn },
            hasLinkedAccounts: { linked },
            runSync: runSync ?? { _ in
                counter.value += 1
                return WalletSyncSummary()
            },
            countPendingReview: { 0 },
            lastSyncAt: lastSyncAt
        )
    }

    @Test func coordinatorNeverRunsTwoSyncsAtOnce() async {
        let counter = WalletSyncCounter()
        let coordinator = makeCoordinator(
            counter: counter,
            runSync: { _ in
                counter.value += 1
                try? await Task.sleep(nanoseconds: 300_000_000)
                return WalletSyncSummary()
            })

        async let first = coordinator.syncNow()
        async let second = coordinator.syncNow()
        let results = await (first, second)

        #expect(counter.value == 1)
        #expect(results.0 == true && results.1 == true)
        #expect(coordinator.syncState == .idle)
        #expect(coordinator.lastSyncAt != nil)
    }

    @Test func coordinatorIsNoOpWhenSignedOut() async {
        let counter = WalletSyncCounter()
        let coordinator = makeCoordinator(
            signedIn: false,
            linked: false, // should not even be consulted
            counter: counter
        )
        let ran = await coordinator.syncNow()
        #expect(ran == false)
        #expect(counter.value == 0)
        #expect(coordinator.syncState == .idle)
        #expect(coordinator.lastSyncAt == nil)
    }

    @Test func coordinatorIsNoOpWhenNothingIsLinked() async {
        let counter = WalletSyncCounter()
        let coordinator = makeCoordinator(linked: false, counter: counter)
        let ran = await coordinator.syncNow()
        #expect(ran == false)
        #expect(counter.value == 0)
        #expect(coordinator.syncState == .idle)
    }

    @Test func coordinatorSyncIfStaleRespectsTheWindow() async {
        let counter = WalletSyncCounter()
        let coordinator = makeCoordinator(counter: counter)

        _ = await coordinator.syncNow()
        #expect(counter.value == 1)

        // Fresh — inside the 60s window.
        _ = await coordinator.syncIfStale(maxAge: 60)
        #expect(counter.value == 1)

        // Seeded with an old timestamp, the same coordinator shape runs.
        let stale = makeCoordinator(
            counter: counter,
            lastSyncAt: .now.addingTimeInterval(-120))
        _ = await stale.syncIfStale(maxAge: 60)
        #expect(counter.value == 2)
    }

    @Test func coordinatorFailureRecordsMessage() async {
        let counter = WalletSyncCounter()
        let coordinator = makeCoordinator(
            counter: counter,
            runSync: { _ in throw WalletAPIError.notSignedIn })
        let ran = await coordinator.syncNow()
        #expect(ran == false)
        if case .failed(let message) = coordinator.syncState {
            #expect(message.contains("đăng nhập"))
        } else {
            Issue.record("expected failed state, got \(coordinator.syncState)")
        }
    }

    // MARK: - Suggestions

    @Test func suggestionsRankMostUsedCategories() throws {
        let context = try makeContext()
        try SeedData.seedIfNeeded(context: context)
        let account = try context.fetch(FetchDescriptor<Account>()).first!
        let categories = try context.fetch(FetchDescriptor<LedgerCategory>())
        let named = { (name: String) in categories.first { $0.name == name }! }
        let food = named("Ăn uống")
        let travel = named("Di chuyển")
        let fun = named("Đi chơi")
        let salary = named("Lương & thù lao")

        func add(_ amount: Int64, _ category: LedgerCategory, daysAgo: Int) {
            context.insert(LedgerTransaction(
                kind: .expense, amount: amount,
                date: .now.addingTimeInterval(Double(-daysAgo) * 86_400),
                account: account, category: category))
        }
        add(1, travel, daysAgo: 1)
        add(1, travel, daysAgo: 2)
        add(1, travel, daysAgo: 3)
        add(1, food, daysAgo: 1)
        add(1, food, daysAgo: 2)
        add(1, fun, daysAgo: 1)
        // A salary income must not leak into expense suggestions.
        context.insert(LedgerTransaction(
            kind: .income, amount: 1, account: account, category: salary))

        let top = WalletSyncSuggestions.top(
            kind: .expense,
            transactions: try allTransactions(in: context),
            categories: categories,
            now: .now)
        #expect(top.map(\.id) == [travel.id, food.id, fun.id])

        // Outside the 90-day window the count drops.
        add(1, fun, daysAgo: 200)
        let topAgain = WalletSyncSuggestions.top(
            kind: .expense,
            transactions: try allTransactions(in: context),
            categories: categories,
            now: .now)
        #expect(topAgain.map(\.id) == [travel.id, food.id, fun.id])

        // Income direction finds salary.
        let incomeTop = WalletSyncSuggestions.top(
            kind: .income,
            transactions: try allTransactions(in: context),
            categories: categories,
            now: .now)
        #expect(incomeTop.map(\.id) == [salary.id])
    }

    @Test func ruleDraftValidatesAndMapsBothWays() {
        var draft = WalletSyncRuleDraft()
        #expect(!draft.isValid)

        draft.keyword = " grab "
        #expect(!draft.isValid)   // still no target
        let id = UUID()
        draft.categoryID = id
        #expect(draft.isValid)

        let rule = draft.makeRule(id: id)!
        #expect(rule.keyword == "grab")
        #expect(rule.action == .category(id))

        let roundTrip = WalletSyncRuleDraft(rule: rule)
        #expect(roundTrip.actionKind == .category)
        #expect(roundTrip.categoryID == id)

        // A transfer draft round-trips too.
        var transferDraft = WalletSyncRuleDraft(
            keyword: "ck", direction: .moneyIn)
        transferDraft.actionKind = .transfer
        transferDraft.accountID = id
        #expect(transferDraft.makeRule()?.action == .transfer(id))
    }
}
