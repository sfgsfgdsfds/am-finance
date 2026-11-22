import Testing
import Foundation
import SwiftData
import FinanceCore
@testable import AMFinance

@MainActor
struct LoansTests {
    private let calendar = AppCalendar.vietnam

    private func makeContext() throws -> ModelContext {
        ModelContext(try AppModelContainer.make(inMemory: true))
    }

    private func date(_ y: Int, _ m: Int, _ d: Int) -> Date {
        calendar.date(from: DateComponents(year: y, month: m, day: d))!
    }

    /// A loan account with complete fields: 120tr over 12 months at 12%/năm
    /// disbursed 15/01/2025, due on the 20th — first installment 20/02/2025.
    @discardableResult
    private func makeLoan(
        in context: ModelContext,
        principal: Int64 = 120_000_000,
        rate: Double = 12,
        term: Int = 12,
        paymentDay: Int = 20,
        method: LoanMethod = .equalPrincipal,
        openingBalance: Int64? = nil
    ) -> Account {
        let account = Account(
            name: "Vay mua nhà", kind: .loan,
            openingBalance: openingBalance ?? -principal
        )
        account.loanPrincipal = principal
        account.loanAnnualRatePercent = rate
        account.loanTermMonths = term
        account.loanStartDate = date(2025, 1, 15)
        account.loanPaymentDay = paymentDay
        account.loanMethodRaw = method.rawValue
        context.insert(account)
        return account
    }

    private func fetchAll<T: PersistentModel>(_ type: T.Type, in context: ModelContext) throws -> [T] {
        try context.fetch(FetchDescriptor<T>())
    }

    // MARK: - LoanPlan completeness

    @Test func planIsNilUntilLoanFieldsComplete() throws {
        let context = try makeContext()
        let loan = Account(name: "Vay", kind: .loan, openingBalance: -120_000_000)
        context.insert(loan)
        #expect(LoanPlan(account: loan, basis: .monthly, calendar: calendar) == nil)

        loan.loanPrincipal = 120_000_000
        loan.loanAnnualRatePercent = 12
        loan.loanTermMonths = 12
        loan.loanStartDate = date(2025, 1, 15)
        loan.loanPaymentDay = 20
        loan.loanMethodRaw = LoanMethod.equalPrincipal.rawValue
        #expect(LoanPlan(account: loan, basis: .monthly, calendar: calendar) != nil)
    }

    @Test func planIsNilForNonLoanAccounts() throws {
        let context = try makeContext()
        let bank = Account(name: "Ngân hàng", kind: .bank, openingBalance: 5_000_000)
        context.insert(bank)
        #expect(LoanPlan(account: bank, basis: .monthly, calendar: calendar) == nil)
    }

    // MARK: - Paid-count inference

    @Test func inferNonePaidWhenDebtEqualsPrincipal() throws {
        let context = try makeContext()
        let loan = makeLoan(in: context)
        let plan = try #require(LoanPlan(account: loan, basis: .monthly, calendar: calendar))
        #expect(plan.remainingDebt == 120_000_000)
        #expect(plan.paidInstallmentCount == 0)
        #expect(plan.nextInstallment?.index == 1)
        #expect(plan.progressFraction == 0)
        #expect(!plan.isFullyRepaid)
    }

    @Test func inferSomePaidFromLowerDebt() throws {
        let context = try makeContext()
        // 120tr / 12 months of equal principal → each kỳ clears 10tr.
        let loan = makeLoan(in: context, openingBalance: -90_000_000)
        let plan = try #require(LoanPlan(account: loan, basis: .monthly, calendar: calendar))
        #expect(plan.paidInstallmentCount == 3)
        #expect(plan.nextInstallment?.index == 4)
        #expect(plan.principalRepaid == 30_000_000)
        #expect(plan.progressFraction == 0.25)
    }

    @Test func partialPaymentStillCountsWholeInstallments() throws {
        let context = try makeContext()
        // 95tr debt is 2.5 installments of principal — kỳ 3 is still due.
        let loan = makeLoan(in: context, openingBalance: -95_000_000)
        let plan = try #require(LoanPlan(account: loan, basis: .monthly, calendar: calendar))
        #expect(plan.paidInstallmentCount == 2)
        #expect(plan.nextInstallment?.index == 3)
    }

