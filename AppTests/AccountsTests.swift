import Testing
import Foundation
import SwiftData
import FinanceCore
@testable import AMFinance

@MainActor
struct AccountsTests {

    private func makeContext() throws -> ModelContext {
        ModelContext(try AppModelContainer.make(inMemory: true))
    }

    // MARK: - AccountDraft validation

    @Test func draftRequiresName() {
        var draft = AccountDraft()
        draft.name = "   "
        #expect(draft.validate() == .missingName)
        draft.name = "Tiền mặt"
        #expect(draft.validate() == nil)
    }

    @Test func draftValidatesStatementDayOnlyForCreditCard() {
        var draft = AccountDraft()
        draft.name = "Thẻ"
        draft.kind = .creditCard
        draft.statementDay = 0
        #expect(draft.validate() == .invalidStatementDay)
        draft.statementDay = 32
        #expect(draft.validate() == .invalidStatementDay)
        draft.statementDay = 31
        #expect(draft.validate() == nil)
        // The day is ignored for non-card kinds.
        draft.kind = .cash
        draft.statementDay = 0
        #expect(draft.validate() == nil)
    }

    @Test func draftRequiresPositiveTermRateAndPrincipalForLoan() {
        var draft = AccountDraft()
        draft.name = "Vay mua nhà"
        draft.kind = .loan

        #expect(draft.validate() == .invalidLoanPrincipal)
        draft.loanPrincipal = 500_000_000
        #expect(draft.validate() == .invalidLoanTerm)
        draft.loanTermMonths = 120
        #expect(draft.validate() == .invalidLoanRate)
        draft.loanAnnualRatePercent = -1
        #expect(draft.validate() == .invalidLoanRate)
        draft.loanAnnualRatePercent = 8.5
        draft.loanPaymentDay = 0
        #expect(draft.validate() == .invalidLoanPaymentDay)
        draft.loanPaymentDay = 5
        #expect(draft.validate() == nil)
    }

    // MARK: - Liability sign mapping

    @Test func draftStoresTypedDebtAsNegativeOpeningBalance() {
        var draft = AccountDraft()
        draft.name = "Thẻ Visa"
        draft.kind = .creditCard
        draft.openingBalance = 5_000_000

        let account = Account(name: "Thẻ Visa", kind: .creditCard)
        draft.apply(to: account)
        #expect(account.openingBalance == -5_000_000)
    }

    @Test func draftReadsStoredDebtBackAsPositive() {
        let card = Account(name: "Thẻ Visa", kind: .creditCard, openingBalance: -5_000_000)
        let draft = AccountDraft(account: card)
        #expect(draft.openingBalance == 5_000_000)
        #expect(draft.signedOpeningBalance == -5_000_000)

        let loan = Account(name: "Khoản vay", kind: .loan, openingBalance: -20_000_000)
        #expect(AccountDraft(account: loan).openingBalance == 20_000_000)
    }

    @Test func draftRoundTripsAssetOpeningBalance() {
        var draft = AccountDraft()
        draft.name = "Ngân hàng"
        draft.kind = .bank
        draft.openingBalance = 3_000_000

        let account = Account(name: "Ngân hàng", kind: .bank)
        draft.apply(to: account)
        #expect(account.openingBalance == 3_000_000)
        #expect(AccountDraft(account: account).openingBalance == 3_000_000)
    }

    @Test func draftApplyWritesKindSpecificFields() {
        var draft = AccountDraft()
        draft.name = "Khoản vay"
        draft.kind = .loan
        draft.loanPrincipal = 120_000_000
        draft.loanAnnualRatePercent = 9.6
        draft.loanTermMonths = 36
        draft.loanPaymentDay = 10
        draft.loanMethod = .annuity

        let account = Account(name: "Khoản vay", kind: .loan)
        draft.apply(to: account)
        #expect(account.loanPrincipal == 120_000_000)
        #expect(account.loanAnnualRatePercent == 9.6)
        #expect(account.loanTermMonths == 36)
        #expect(account.loanPaymentDay == 10)
        #expect(account.loanMethodRaw == LoanMethod.annuity.rawValue)
        // Card fields stay cleared on a loan.
        #expect(account.creditLimit == nil)
        #expect(account.statementDay == nil)
    }

