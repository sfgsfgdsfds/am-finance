import Testing
import SwiftData
import Foundation
import FinanceCore
@testable import AMFinance

/// Correctness gate for the balance cache: every cached value must equal
/// the straightforward relationship walk — on a small hand-made ledger,
/// after every kind of mutation, and across data reset and restore.
/// The timing/equality runs on the benchmark datasets live in
/// `PerformanceTests.swift`.
@Suite(.serialized)
@MainActor
struct LedgerBalanceStoreTests {

    /// A small ledger exercising every role combination: income, expense,
    /// transfers in both directions, a self-transfer, a zero-amount row,
    /// imported rows pending review, a card with cycle config, a loan and
    /// a receivable with a negative opening balance.
    struct Fixture {
        let container: ModelContainer
        let context: ModelContext
        let store: LedgerBalanceStore
        let bank: Account
        let cash: Account
        let card: Account
        let loan: Account
        let receivable: Account
        let idle: Account
        var accounts: [Account] { [bank, cash, card, loan, receivable, idle] }
    }

    private func makeFixture() throws -> Fixture {
        let container = try AppModelContainer.make(inMemory: true)
        let context = ModelContext(container)
        let bank = Account(name: "Bank", kind: .bank,
                           openingBalance: 10_000_000, sortOrder: 0)
        let cash = Account(name: "Tiền mặt", kind: .cash,
                           openingBalance: 1_000_000, sortOrder: 1)
        let card = Account(name: "Thẻ", kind: .creditCard,
                           openingBalance: -2_000_000, sortOrder: 2)
        card.statementDay = 20
        card.graceDays = 15
        let loan = Account(name: "Vay", kind: .loan,
                           openingBalance: -50_000_000, sortOrder: 3)
        let receivable = Account(name: "Khách", kind: .receivable,
                                 openingBalance: -500_000, sortOrder: 4)
        let idle = Account(name: "Ví phụ", kind: .eWallet,
                           openingBalance: 0, sortOrder: 5)
        let category = LedgerCategory(
            name: "Chi", kind: .expense, sortOrder: 0)
        for model in [bank, cash, card, loan, receivable, idle] {
            context.insert(model)
        }
        context.insert(category)

        let day: TimeInterval = 86_400
        let now = Date.now
        let rows: [LedgerTransaction] = [
            LedgerTransaction(kind: .expense, amount: 300_000,
                              date: now.addingTimeInterval(-6 * day),
                              note: "Chi 1", account: bank, category: category),
            LedgerTransaction(kind: .income, amount: 2_000_000,
                              date: now.addingTimeInterval(-5 * day),
                              note: "Thu 1", account: bank, category: category),
            LedgerTransaction(kind: .transfer, amount: 500_000,
                              date: now.addingTimeInterval(-4 * day),
                              note: "Bank → Tiền mặt",
                              account: bank, toAccount: cash),
            LedgerTransaction(kind: .transfer, amount: 700_000,
                              date: now.addingTimeInterval(-3 * day),
                              note: "Tiền mặt → Bank",
                              account: cash, toAccount: bank),
            LedgerTransaction(kind: .expense, amount: 400_000,
                              date: now.addingTimeInterval(-2 * day),
                              note: "Trả thẻ nguồn", account: cash,
                              toAccount: card),
            LedgerTransaction(kind: .transfer, amount: 400_000,
                              date: now.addingTimeInterval(-2 * day),
                              note: "Trả thẻ đích", account: cash,
                              toAccount: card),
            LedgerTransaction(kind: .expense, amount: 250_000,
                              date: now.addingTimeInterval(-day),
                              note: "Chi ngoài lề", account: receivable,
                              category: category),
            LedgerTransaction(kind: .transfer, amount: 800_000,
                              date: now,
                              note: "Ứng khách", account: receivable,
                              toAccount: receivable),
            LedgerTransaction(kind: .income, amount: 0,
                              date: now,
                              note: "Không đồng", account: bank),
        ]
        for row in rows { context.insert(row) }
        let pending = LedgerTransaction(
            kind: .expense, amount: 111_000, date: now,
            note: "Chưa duyệt", account: bank, category: category)
        pending.needsReview = true
        pending.externalSource = WalletSyncEngine.externalSource
        pending.externalID = "fixture-1"
        context.insert(pending)
        try context.save()

        let store = LedgerBalanceStores.shared(for: container)
        try store.refresh(context: context)
        return Fixture(
            container: container, context: context, store: store,
            bank: bank, cash: cash, card: card, loan: loan,
            receivable: receivable, idle: idle)
    }