    @Test func inferFullyRepaidWhenNoDebt() throws {
        let context = try makeContext()
        let loan = makeLoan(in: context, openingBalance: 0)
        let plan = try #require(LoanPlan(account: loan, basis: .monthly, calendar: calendar))
        #expect(plan.paidInstallmentCount == plan.schedule.installments.count)
        #expect(plan.nextInstallment == nil)
        #expect(plan.isFullyRepaid)
        #expect(plan.progressFraction == 1)
    }

    @Test func inferNonePaidWhenDebtAbovePlan() throws {
        let context = try makeContext()
        // Late fees pushed the real debt past the original principal.
        let loan = makeLoan(in: context, openingBalance: -150_000_000)
        let plan = try #require(LoanPlan(account: loan, basis: .monthly, calendar: calendar))
        #expect(plan.paidInstallmentCount == 0)
        #expect(plan.nextInstallment?.index == 1)
        #expect(plan.progressFraction == 0)
    }

    @Test func nextInstallmentMatchesFinanceCoreForBothMethods() throws {
        for method in [LoanMethod.equalPrincipal, .annuity] {
            let context = try makeContext()
            let schedule = try LoanTerms(
                principal: 120_000_000, termMonths: 12,
                startDate: date(2025, 1, 15), paymentDay: 20,
                method: method, basis: .monthly,
                ratePeriods: [LoanRatePeriod(fromInstallment: 1, annualRatePercent: 12)]
            ).schedule(calendar: calendar)

            // Pretend exactly three installments were paid.
            let loan = makeLoan(
                in: context, method: method,
                openingBalance: -schedule.balance(afterInstallmentsPaid: 3)
            )
            let plan = try #require(LoanPlan(account: loan, basis: .monthly, calendar: calendar))
            #expect(plan.paidInstallmentCount == 3)
            #expect(plan.nextInstallment == schedule.installments[3])
            #expect(plan.nextInstallment?.index == 4)
        }
    }

    // MARK: - Rate changes

    @Test func rateChangeAppliesFromChosenInstallment() throws {
        let context = try makeContext()
        // 240tr / 24 months: 12%/năm, floating 18% từ kỳ 13.
        let loan = makeLoan(in: context, principal: 240_000_000, term: 24)
        context.insert(LoanRateChange(
            fromInstallment: 13, annualRatePercent: 18, account: loan
        ))
        try context.save()

        let plan = try #require(LoanPlan(account: loan, basis: .monthly, calendar: calendar))
        #expect(plan.schedule.installments.count == 24)
        // Kỳ 12 sees 130tr at 1%/month; kỳ 13 sees 120tr at 1.5%/month.
        #expect(plan.schedule.installments[11].interest == 1_300_000)
        #expect(plan.schedule.installments[12].interest == 1_800_000)
        #expect(plan.annualRate(atInstallment: 1) == 12)
        #expect(plan.annualRate(atInstallment: 12) == 12)
        #expect(plan.annualRate(atInstallment: 13) == 18)
        #expect(plan.annualRate(atInstallment: 24) == 18)
        #expect(plan.currentAnnualRate == 12)
        #expect(plan.schedule.terms.ratePeriods.count == 2)
    }

    @Test func deletingRateChangeRestoresBaseSchedule() throws {
        let context = try makeContext()
        let loan = makeLoan(in: context, principal: 240_000_000, term: 24)
        let change = LoanRateChange(fromInstallment: 13, annualRatePercent: 18, account: loan)
        context.insert(change)
        try context.save()
        #expect(loan.loanRateChanges?.count == 1)

        context.delete(change)
        try context.save()
        let plan = try #require(LoanPlan(account: loan, basis: .monthly, calendar: calendar))
        // Back to a flat 12% — kỳ 13 interest is on 120tr at 1%/month.
        #expect(plan.schedule.installments[12].interest == 1_200_000)
        #expect(plan.schedule.terms.ratePeriods.count == 1)
    }

    // MARK: - Recording payments