    // MARK: - Receivable business link

    @Test func draftRoundTripsReceivableBusiness() throws {
        let context = try makeContext()
        let business = Business(name: "Chạy quảng cáo thuê")
        context.insert(business)
        let client = Account(name: "Khách A", kind: .receivable, openingBalance: 2_000_000)
        client.business = business
        context.insert(client)
        try context.save()

        let draft = AccountDraft(account: client)
        #expect(draft.business?.id == business.id)
        #expect(draft.openingBalance == 2_000_000) // asset — positive, not negated
        #expect(draft.validate() == nil)

        var edited = draft
        edited.business = nil
        edited.apply(to: client)
        #expect(client.business == nil)
    }

    @Test func draftClearsBusinessOnNonReceivableKinds() {
        var draft = AccountDraft()
        draft.name = "Tiền mặt"
        draft.kind = .cash
        draft.business = Business(name: "Làm web")

        let account = Account(name: "Tiền mặt", kind: .cash)
        draft.apply(to: account)
        #expect(account.business == nil)
    }

    // MARK: - AccountGrouping

    @Test func groupingOrdersKindsAndComputesSubtotals() throws {
        let context = try makeContext()
        let cash = Account(name: "Tiền mặt", kind: .cash, openingBalance: 1_000_000)
        let bank = Account(name: "Ngân hàng", kind: .bank, openingBalance: 3_000_000)
        let wallet = Account(name: "Momo", kind: .eWallet, openingBalance: 500_000)
        let client = Account(name: "Khách A", kind: .receivable, openingBalance: 4_000_000)
        let card = Account(name: "Thẻ", kind: .creditCard, openingBalance: -2_000_000)
        let loan = Account(name: "Vay", kind: .loan, openingBalance: -10_000_000)
        for account in [loan, card, client, wallet, bank, cash] {
            context.insert(account)
        }
        try context.save()

        let all = try context.fetch(FetchDescriptor<Account>())
        let sections = AccountGrouping.sections(from: all)

        #expect(sections.map(\.kind) == [.cash, .bank, .eWallet, .receivable, .creditCard, .loan])
        #expect(sections.map(\.subtotal) == [1_000_000, 3_000_000, 500_000, 4_000_000, -2_000_000, -10_000_000])
    }

    @Test func groupingSplitsArchivedAndSumsWithinKind() throws {
        let context = try makeContext()
        let active = Account(name: "Mới", kind: .bank, openingBalance: 1_000_000, sortOrder: 0)
        let old = Account(name: "Cũ", kind: .bank, openingBalance: 99_000_000, sortOrder: 1, isArchived: true)
        let other = Account(name: "Khác", kind: .bank, openingBalance: 2_000_000, sortOrder: 2)
        for account in [old, other, active] {
            context.insert(account)
        }
        try context.save()

        let all = try context.fetch(FetchDescriptor<Account>())
        let sections = AccountGrouping.sections(from: all)
        #expect(sections.count == 1)
        #expect(sections[0].accounts.map(\.name) == ["Mới", "Khác"])
        #expect(sections[0].subtotal == 3_000_000)
        #expect(AccountGrouping.archived(from: all).map(\.name) == ["Cũ"])
    }

    // MARK: - AccountBalanceAdjustment

    @Test func adjustmentForAssetAccount() {
        // Balance 1.000.000, real 1.500.000 → income 500.000.
        let up = AccountBalanceAdjustment.adjustment(current: 1_000_000, target: 1_500_000)
        #expect(up?.kind == .income)
        #expect(up?.amount == 500_000)
        // Real 700.000 → expense 300.000.
        let down = AccountBalanceAdjustment.adjustment(current: 1_000_000, target: 700_000)
        #expect(down?.kind == .expense)
        #expect(down?.amount == 300_000)
        // Nothing to do when equal.
        #expect(AccountBalanceAdjustment.adjustment(current: 1_000_000, target: 1_000_000) == nil)
    }

