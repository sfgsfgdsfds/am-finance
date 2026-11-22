import Testing
import SwiftData
import FinanceCore
@testable import AMFinance

@MainActor
struct TransactionEditorTests {
    private func makeContext() throws -> ModelContext {
        ModelContext(try AppModelContainer.make(inMemory: true))
    }

    private func fetchAll<T: PersistentModel>(_ type: T.Type, in context: ModelContext) throws -> [T] {
        try context.fetch(FetchDescriptor<T>())
    }

    // MARK: - Validation

    @Test func emptyDraftFailsAmountAndAccount() {
        let draft = TransactionDraft(kind: .expense)
        #expect(Set(draft.validate()) == [.missingAmount, .missingAccount])
        #expect(!draft.isValid)
    }

    @Test func completeExpenseAndIncomeDraftsAreValid() {
        let cash = Account(name: "Tiền mặt", kind: .cash)

        var expense = TransactionDraft(kind: .expense, account: cash)
        expense.amount = 50_000
        expense.category = LedgerCategory(name: "Ăn uống", kind: .expense)
        #expect(expense.isValid)
        // Category is optional — a draft without one still saves.
        expense.category = nil
        #expect(expense.isValid)

        var income = TransactionDraft(kind: .income, account: cash)
        income.amount = 1_000_000
        income.category = LedgerCategory(name: "Lương", kind: .income)
        #expect(income.isValid)
    }

    @Test func negativeAmountIsInvalid() {
        var draft = TransactionDraft(
            kind: .expense,
            account: Account(name: "Tiền mặt", kind: .cash)
        )
        draft.amount = -100
        #expect(draft.validate().contains(.missingAmount))
    }

    @Test func transferRequiresDestination() {
        var draft = TransactionDraft(
            kind: .transfer,
            account: Account(name: "Tiền mặt", kind: .cash)
        )
        draft.amount = 100_000
        #expect(draft.validate() == [.missingDestination])
    }

    @Test func transferRejectsSourceAsDestination() {
        let cash = Account(name: "Tiền mặt", kind: .cash)
        var draft = TransactionDraft(kind: .transfer, account: cash)
        draft.amount = 100_000
        draft.toAccount = cash
        #expect(draft.validate() == [.sameSourceAndDestination])
    }

    @Test func transferWithDifferentDestinationIsValid() {
        var draft = TransactionDraft(
            kind: .transfer,
            account: Account(name: "Tiền mặt", kind: .cash)
        )
        draft.amount = 100_000
        draft.toAccount = Account(name: "Ngân hàng", kind: .bank)
        #expect(draft.isValid)
    }

    @Test func categoryMustMatchKind() {
        var draft = TransactionDraft(
            kind: .expense,
            account: Account(name: "Tiền mặt", kind: .cash)
        )
        draft.amount = 10_000
        draft.category = LedgerCategory(name: "Lương", kind: .income)
        #expect(draft.validate() == [.categoryKindMismatch])
    }

    // MARK: - Kind switching

    @Test func switchingToTransferClearsCategoryAndBusiness() {
        var draft = TransactionDraft(kind: .expense)
        draft.category = LedgerCategory(name: "Ăn uống", kind: .expense)
        draft.business = Business(name: "Làm web")
        draft.setKind(.transfer)
        #expect(draft.category == nil)
        #expect(draft.business == nil)
    }

    @Test func switchingAwayFromTransferClearsDestination() {
        var draft = TransactionDraft(kind: .transfer)
        draft.toAccount = Account(name: "Ngân hàng", kind: .bank)
        draft.setKind(.income)
        #expect(draft.toAccount == nil)
    }

    @Test func switchingBetweenExpenseAndIncomeDropsMismatchedCategory() {
        var draft = TransactionDraft(kind: .expense)
        draft.category = LedgerCategory(name: "Ăn uống", kind: .expense)
        draft.setKind(.income)
        #expect(draft.category == nil)
    }

    @Test func setSameKindKeepsFields() {
        let category = LedgerCategory(name: "Ăn uống", kind: .expense)
        var draft = TransactionDraft(kind: .expense)
        draft.category = category
        draft.setKind(.expense)
        #expect(draft.category?.id == category.id)
    }

    // MARK: - Insert

    @Test func insertExpenseDecreasesSourceBalance() throws {
        let context = try makeContext()
        let cash = Account(name: "Tiền mặt", kind: .cash, openingBalance: 1_000_000)
        context.insert(cash)

        var draft = TransactionDraft(kind: .expense, account: cash)
        draft.amount = 250_000
        draft.category = LedgerCategory(name: "Ăn uống", kind: .expense)
        let transaction = try draft.insert(into: context)
        try context.save()

        #expect(cash.balance == 750_000)
        #expect(transaction.kind == .expense)
        #expect(transaction.amount == 250_000)
        #expect(transaction.category != nil)
        #expect(!transaction.needsReview)
    }