    @Test func recordedPaymentMovesPrincipalAndInterest() throws {
        let context = try makeContext()
        try SeedData.seedIfNeeded(context: context)
        let bank = Account(name: "Ngân hàng", kind: .bank, openingBalance: 50_000_000)
        context.insert(bank)
        // Three installments already paid → next is kỳ 4.
        let loan = makeLoan(in: context, openingBalance: -90_000_000)
        try context.save()

        let plan = try #require(LoanPlan(account: loan, basis: .monthly, calendar: calendar))
        var draft = LoanPaymentDraft(plan: plan)
        draft.payingAccount = bank
        // Kỳ 4 of the plan: 10tr principal + 900k interest (90tr at 1%/month).
        #expect(draft.installmentIndex == 4)
        #expect(draft.principal == 10_000_000)
        #expect(draft.interest == 900_000)
        #expect(draft.isValid)

        let category = try #require(
            fetchAll(LedgerCategory.self, in: context)
                .first { $0.name == LoanPaymentDraft.interestCategoryName }
        )
        #expect(draft.insert(into: context, loan: loan, interestCategory: category))
        try context.save()

        // The loan only moves by the principal; the payer covers both parts.
        #expect(loan.balance == -80_000_000)
        #expect(bank.balance == 50_000_000 - 10_900_000)

