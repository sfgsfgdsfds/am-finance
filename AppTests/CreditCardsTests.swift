import Testing
import Foundation
import SwiftData
import FinanceCore
@testable import AMFinance

@MainActor
struct CreditCardsTests {

    private let calendar = AppCalendar.vietnam
    private let config = CreditCardCycleConfig(statementDay: 20, graceDays: 15)

    private func makeContext() throws -> ModelContext {
        ModelContext(try AppModelContainer.make(inMemory: true))
    }

    /// Start-of-day (or a given time) in the app calendar.
    private func ymd(_ year: Int, _ month: Int, _ day: Int,
                     hour: Int = 0, minute: Int = 0) -> Date {
        calendar.date(from: DateComponents(year: year, month: month, day: day,
                                           hour: hour, minute: minute))!
    }

    private func overview(
        openingBalance: Int64 = 0,
        entries: [CreditCardEntry],
        creditLimit: Int64? = 10_000_000,
        now: Date
    ) -> CreditCardOverview {
        CreditCardOverview.build(
            openingBalance: openingBalance,
            entries: entries,
            config: config,
            creditLimit: creditLimit,
            now: now,
            calendar: calendar
        )
    }

    // MARK: - Overview numbers

    @Test func overviewForHandMadeHistory() {
        // Closed cycle May 21 – Jun 20; open cycle Jun 21 – Jul 20.
        let entries = [
            CreditCardEntry(date: ymd(2026, 6, 10), delta: -1_000_000),
            CreditCardEntry(date: ymd(2026, 6, 15), delta: -500_000),
            CreditCardEntry(date: ymd(2026, 6, 25), delta: 400_000),   // payment after close
            CreditCardEntry(date: ymd(2026, 6, 28), delta: -200_000),  // new cycle
        ]
        let o = overview(entries: entries, now: ymd(2026, 7, 1))

        #expect(o.debt == 1_300_000)
        #expect(o.creditBalance == 0)
        #expect(o.creditLimit == 10_000_000)
        #expect(o.availableCredit == 8_700_000)
        #expect(o.utilization == 0.13)
        #expect(o.utilizationLevel == .low)
        #expect(o.utilizationText == "13%")

        let s = o.lastStatement
        #expect(s.cycle.start == ymd(2026, 5, 21))
        #expect(s.cycle.end == ymd(2026, 6, 20))
        #expect(s.periodText == "21/05 – 20/06/2026")
        #expect(s.balance == 1_500_000)
        #expect(s.paidSinceClosing == 400_000)
        #expect(s.amountDue == 1_100_000)
        #expect(s.minimumPayment == 55_000)
        #expect(!s.paidInFull)
        #expect(s.dueDate == ymd(2026, 7, 5))
        #expect(s.dueDateText == "05/07/2026")
        #expect(s.daysUntilDue == 4)
        #expect(s.dueStatusText == "Còn 4 ngày")
        #expect(!s.isOverdue)

        let c = o.openCycle
        #expect(c.cycle.start == ymd(2026, 6, 21))
        #expect(c.cycle.end == ymd(2026, 7, 20))
        #expect(c.periodText == "21/06 – 20/07/2026")
        #expect(c.spending == 200_000)
        #expect(c.closingDateText == "20/07/2026")
        #expect(c.daysUntilClosing == 19)
        #expect(c.closingStatusText == "Còn 19 ngày")
    }

    @Test func fullyPaidStatementLeavesCardInCredit() {
        let entries = [
            CreditCardEntry(date: ymd(2026, 6, 10), delta: -1_000_000),
            CreditCardEntry(date: ymd(2026, 6, 25), delta: 1_500_000),  // overpaid after close
        ]
        let o = overview(entries: entries, now: ymd(2026, 7, 1))

        #expect(o.debt == 0)
        #expect(o.creditBalance == 500_000)
        #expect(o.utilization == 0)
        #expect(o.lastStatement.amountDue == 0)
        #expect(o.lastStatement.paidInFull)
        // "Đã trả sau chốt" is capped at the statement balance.
        #expect(o.lastStatement.paidSinceClosing == 1_000_000)
        #expect(o.lastStatement.minimumPayment == 0)
        #expect(!o.lastStatement.isOverdue)
    }