    @Test func insertIncomeIncreasesSourceBalance() throws {
        let context = try makeContext()
        let cash = Account(name: "Tiền mặt", kind: .cash, openingBalance: 1_000_000)
        let business = Business(name: "Làm web")
        context.insert(cash)
        context.insert(business)

        var draft = TransactionDraft(kind: .income, account: cash)
        draft.amount = 2_000_000
        draft.business = business
        let transaction = try draft.insert(into: context)
        try context.save()

        #expect(cash.balance == 3_000_000)
        #expect(transaction.business?.id == business.id)
    }

    @Test func insertTransferMovesBetweenAccounts() throws {
        let context = try makeContext()
        let cash = Account(name: "Tiền mặt", kind: .cash, openingBalance: 1_000_000)
        let bank = Account(name: "Ngân hàng", kind: .bank)
        context.insert(cash)
        context.insert(bank)

        var draft = TransactionDraft(kind: .transfer, account: cash)
        draft.amount = 300_000
        draft.toAccount = bank
        // Leftovers the form never shows for transfers must not be saved.
        draft.category = LedgerCategory(name: "Không lưu", kind: .expense)
        draft.business = Business(name: "Không lưu")
        let transaction = try draft.insert(into: context)
        try context.save()

        #expect(cash.balance == 700_000)
        #expect(bank.balance == 300_000)
        #expect(transaction.toAccount?.id == bank.id)
        #expect(transaction.category == nil)
        #expect(transaction.business == nil)
    }

    @Test func insertInvalidDraftThrowsAndSavesNothing() throws {
        let context = try makeContext()
        let draft = TransactionDraft(kind: .expense)
        #expect {
            try draft.insert(into: context)
        } throws: { error in
            (error as? TransactionDraftError) == .missingAmount
        }
        try context.save()
        #expect(try fetchAll(LedgerTransaction.self, in: context).isEmpty)
    }

    // MARK: - Apply

    @Test func applyEditsTransactionAndStampsUpdatedAt() throws {
        let context = try makeContext()
        let cash = Account(name: "Tiền mặt", kind: .cash, openingBalance: 1_000_000)
        context.insert(cash)
        let transaction = LedgerTransaction(
            kind: .expense,
            amount: 100_000,
            note: "Cũ",
            account: cash,
            needsReview: true
        )
        context.insert(transaction)
        try context.save()
        transaction.updatedAt = .distantPast

        var draft = TransactionDraft(transaction: transaction)
        #expect(draft.amount == 100_000)
        #expect(draft.note == "Cũ")
        #expect(draft.account?.id == cash.id)

        draft.amount = 777_000
        draft.note = "Đã sửa"
        try draft.apply(to: transaction)
        try context.save()

        #expect(transaction.amount == 777_000)
        #expect(transaction.note == "Đã sửa")
        #expect(!transaction.needsReview)
        #expect(transaction.updatedAt > .distantPast)
        #expect(cash.balance == 1_000_000 - 777_000)
    }

    @Test func applyKindChangeDropsDestinationAndRestoresBalance() throws {
        let context = try makeContext()
        let cash = Account(name: "Tiền mặt", kind: .cash, openingBalance: 1_000_000)
        let bank = Account(name: "Ngân hàng", kind: .bank)
        context.insert(cash)
        context.insert(bank)
        let transaction = LedgerTransaction(
            kind: .transfer,
            amount: 200_000,
            account: cash,
            toAccount: bank
        )
        context.insert(transaction)
        try context.save()
        #expect(cash.balance == 800_000)
        #expect(bank.balance == 200_000)

        var draft = TransactionDraft(transaction: transaction)
        draft.setKind(.expense)
        draft.amount = 500_000
        try draft.apply(to: transaction)
        try context.save()

        #expect(transaction.toAccount == nil)
        #expect(cash.balance == 500_000)
        // Bank no longer receives the transfer — back to its opening balance.
        #expect(bank.balance == 0)
    }

    @Test func applyInvalidDraftLeavesTransactionUntouched() throws {
        let context = try makeContext()
        let cash = Account(name: "Tiền mặt", kind: .cash, openingBalance: 1_000_000)
        context.insert(cash)
        let transaction = LedgerTransaction(
            kind: .expense, amount: 100_000, account: cash, needsReview: true
        )
        context.insert(transaction)
        try context.save()

        var draft = TransactionDraft(transaction: transaction)
        draft.amount = 0
        #expect {
            try draft.apply(to: transaction)
        } throws: { error in
            (error as? TransactionDraftError) == .missingAmount
        }
        #expect(transaction.amount == 100_000)
        #expect(transaction.needsReview)
    }
}