        let transactions = try fetchAll(LedgerTransaction.self, in: context)
        #expect(transactions.count == 2)
        let transfer = try #require(transactions.first { $0.kind == .transfer })
        #expect(transfer.amount == 10_000_000)
        #expect(transfer.account?.id == bank.id)
        #expect(transfer.toAccount?.id == loan.id)
        #expect(transfer.note == "Trả gốc Vay mua nhà kỳ 4")
        let expense = try #require(transactions.first { $0.kind == .expense })
        #expect(expense.amount == 900_000)
        #expect(expense.account?.id == bank.id)
        #expect(expense.category?.id == category.id)
        #expect(expense.note == "Lãi vay Vay mua nhà kỳ 4")
    }

    @Test func zeroInterestSkipsTheExpenseRow() throws {
        let context = try makeContext()
        let bank = Account(name: "Ngân hàng", kind: .bank, openingBalance: 50_000_000)
        context.insert(bank)
        let loan = makeLoan(in: context)
        try context.save()

        var draft = LoanPaymentDraft(plan: nil)
        draft.principal = 10_000_000
        draft.interest = 0
        draft.payingAccount = bank
        #expect(draft.insert(into: context, loan: loan, interestCategory: nil))
        try context.save()

        let transactions = try fetchAll(LedgerTransaction.self, in: context)
        #expect(transactions.count == 1)
        #expect(transactions[0].kind == .transfer)
        #expect(loan.balance == -110_000_000)
        #expect(bank.balance == 40_000_000)
    }

    @Test func zeroPrincipalSkipsTheTransferRow() throws {
        let context = try makeContext()
        let bank = Account(name: "Ngân hàng", kind: .bank, openingBalance: 50_000_000)
        context.insert(bank)
        let loan = makeLoan(in: context)
        try context.save()

        var draft = LoanPaymentDraft(plan: nil)
        draft.principal = 0
        draft.interest = 1_200_000
        draft.payingAccount = bank
        #expect(draft.insert(into: context, loan: loan, interestCategory: nil))
        try context.save()

        let transactions = try fetchAll(LedgerTransaction.self, in: context)
        #expect(transactions.count == 1)
        #expect(transactions[0].kind == .expense)
        #expect(loan.balance == -120_000_000)
        #expect(bank.balance == 48_800_000)
    }

    @Test func invalidPaymentDraftInsertsNothing() throws {
        let context = try makeContext()
        let loan = makeLoan(in: context)
        try context.save()

        var draft = LoanPaymentDraft(plan: nil)
        draft.principal = 10_000_000
        draft.interest = 1_000_000
        // No paying account chosen.
        #expect(!draft.isValid)
        #expect(!draft.insert(into: context, loan: loan, interestCategory: nil))
        try context.save()
        #expect(try fetchAll(LedgerTransaction.self, in: context).isEmpty)
        #expect(loan.balance == -120_000_000)
    }

    /// A client receivable is not the owner's money — only cash, bank and
    /// e-wallet accounts may pay a loan installment.
    @Test func payingAccountPickerExcludesReceivablesAndLiabilities() {
        let cash = Account(name: "Tiền mặt", kind: .cash)
        let bank = Account(name: "Ngân hàng", kind: .bank)
        let wallet = Account(name: "Momo", kind: .eWallet)
        let client = Account(name: "Khách A", kind: .receivable)
        let card = Account(name: "Thẻ", kind: .creditCard)
        let otherLoan = Account(name: "Vay khác", kind: .loan)
        let archived = Account(name: "Cũ", kind: .bank, isArchived: true)
        let all = [cash, bank, wallet, client, card, otherLoan, archived]

        let payers = LoanPayingAccountPicker.candidates(all)
        #expect(Set(payers.map(\.id)) == Set([cash, bank, wallet].map(\.id)))
    }

    // MARK: - Prepayment

    @Test func prepaymentRecordsSingleTransfer() throws {
        let context = try makeContext()
        let bank = Account(name: "Ngân hàng", kind: .bank, openingBalance: 50_000_000)
        context.insert(bank)
        let loan = makeLoan(in: context)
        try context.save()

        var draft = LoanPrepaymentDraft(amount: 20_000_000)
        draft.payingAccount = bank
        #expect(draft.insert(into: context, loan: loan))
        try context.save()

        #expect(loan.balance == -100_000_000)
        #expect(bank.balance == 30_000_000)
        let transactions = try fetchAll(LedgerTransaction.self, in: context)
        #expect(transactions.count == 1)
        #expect(transactions[0].kind == .transfer)
        #expect(transactions[0].note == "Trả gốc trước hạn Vay mua nhà")

        // The plan re-infers two paid installments from the smaller debt.
        let plan = try #require(LoanPlan(account: loan, basis: .monthly, calendar: calendar))
        #expect(plan.paidInstallmentCount == 2)
        #expect(plan.nextInstallment?.index == 3)
    }

    // MARK: - Rate-change validation

    @Test func rateChangeValidation() {
        func check(_ from: Int, _ rate: Double, term: Int = 12, existing: Set<Int> = [])
        -> LoanRateChangeError? {
            LoanPlan.validateRateChange(
                fromInstallment: from, annualRatePercent: rate,
                termMonths: term, existingInstallments: existing
            )
        }
        #expect(check(1, 10) == .invalidInstallment)
        #expect(check(0, 10) == .invalidInstallment)
        #expect(check(13, 10) == .invalidInstallment)
        #expect(check(2, 10, term: 1) == .invalidInstallment)
        #expect(check(2, 0) == .invalidRate)
        #expect(check(2, -5) == .invalidRate)
        #expect(check(2, .nan) == .invalidRate)
        #expect(check(5, 10, existing: [5]) == .duplicateInstallment)
        #expect(check(5, 10, existing: [4, 6]) == nil)
        #expect(check(12, 10) == nil)
        #expect(check(2, 10) == nil)
    }

    // MARK: - Basis store

    @Test func basisStoreDefaultsToActual365AndPersistsPerAccount() {
        let defaults = UserDefaults(suiteName: "LoansTests.\(UUID().uuidString)")!
        let store = LoanInterestBasisStore(defaults: defaults)
        let accountID = UUID()
        #expect(store.basis(for: accountID) == .actual365)

        store.set(.monthly, for: accountID)
        #expect(store.basis(for: accountID) == .monthly)
        #expect(store.basis(for: UUID()) == .actual365)
    }

    // MARK: - Due-date helpers

    @Test func daysUntilNextDueCountsDownAndFlagsOverdue() throws {
        let context = try makeContext()
        let loan = makeLoan(in: context) // first due 20/02/2025
        let plan = try #require(LoanPlan(account: loan, basis: .monthly, calendar: calendar))
        #expect(plan.nextInstallment?.dueDate == date(2025, 2, 20))

        #expect(plan.daysUntilNextDue(now: date(2025, 2, 10), calendar: calendar) == 10)
        #expect(!plan.isOverdue(now: date(2025, 2, 10), calendar: calendar))
        #expect(plan.daysUntilNextDue(now: date(2025, 2, 20), calendar: calendar) == 0)
        #expect(!plan.isOverdue(now: date(2025, 2, 20), calendar: calendar))
        #expect(plan.daysUntilNextDue(now: date(2025, 2, 21), calendar: calendar) == -1)
        #expect(plan.isOverdue(now: date(2025, 2, 21), calendar: calendar))
    }

    @Test func loanDateFormatRendersFullVietnameseDate() {
        #expect(LoanDateFormat.full(date(2025, 2, 5)) == "05/02/2025")
        #expect(LoanDateFormat.full(date(2026, 11, 20)) == "20/11/2026")
    }
}
