import Testing
import Foundation
import SwiftData
import FinanceCore
@testable import AMFinance

@MainActor
struct DebtsTests {

    private let calendar = AppCalendar.vietnam

    private func makeContext() throws -> ModelContext {
        ModelContext(try AppModelContainer.make(inMemory: true))
    }

    /// A moment in Asia/Ho_Chi_Minh.
    private func day(
        _ year: Int, _ month: Int, _ day: Int, _ hour: Int = 12
    ) -> Date {
        calendar.date(from: DateComponents(
            year: year, month: month, day: day, hour: hour
        ))!
    }

    // MARK: - DebtsTotals

    @Test func totalsSplitCardsAndLoans() {
        let totals = DebtsTotals.make(accounts: [
            .init(kind: .creditCard, balance: -3_000_000),
            .init(kind: .creditCard, balance: -1_000_000),
            .init(kind: .loan, balance: -50_000_000),
            .init(kind: .loan, balance: -80_000_000),
        ])
        #expect(totals.cardDebt == 4_000_000)
        #expect(totals.loanDebt == 130_000_000)
        #expect(totals.total == 134_000_000)
    }

    @Test func totalsSkipArchivedAndClampPositiveBalances() {
        let totals = DebtsTotals.make(accounts: [
            // A card in credit owes nothing.
            .init(kind: .creditCard, balance: 500_000),
            .init(kind: .creditCard, balance: -2_000_000),
            // Archived debt is invisible.
            .init(kind: .loan, balance: -99_000_000, isArchived: true),
            // Non-liability kinds never count.
            .init(kind: .bank, balance: -10_000_000),
            .init(kind: .cash, balance: 5_000_000),
        ])
        #expect(totals.cardDebt == 2_000_000)
        #expect(totals.loanDebt == 0)
        #expect(totals.total == 2_000_000)
    }

    // MARK: - Ordering across cards and loans

    @Test func upcomingSortsByDueDateAcrossKinds() {
        let cardA = UUID(), loan = UUID(), cardB = UUID()
        let items = DebtsUpcoming.build(
            cards: [
                .init(accountID: cardA, amountDue: 100, dueDate: day(2026, 11, 25)),
                .init(accountID: cardB, amountDue: 200, dueDate: day(2026, 11, 18)),
            ],
            loans: [
                .init(accountID: loan, installmentTotal: 300, dueDate: day(2026, 11, 20)),
            ],
            now: day(2026, 11, 15),
            calendar: calendar
        )

        #expect(items.map(\.accountID) == [cardB, loan, cardA])
        #expect(items.map(\.kind) == [.creditCard, .loan, .creditCard])
        #expect(items.map(\.amount) == [200, 300, 100])
        #expect(items.map(\.daysUntilDue) == [3, 5, 10])
        #expect(items[0].statusText == "Còn 3 ngày")
        #expect(items[0].dueDateText == "18/11/2026")
        #expect(items[1].kind.title == "Khoản vay")
        #expect(items[0].kind.title == "Thẻ tín dụng")
    }

    // MARK: - Skips

    @Test func upcomingSkipsPaidInFullCardAndEmptyLoan() {
        let paidCard = UUID(), dueCard = UUID(), zeroLoan = UUID()
        let items = DebtsUpcoming.build(
            cards: [
                .init(accountID: paidCard, amountDue: 0, dueDate: day(2026, 11, 19)),
                .init(accountID: dueCard, amountDue: 500_000, dueDate: day(2026, 11, 20)),
            ],
            loans: [
                .init(accountID: zeroLoan, installmentTotal: 0, dueDate: day(2026, 11, 10)),
            ],
            now: day(2026, 11, 15),
            calendar: calendar
        )
        #expect(items.map(\.accountID) == [dueCard])
    }

    @Test func upcomingSkipsArchivedAccounts() {
        let live = UUID(), archivedCard = UUID(), archivedLoan = UUID()
        let items = DebtsUpcoming.build(
            cards: [
                .init(accountID: live, amountDue: 1, dueDate: day(2026, 11, 20)),
                .init(accountID: archivedCard, amountDue: 1, dueDate: day(2026, 11, 10),
                      isArchived: true),
            ],
            loans: [
                .init(accountID: archivedLoan, installmentTotal: 1,
                      dueDate: day(2026, 11, 10), isArchived: true),
            ],
            now: day(2026, 11, 15),
            calendar: calendar
        )
        #expect(items.map(\.accountID) == [live])
    }

    // MARK: - Labels

    @Test func upcomingLabelsOverdueTodayAndFuture() {
        let overdue = UUID(), today = UUID(), future = UUID()
        // `now` late in the day — the countdown is day-granular.
        let items = DebtsUpcoming.build(
            cards: [
                .init(accountID: overdue, amountDue: 1, dueDate: day(2026, 11, 12)),
                .init(accountID: today, amountDue: 1, dueDate: day(2026, 11, 15)),
                .init(accountID: future, amountDue: 1, dueDate: day(2026, 11, 16)),
            ],
            loans: [],
            now: day(2026, 11, 15, 23),
            calendar: calendar
        )
        #expect(items.map(\.statusText) == ["Quá hạn 3 ngày", "Hôm nay", "Còn 1 ngày"])
        #expect(items.map(\.isOverdue) == [true, false, false])
        #expect(items.map(\.daysUntilDue) == [-3, 0, 1])
    }