    @Test func adjustmentForLiabilityAccount() {
        // Typed debt is negated into a signed target for liabilities.
        #expect(AccountBalanceAdjustment.signedTarget(typed: 2_000_000, kind: .creditCard) == -2_000_000)
        #expect(AccountBalanceAdjustment.signedTarget(typed: 2_000_000, kind: .loan) == -2_000_000)
        #expect(AccountBalanceAdjustment.signedTarget(typed: 2_000_000, kind: .cash) == 2_000_000)

        // Card shows -5.000.000, real debt is 3.000.000 → income 2.000.000
        // pushes the balance back towards zero.
        let adj = AccountBalanceAdjustment.adjustment(current: -5_000_000, target: -3_000_000)
        #expect(adj?.kind == .income)
        #expect(adj?.amount == 2_000_000)
    }

    @Test func adjustmentTransactionLandsOnTarget() throws {
        let context = try makeContext()
        let account = Account(name: "Tiền mặt", kind: .cash, openingBalance: 1_000_000)
        context.insert(account)
        try context.save()

        let target = AccountBalanceAdjustment.signedTarget(typed: 1_500_000, kind: account.kind)
        let adjustment = try #require(
            AccountBalanceAdjustment.adjustment(current: account.balance, target: target)
        )
        context.insert(LedgerTransaction(
            kind: adjustment.kind, amount: adjustment.amount,
            note: "Điều chỉnh số dư", account: account
        ))
        try context.save()

        #expect(account.balance == 1_500_000)
    }

    // MARK: - Delete rule

    @Test func canDeleteOnlyWithoutTransactions() throws {
        let context = try makeContext()
        let cash = Account(name: "Tiền mặt", kind: .cash)
        let bank = Account(name: "Ngân hàng", kind: .bank)
        context.insert(cash)
        context.insert(bank)
        try context.save()

        #expect(AccountGrouping.canDelete(cash))
        #expect(AccountGrouping.canDelete(bank))

        // Being the source of a transaction blocks deletion.
        context.insert(LedgerTransaction(kind: .expense, amount: 10_000, account: cash))
        try context.save()
        #expect(!AccountGrouping.canDelete(cash))

        // Being a transfer destination blocks it too.
        context.insert(LedgerTransaction(
            kind: .transfer, amount: 10_000, account: cash, toAccount: bank
        ))
        try context.save()
        #expect(!AccountGrouping.canDelete(bank))
    }

    // MARK: - AccountCardCycleInfo

    private func ymd(_ year: Int, _ month: Int, _ day: Int) -> Date {
        AppCalendar.vietnam.date(
            from: DateComponents(year: year, month: month, day: day)
        )!
    }

    @Test func cardCycleInfoNeedsStatementDay() {
        #expect(AccountCardCycleInfo(
            statementDay: nil, graceDays: 15,
            onOrAfter: ymd(2026, 7, 1), calendar: AppCalendar.vietnam
        ) == nil)
    }

    /// Only `statementDay` set: the next statement date shows, but there is
    /// no due date — the detail screen shows the "ân hạn" hint instead.
    @Test func cardCycleInfoWithoutGraceDaysHasNoDueDate() throws {
        let info = try #require(AccountCardCycleInfo(
            statementDay: 20, graceDays: nil,
            onOrAfter: ymd(2026, 7, 1), calendar: AppCalendar.vietnam
        ))
        #expect(info.nextStatementDate == ymd(2026, 7, 20))
        #expect(info.nextDueDate == nil)
    }

    /// Both fields set: statement date and the still-upcoming due date of
    /// the last closed statement (Jun 20 + 15 days = Jul 5).
    @Test func cardCycleInfoWithGraceDaysHasBothDates() throws {
        let info = try #require(AccountCardCycleInfo(
            statementDay: 20, graceDays: 15,
            onOrAfter: ymd(2026, 7, 1), calendar: AppCalendar.vietnam
        ))
        #expect(info.nextStatementDate == ymd(2026, 7, 20))
        #expect(info.nextDueDate == ymd(2026, 7, 5))

        // Once that due date passes, the open cycle's due date is next.
        let later = try #require(AccountCardCycleInfo(
            statementDay: 20, graceDays: 15,
            onOrAfter: ymd(2026, 7, 10), calendar: AppCalendar.vietnam
        ))
        #expect(later.nextStatementDate == ymd(2026, 7, 20))
        #expect(later.nextDueDate == ymd(2026, 8, 4))
    }
}