    @Test func overdueStatementCountsDaysAndFlags() {
        let entries = [CreditCardEntry(date: ymd(2026, 6, 10), delta: -1_000_000)]
        let o = overview(entries: entries, now: ymd(2026, 7, 8))

        #expect(o.lastStatement.daysUntilDue == -3)
        #expect(o.lastStatement.dueStatusText == "Quá hạn 3 ngày")
        #expect(o.lastStatement.isOverdue)
        #expect(o.lastStatement.amountDue == 1_000_000)
        // 5% of 1.000.000 = 50.000 — floor met exactly.
        #expect(o.lastStatement.minimumPayment == 50_000)

        // Same statement on the due day itself.
        let onDue = overview(entries: entries, now: ymd(2026, 7, 5))
        #expect(onDue.lastStatement.daysUntilDue == 0)
        #expect(onDue.lastStatement.dueStatusText == "Hôm nay")
        #expect(!onDue.lastStatement.isOverdue)
    }

    @Test func cardStartingInCredit() {
        // A positive opening balance on a card means money stored on it.
        let o = overview(
            openingBalance: 500_000,
            entries: [CreditCardEntry(date: ymd(2026, 6, 10), delta: -200_000)],
            now: ymd(2026, 7, 1)
        )
        #expect(o.debt == 0)
        #expect(o.creditBalance == 300_000)
        #expect(o.utilization == 0)
        #expect(o.lastStatement.paidInFull)
    }

    @Test func missingLimitGivesZeroUtilization() {
        let entries = [CreditCardEntry(date: ymd(2026, 6, 10), delta: -2_500_000)]
        let noLimit = overview(entries: entries, creditLimit: nil, now: ymd(2026, 7, 1))
        #expect(noLimit.creditLimit == nil)
        #expect(noLimit.availableCredit == nil)
        #expect(noLimit.utilization == 0)
        #expect(noLimit.utilizationText == "0%")
        #expect(noLimit.utilizationLevel == .low)

        // A zero or negative limit is treated like no limit.
        let zeroLimit = overview(entries: entries, creditLimit: 0, now: ymd(2026, 7, 1))
        #expect(zeroLimit.creditLimit == nil)
        #expect(zeroLimit.utilization == 0)
    }

    @Test func utilizationLevels() {
        #expect(CreditCardUtilizationLevel(0) == .low)
        #expect(CreditCardUtilizationLevel(0.49) == .low)
        #expect(CreditCardUtilizationLevel(0.5) == .medium)
        #expect(CreditCardUtilizationLevel(0.69) == .medium)
        #expect(CreditCardUtilizationLevel(0.7) == .high)
        #expect(CreditCardUtilizationLevel(1.2) == .high)
    }

    @Test func dueDateLabels() {
        #expect(CreditCardOverview.dueStatusText(daysUntilDue: 5) == "Còn 5 ngày")
        #expect(CreditCardOverview.dueStatusText(daysUntilDue: 1) == "Còn 1 ngày")
        #expect(CreditCardOverview.dueStatusText(daysUntilDue: 0) == "Hôm nay")
        #expect(CreditCardOverview.dueStatusText(daysUntilDue: -3) == "Quá hạn 3 ngày")
        #expect(CreditCardOverview.countdownText(days: 0) == "Hôm nay")
        #expect(CreditCardOverview.countdownText(days: 7) == "Còn 7 ngày")
    }

    // MARK: - Entries from the model

    @Test func entriesMapEveryRoleToSignedDelta() throws {
        let context = try makeContext()
        let bank = Account(name: "Ngân hàng", kind: .bank, openingBalance: 10_000_000)
        let card = Account(name: "Thẻ Visa", kind: .creditCard)
        context.insert(bank)
        context.insert(card)
        let now = Date.now
        context.insert(LedgerTransaction(
            kind: .expense, amount: 100, date: now, account: card          // purchase
        ))
        context.insert(LedgerTransaction(
            kind: .income, amount: 50, date: now, account: card           // refund
        ))
        context.insert(LedgerTransaction(
            kind: .transfer, amount: 30, date: now,
            account: card, toAccount: bank                                // cash advance
        ))
        context.insert(LedgerTransaction(
            kind: .transfer, amount: 70, date: now,
            account: bank, toAccount: card                                // payment
        ))
        try context.save()

        #expect(card.creditCardEntries.map(\.delta).sorted() == [-100, -30, 50, 70])
    }