    /// Every cached answer equals the walk it replaces. Entry lists are
    /// compared order-insensitively: the old relationship order is
    /// unspecified, and every consumer (credit-card cycles, balance
    /// history) reduces over the entries, so only content matters.
    private func expectParity(_ fx: Fixture,
                            _ message: Comment? = nil) {
        for account in fx.accounts {
            #expect(
                fx.store.balance(of: account) == account.balance,
                "\(account.name) balance \(message ?? "")")
            #expect(
                fx.store.creditCardEntries(of: account)
                    .sorted { ($0.date, $0.delta) < ($1.date, $1.delta) }
                    == account.creditCardEntries
                    .sorted { ($0.date, $0.delta) < ($1.date, $1.delta) },
                "\(account.name) card entries \(message ?? "")")
            #expect(
                fx.store.balanceTrendEntries(of: account)
                    .sorted { ($0.date, $0.delta) < ($1.date, $1.delta) }
                    == account.balanceTrendEntries
                    .sorted { ($0.date, $0.delta) < ($1.date, $1.delta) },
                "\(account.name) trend entries \(message ?? "")")
            #expect(
                fx.store.receivableSnapshot(of: account)
                    == ReceivableSnapshot.make(account: account),
                "\(account.name) receivable snapshot \(message ?? "")")
            #expect(
                fx.store.hasActivity(of: account)
                    == !AccountGrouping.canDelete(account),
                "\(account.name) activity \(message ?? "")")
        }
        #expect(
            NetWorth.total(fx.accounts) { fx.store.balance(of: $0) }
                == NetWorth.total(fx.accounts),
            "net worth \(message ?? "")")
    }

    @Test func parityOnSmallLedger() throws {
        try expectParity(makeFixture())
    }

    /// A save bumps the ledger version synchronously — reads between the
    /// save and the off-main re-aggregation must already fall back to the
    /// walk, never serve the stale aggregate.
    @Test func saveInvalidatesSynchronously() throws {
        let fx = try makeFixture()
        let before = fx.store.balance(of: fx.bank)
        fx.context.insert(LedgerTransaction(
            kind: .expense, amount: 999_000, date: .now,
            note: "Mới", account: fx.bank))
        try fx.context.save()
        // No refresh yet — the read must equal the new truth.
        #expect(fx.store.balance(of: fx.bank) == fx.bank.balance)
        #expect(fx.store.balance(of: fx.bank) == before - 999_000)
    }

    @Test func parityAfterInsertEditDeleteTransfer() throws {
        let fx = try makeFixture()

        // Insert.
        let fresh = LedgerTransaction(
            kind: .income, amount: 777_000, date: .now,
            note: "Thêm", account: fx.cash)
        fx.context.insert(fresh)
        try fx.context.save()
        try fx.store.refresh(context: fx.context)
        try expectParity(fx, "sau thêm")

        // Edit — amount and account move together.
        fresh.amount = 555_000
        fresh.account = fx.bank
        try fx.context.save()
        try fx.store.refresh(context: fx.context)
        try expectParity(fx, "sau sửa")

        // Transfer between accounts.
        fx.context.insert(LedgerTransaction(
            kind: .transfer, amount: 333_000, date: .now,
            note: "Chuyển", account: fx.bank, toAccount: fx.loan))
        try fx.context.save()
        try fx.store.refresh(context: fx.context)
        try expectParity(fx, "sau chuyển")

        // Delete — including the self-transfer edge case.
        for row in [fresh] + (fx.bank.transactions ?? [])
            .filter({ $0.toAccount === fx.receivable }) {
            fx.context.delete(row)
        }
        try fx.context.save()
        try fx.store.refresh(context: fx.context)
        try expectParity(fx, "sau xoá")
    }

    /// Restore semantics: encode the fixture, wipe everything, restore —
    /// the cache must land on the same numbers as the walk.
    @Test func parityAcrossResetAndRestore() throws {
        let fx = try makeFixture()
        let expectedBalances = Dictionary(
            uniqueKeysWithValues: fx.accounts.map { ($0.id, $0.balance) })
        let data = try BackupCodec.encode(context: fx.context)

        try BackupRestorer.deleteAllRows(in: fx.context)
        try fx.context.save()
        try fx.store.refresh(context: fx.context)
        // Wiped store: the aggregate holds no accounts and nothing is
        // marked active.
        #expect(try fx.context.fetch(FetchDescriptor<Account>()).isEmpty)
        #expect(fx.store.aggregate?.balances.isEmpty == true)
        #expect(fx.store.aggregate?.activeIDs.isEmpty == true)

        let document = try BackupCodec.decode(data)
        try BackupRestorer.restore(document, mode: .replace, into: fx.context)
        try fx.context.save()
        try fx.store.refresh(context: fx.context)
        let restored = try fx.context.fetch(FetchDescriptor<Account>())
        for account in restored {
            #expect(fx.store.balance(of: account) == account.balance)
            #expect(
                fx.store.balance(of: account) == expectedBalances[account.id],
                "\(account.name) sau restore")
        }
        #expect(
            NetWorth.total(restored) { fx.store.balance(of: $0) }
                == NetWorth.total(restored))
    }

    /// `changeCount` is the observable signal views use to re-pull paged
    /// data — it must move after a save reaches the main actor.
    @Test func changeCountMovesAfterSave() async throws {
        let fx = try makeFixture()
        let count = fx.store.changeCount
        fx.context.insert(LedgerTransaction(
            kind: .expense, amount: 10_000, date: .now,
            note: "X", account: fx.bank))
        try fx.context.save()
        try await Task.sleep(for: .milliseconds(50))
        #expect(fx.store.changeCount > count)
    }

    /// One store per container; `remove` drops it so a reset store does
    /// not keep an observer on a dead container alive.
    @Test func sharedRegistryPerContainer() throws {
        let fx = try makeFixture()
        #expect(
            LedgerBalanceStores.shared(for: fx.container) === fx.store)
        let other = try AppModelContainer.make(inMemory: true)
        #expect(
            LedgerBalanceStores.shared(for: other) !== fx.store)
        LedgerBalanceStores.remove(fx.container)
        #expect(
            LedgerBalanceStores.shared(for: fx.container) !== fx.store)
    }
}