    // MARK: - 14-day window (dashboard card)

    @Test func windowKeepsOverdueAndDropsFarFuture() {
        let overdue = UUID(), near = UUID(), edge = UUID(), far = UUID()
        let items = DebtsUpcoming.build(
            cards: [
                .init(accountID: near, amountDue: 1, dueDate: day(2026, 11, 20)),
                .init(accountID: edge, amountDue: 1, dueDate: day(2026, 11, 29)),
                .init(accountID: far, amountDue: 1, dueDate: day(2026, 11, 30)),
            ],
            loans: [
                .init(accountID: overdue, installmentTotal: 1, dueDate: day(2026, 11, 1)),
            ],
            now: day(2026, 11, 15),
            calendar: calendar,
            withinDays: 14
        )
        // Overdue stays (it is still due), day 14 stays, day 15 is out.
        #expect(Set(items.map(\.accountID)) == [overdue, near, edge])
        #expect(!items.contains { $0.accountID == far })
    }

    // MARK: - Mapper over real models

    /// A card with a statement due and a loan with a pending installment
    /// produce one upcoming item each, ordered by due date; a card paid in
    /// full contributes nothing.
    @Test func mapperBuildsItemsFromModels() throws {
        let context = try makeContext()

        let card = Account(name: "Thẻ Visa", kind: .creditCard)
        card.creditLimit = 30_000_000
        card.statementDay = 20
        card.graceDays = 15
        let paidCard = Account(name: "Thẻ trả hết", kind: .creditCard)
        paidCard.statementDay = 20
        paidCard.graceDays = 15
        context.insert(card)
        context.insert(paidCard)

        let now = day(2026, 7, 1)
        // Spending inside the May 21 – Jun 20 cycle (due 05/07).
        context.insert(LedgerTransaction(
            kind: .expense, amount: 1_000_000,
            date: day(2026, 6, 10), account: card
        ))
        // Paid card: same cycle, fully covered by a payment after closing.
        context.insert(LedgerTransaction(
            kind: .expense, amount: 800_000,
            date: day(2026, 6, 10), account: paidCard
        ))
        context.insert(LedgerTransaction(
            kind: .income, amount: 800_000,
            date: day(2026, 6, 25), account: paidCard
        ))

        // Loan: 120tr over 12 months, disbursed 15/01/2025, due on the 20th —
        // first installment is long overdue by `now`.
        let loan = Account(name: "Vay nhà", kind: .loan, openingBalance: -120_000_000)
        loan.loanPrincipal = 120_000_000
        loan.loanAnnualRatePercent = 12
        loan.loanTermMonths = 12
        loan.loanStartDate = day(2025, 1, 15)
        loan.loanPaymentDay = 20
        loan.loanMethodRaw = LoanMethod.equalPrincipal.rawValue
        context.insert(loan)
        try context.save()

        let store = LoanInterestBasisStore(
            defaults: UserDefaults(suiteName: "DebtsTests.\(UUID().uuidString)")!
        )
        let items = DebtsUpcomingMapper.items(
            for: [card, paidCard, loan],
            basisStore: store,
            now: now,
            calendar: calendar
        )

        #expect(items.count == 2)
        // The overdue loan installment comes before the card due date.
        #expect(items.map(\.kind) == [.loan, .creditCard])
        #expect(items.map(\.accountID) == [loan.id, card.id])

        let cardItem = try #require(items.first { $0.kind == .creditCard })
        #expect(cardItem.amount == 1_000_000)
        #expect(cardItem.dueDate == day(2026, 7, 5, 0))
        #expect(cardItem.statusText == "Còn 4 ngày")

        let loanItem = try #require(items.first { $0.kind == .loan })
        let plan = try #require(LoanPlan(account: loan, basis: .actual365, calendar: calendar))
        let next = try #require(plan.nextInstallment)
        #expect(loanItem.amount == next.total)
        #expect(loanItem.dueDate == next.dueDate)
        #expect(loanItem.isOverdue)
    }

    /// Cards without a cycle config and loans without complete fields are
    /// invisible to the upcoming list.
    @Test func mapperSkipsUnconfiguredAccounts() throws {
        let context = try makeContext()
        let plainCard = Account(name: "Thẻ", kind: .creditCard, openingBalance: -2_000_000)
        let bareLoan = Account(name: "Vay", kind: .loan, openingBalance: -5_000_000)
        let bank = Account(name: "Ngân hàng", kind: .bank, openingBalance: 10_000_000)
        for account in [plainCard, bareLoan, bank] { context.insert(account) }
        try context.save()

        let items = DebtsUpcomingMapper.items(
            for: [plainCard, bareLoan, bank],
            now: day(2026, 7, 1),
            calendar: calendar
        )
        #expect(items.isEmpty)
    }
}