    // MARK: - Payment

    @Test func paymentIsATransferBetweenBothAccounts() throws {
        let context = try makeContext()
        let bank = Account(name: "Ngân hàng", kind: .bank, openingBalance: 10_000_000)
        let card = Account(name: "Thẻ Visa", kind: .creditCard, openingBalance: -1_000_000)
        context.insert(bank)
        context.insert(card)
        try context.save()

        let payment = CreditCardPayment.makeTransfer(
            card: card, from: bank, amount: 400_000, date: ymd(2026, 7, 3)
        )
        context.insert(payment)
        try context.save()

        #expect(payment.kind == .transfer)
        #expect(payment.note == "Trả nợ thẻ Thẻ Visa")
        #expect(payment.account === bank)
        #expect(payment.toAccount === card)
        #expect(bank.balance == 9_600_000)
        #expect(card.balance == -600_000)

        // The payment never shows up as expense (or income) in reports.
        let month = ReportDateInterval(start: ymd(2026, 7, 1), end: ymd(2026, 8, 1))
        let totals = ReportSummary.totals(entries: [
            ReportEntry(date: payment.date, kind: payment.kind, amount: payment.amount)
        ], in: month)
        #expect(totals.expense == 0)
        #expect(totals.income == 0)
        #expect(totals.count == 0)
    }

    @Test func eligiblePayersExcludesArchivedAndLiabilities() throws {
        let context = try makeContext()
        let cash = Account(name: "Tiền mặt", kind: .cash)
        let bank = Account(name: "Ngân hàng", kind: .bank)
        let wallet = Account(name: "Momo", kind: .eWallet)
        let archived = Account(name: "Cũ", kind: .bank, isArchived: true)
        let otherCard = Account(name: "Thẻ khác", kind: .creditCard)
        let loan = Account(name: "Vay", kind: .loan)
        let card = Account(name: "Thẻ Visa", kind: .creditCard)
        for account in [cash, bank, wallet, archived, otherCard, loan, card] {
            context.insert(account)
        }
        try context.save()

        let all = try context.fetch(FetchDescriptor<Account>())
        let payers = CreditCardPayment.eligiblePayers(all, paying: card)
        #expect(payers.map(\.name).sorted() == ["Momo", "Ngân hàng", "Tiền mặt"])
        #expect(payers.allSatisfy { !$0.isArchived && $0.kind.canPay })
    }

    /// A client receivable is not money the owner holds — it cannot pay a
    /// card bill even though it is not a liability.
    @Test func eligiblePayersExcludesReceivables() throws {
        let context = try makeContext()
        let bank = Account(name: "Ngân hàng", kind: .bank)
        let client = Account(name: "Khách A", kind: .receivable)
        let card = Account(name: "Thẻ Visa", kind: .creditCard)
        for account in [bank, client, card] { context.insert(account) }
        try context.save()

        let all = try context.fetch(FetchDescriptor<Account>())
        let payers = CreditCardPayment.eligiblePayers(all, paying: card)
        #expect(payers.map(\.id) == [bank.id])
        #expect(!AccountKind.receivable.canPay)
        #expect(AccountKind.cash.canPay && AccountKind.bank.canPay
                && AccountKind.eWallet.canPay)
        #expect(!AccountKind.creditCard.canPay && !AccountKind.loan.canPay)
    }

    @Test func paymentPlanPrefill() {
        let statementDue = CreditCardPaymentPlan(
            statementBalance: 1_500_000,
            statementDue: 1_100_000,
            minimumPayment: 55_000,
            totalDebt: 1_300_000
        )
        #expect(statementDue.prefill == 1_100_000)

        // No statement data — fall back to the whole debt.
        let noConfig = CreditCardPaymentPlan(totalDebt: 800_000)
        #expect(noConfig.prefill == 800_000)
        #expect(CreditCardPaymentPlan(totalDebt: 0).prefill == 0)
    }
}
