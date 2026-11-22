import Testing
import SwiftData
import FinanceCore
@testable import AMFinance

@MainActor
struct ModelTests {
    private func makeContext() throws -> ModelContext {
        ModelContext(try AppModelContainer.make(inMemory: true))
    }

    private func fetchAll<T: PersistentModel>(_ type: T.Type, in context: ModelContext) throws -> [T] {
        try context.fetch(FetchDescriptor<T>())
    }

    @Test func seedIsIdempotent() throws {
        let context = try makeContext()

        try SeedData.seedIfNeeded(context: context)
        #expect(try fetchAll(Account.self, in: context).count == 1)
        #expect(try fetchAll(Business.self, in: context).count == 3)
        let categories = try fetchAll(LedgerCategory.self, in: context)
        #expect(categories.count == 21)
        #expect(categories.filter { $0.kind == .expense }.count == 15)
        #expect(categories.filter { $0.kind == .income }.count == 6)

        try SeedData.seedIfNeeded(context: context)
        #expect(try fetchAll(Account.self, in: context).count == 1)
        #expect(try fetchAll(Business.self, in: context).count == 3)
        #expect(try fetchAll(LedgerCategory.self, in: context).count == 21)
    }

    @Test func seedCreatesExpectedCashAccount() throws {
        let context = try makeContext()
        try SeedData.seedIfNeeded(context: context)
        let account = try #require(fetchAll(Account.self, in: context).first)
        #expect(account.name == "Tiền mặt")
        #expect(account.kind == .cash)
        #expect(account.balance == 0)
    }

    @Test func balanceAfterExpenseIncomeAndTransfer() throws {
        let context = try makeContext()
        let cash = Account(name: "Tiền mặt", kind: .cash, openingBalance: 1_000_000)
        let bank = Account(name: "Ngân hàng", kind: .bank)
        context.insert(cash)
        context.insert(bank)

        context.insert(LedgerTransaction(kind: .expense, amount: 100_000, account: cash))
        context.insert(LedgerTransaction(kind: .income, amount: 500_000, account: cash))
        context.insert(LedgerTransaction(kind: .transfer, amount: 200_000, account: cash, toAccount: bank))
        try context.save()

        #expect(cash.balance == 1_200_000)
        #expect(bank.balance == 200_000)
    }

    @Test func creditCardPurchaseAndPayoff() throws {
        let context = try makeContext()
        let card = Account(name: "Thẻ tín dụng", kind: .creditCard)
        card.creditLimit = 30_000_000
        let bank = Account(name: "Ngân hàng", kind: .bank, openingBalance: 5_000_000)
        context.insert(card)
        context.insert(bank)

        // A purchase on the card is an expense sourced from the card.
        context.insert(LedgerTransaction(kind: .expense, amount: 1_500_000, account: card))
        try context.save()
        #expect(card.balance == -1_500_000)

        // Paying the card is a transfer bank -> card.
        context.insert(LedgerTransaction(kind: .transfer, amount: 1_500_000, account: bank, toAccount: card))
        try context.save()
        #expect(card.balance == 0)
        #expect(bank.balance == 3_500_000)
    }

    @Test func netWorthSumsAssetsAndLiabilities() throws {
        let context = try makeContext()
        let cash = Account(name: "Tiền mặt", kind: .cash, openingBalance: 2_000_000)
        let card = Account(name: "Thẻ tín dụng", kind: .creditCard)
        let loan = Account(name: "Khoản vay", kind: .loan, openingBalance: -10_000_000)
        let archived = Account(name: "Cũ", kind: .bank, openingBalance: 99_000_000, isArchived: true)
        for account in [cash, card, loan, archived] {
            context.insert(account)
        }
        context.insert(LedgerTransaction(kind: .expense, amount: 500_000, account: card))
        try context.save()

        let accounts = try fetchAll(Account.self, in: context)
        #expect(NetWorth.assets(accounts) == 2_000_000)
        #expect(NetWorth.liabilities(accounts) == -10_500_000)
        #expect(NetWorth.total(accounts) == -8_500_000)
    }

    @Test func deletingCategoryLeavesTransactionUncategorized() throws {
        let context = try makeContext()
        let category = LedgerCategory(name: "Ăn uống", kind: .expense)
        let account = Account(name: "Tiền mặt", kind: .cash)
        context.insert(category)
        context.insert(account)
        let transaction = LedgerTransaction(
            kind: .expense, amount: 50_000, account: account, category: category
        )
        context.insert(transaction)
        try context.save()
        #expect(transaction.category?.id == category.id)

        context.delete(category)
        try context.save()

        #expect(transaction.category == nil)
        let transactions = try fetchAll(LedgerTransaction.self, in: context)
        #expect(transactions.count == 1)
        #expect(account.balance == -50_000)
    }
}
