import Testing
import SwiftData
import Foundation
import FinanceCore
@testable import AMFinance

@MainActor
struct ReceivablesTests {

    private let calendar = AppCalendar.vietnam

    private func makeContext() throws -> ModelContext {
        ModelContext(try AppModelContainer.make(inMemory: true))
    }

    private func day(
        _ year: Int, _ month: Int, _ dayOfMonth: Int,
        _ hour: Int = 12
    ) -> Date {
        calendar.date(from: DateComponents(
            year: year, month: month, day: dayOfMonth, hour: hour
        ))!
    }

    private func fetchAll<T: PersistentModel>(_ type: T.Type, in context: ModelContext) throws -> [T] {
        try context.fetch(FetchDescriptor<T>())
    }

    // MARK: - Snapshot: FIFO aging

    @Test func snapshotOutstandingTotalsAndAging() {
        let snapshot = ReceivableSnapshot.make(
            advances: [
                ReceivableMovement(date: day(2026, 9, 1), amount: 10_000_000),
                ReceivableMovement(date: day(2026, 10, 15), amount: 5_000_000),
            ],
            settlements: [
                ReceivableMovement(date: day(2026, 11, 1), amount: 6_000_000),
            ]
        )
        #expect(snapshot.totalAdvanced == 15_000_000)
        #expect(snapshot.totalRepaid == 6_000_000)
        #expect(snapshot.outstanding == 9_000_000)
        #expect(!snapshot.isSettled)
        // 6M settled eats the Sep advance first; its remaining 4M is the
        // oldest still unpaid.
        #expect(snapshot.oldestUnpaidDate == day(2026, 9, 1))
    }

    @Test func snapshotPartialRepaymentsAgeOldestFirst() {
        // Advances out of order on purpose — the FIFO sort must fix it.
        let snapshot = ReceivableSnapshot.make(
            advances: [
                ReceivableMovement(date: day(2026, 11, 10), amount: 4_000_000),
                ReceivableMovement(date: day(2026, 9, 5), amount: 8_000_000),
            ],
            settlements: [
                ReceivableMovement(date: day(2026, 11, 20), amount: 8_000_000),
            ]
        )
        // The Sep advance is fully consumed; the Nov one is now oldest.
        #expect(snapshot.outstanding == 4_000_000)
        #expect(snapshot.oldestUnpaidDate == day(2026, 11, 10))
    }

    @Test func snapshotSettledHasNoOldestUnpaid() {
        let snapshot = ReceivableSnapshot.make(
            advances: [ReceivableMovement(date: day(2026, 9, 1), amount: 5_000_000)],
            settlements: [ReceivableMovement(date: day(2026, 9, 20), amount: 5_000_000)]
        )
        #expect(snapshot.isSettled)
        #expect(snapshot.outstanding == 0)
        #expect(snapshot.oldestUnpaidDate == nil)
    }

    /// A repayment larger than the outstanding amount is legitimate —
    /// the excess is prepaid credit ("khách ứng trước"), not a negative
    /// "đang nợ", and it can never look "quá 30 ngày".
    @Test func snapshotOverpaymentBecomesPrepaidCredit() {
        let snapshot = ReceivableSnapshot.make(
            advances: [
                ReceivableMovement(date: day(2026, 9, 1), amount: 5_000_000),
            ],
            settlements: [
                ReceivableMovement(date: day(2026, 11, 1), amount: 7_000_000),
            ]
        )
        #expect(snapshot.outstanding == 0)
        #expect(snapshot.prepaid == 2_000_000)
        #expect(snapshot.hasPrepaid)
        #expect(snapshot.isSettled)
        #expect(snapshot.oldestUnpaidDate == nil)
        #expect(!snapshot.isOverdue(now: day(2026, 11, 22), calendar: calendar))
    }

    /// Credit consumes later advances too: 7M settled against a 5M
    /// advance 50 days ago leaves 2M prepaid; a new 4M advance is eaten by
    /// that credit first, so only 2M remains — aged from the new advance,
    /// not the old one.
    @Test func snapshotPrepaidCreditConsumesLaterAdvances() {
        let snapshot = ReceivableSnapshot.make(
            advances: [
                ReceivableMovement(date: day(2026, 10, 1), amount: 5_000_000),
                ReceivableMovement(date: day(2026, 11, 20), amount: 4_000_000),
            ],
            settlements: [
                ReceivableMovement(date: day(2026, 11, 10), amount: 7_000_000),
            ]
        )
        #expect(snapshot.outstanding == 2_000_000)
        #expect(snapshot.prepaid == 0)
        #expect(snapshot.oldestUnpaidDate == day(2026, 11, 20))
        #expect(snapshot.oldestUnpaidAgeDays(now: day(2026, 11, 22), calendar: calendar) == 2)
        #expect(!snapshot.isOverdue(now: day(2026, 11, 22), calendar: calendar))
    }

    /// A client created with a negative opening balance starts in credit.
    @Test func snapshotMapsNegativeOpeningBalanceToPrepaid() throws {
        let context = try makeContext()
        let client = Account(
            name: "Khách", kind: .receivable, openingBalance: -3_000_000)
        client.createdAt = day(2026, 10, 1)
        context.insert(client)
        try context.save()

        let snapshot = ReceivableSnapshot.make(account: client)
        #expect(snapshot.outstanding == 0)
        #expect(snapshot.prepaid == 3_000_000)
        #expect(snapshot.prepaid == -client.balance)
    }

    /// An overpayment on a live account: the ledger balance goes negative
    /// and the snapshot reports prepaid credit equal to -balance.
    @Test func repaymentBeyondOutstandingBecomesPrepaid() throws {
        let context = try makeContext()
        let cash = Account(name: "Tiền mặt", kind: .cash)
        let client = Account(name: "Khách A", kind: .receivable)
        context.insert(cash)
        context.insert(client)
        context.insert(ReceivableActions.advance(
            receivable: client, from: cash,
            amount: 5_000_000, date: day(2026, 9, 1), note: ""))
        try context.save()

        context.insert(ReceivableActions.repayment(
            receivable: client, to: cash,
            amount: 7_000_000, date: day(2026, 11, 1), note: ""))
        try context.save()

        #expect(client.balance == -2_000_000)
        let snapshot = ReceivableSnapshot.make(account: client)
        #expect(snapshot.outstanding == 0)
        #expect(snapshot.prepaid == 2_000_000)
        #expect(snapshot.isSettled)
        #expect(!snapshot.isOverdue(now: day(2026, 11, 22), calendar: calendar))

        // The next advance consumes the credit before creating new debt.
        context.insert(ReceivableActions.advance(
            receivable: client, from: cash,
            amount: 1_500_000, date: day(2026, 11, 21), note: ""))
        try context.save()
        let after = ReceivableSnapshot.make(account: client)
        #expect(after.outstanding == 0)
        #expect(after.prepaid == 500_000)
    }

    @Test func snapshotAgeAndOverdueThreshold() {
        let snapshot = ReceivableSnapshot.make(
            advances: [ReceivableMovement(date: day(2026, 10, 1), amount: 3_000_000)],
            settlements: []
        )
        let now = day(2026, 11, 22)
        #expect(snapshot.oldestUnpaidAgeDays(now: now, calendar: calendar) == 52)
        #expect(snapshot.isOverdue(now: now, calendar: calendar))

        let recent = day(2026, 10, 25)
        #expect(snapshot.oldestUnpaidAgeDays(now: recent, calendar: calendar) == 24)
        #expect(!snapshot.isOverdue(now: recent, calendar: calendar))
        // Exactly 30 days is not "quá 30 ngày" yet.
        #expect(!snapshot.isOverdue(now: day(2026, 10, 31), calendar: calendar))
        #expect(snapshot.isOverdue(now: day(2026, 11, 1), calendar: calendar))
    }

    // MARK: - Snapshot from a live account

    @Test func snapshotMapsAccountMovements() throws {
        let context = try makeContext()
        let cash = Account(name: "Tiền mặt", kind: .cash)
        let client = Account(name: "Khách", kind: .receivable)
        client.createdAt = day(2026, 8, 1)
        context.insert(cash)
        context.insert(client)
        // Opening debt counts as an advance dated at the account's creation.
        client.openingBalance = 1_000_000
        context.insert(LedgerTransaction(
            kind: .transfer, amount: 4_000_000, date: day(2026, 9, 10),
            account: cash, toAccount: client))
        context.insert(LedgerTransaction(
            kind: .transfer, amount: 2_000_000, date: day(2026, 10, 1),
            account: client, toAccount: cash))
        context.insert(LedgerTransaction(
            kind: .expense, amount: 500_000, date: day(2026, 10, 5),
            account: client))
        try context.save()

        let snapshot = ReceivableSnapshot.make(account: client)
        #expect(snapshot.totalAdvanced == 5_000_000)
        #expect(snapshot.totalRepaid == 2_500_000)
        #expect(snapshot.outstanding == client.balance)
        #expect(snapshot.outstanding == 2_500_000)
        // FIFO consumes the opening advance (Aug) before the Sep transfer.
        #expect(snapshot.oldestUnpaidDate == day(2026, 9, 10))
    }

    // MARK: - Advance

    @Test func advanceByCreditCardRaisesCardDebtAndReceivableEqually() throws {
        let context = try makeContext()
        let card = Account(name: "Thẻ Visa", kind: .creditCard, openingBalance: -1_000_000)
        let client = Account(name: "Khách A", kind: .receivable)
        context.insert(card)
        context.insert(client)
        try context.save()

        let accounts = try fetchAll(Account.self, in: context)
        let netWorthBefore = NetWorth.total(accounts)

        context.insert(ReceivableActions.advance(
            receivable: client, from: card,
            amount: 6_000_000, date: day(2026, 11, 5), note: "Ứng chạy ads"))
        try context.save()

        // Card debt and the receivable grow by the same amount.
        #expect(card.balance == -7_000_000)
        #expect(client.balance == 6_000_000)
        // Net worth, income and expense are untouched — it is a transfer.
        #expect(NetWorth.total(accounts) == netWorthBefore)
        let transactions = try fetchAll(LedgerTransaction.self, in: context)
        #expect(transactions.count == 1)
        #expect(transactions.allSatisfy { $0.kind == .transfer })
        #expect(transactions.first?.business == nil)
    }

    // MARK: - Repayment

    @Test func repaymentClearsTheReceivable() throws {
        let context = try makeContext()
        let cash = Account(name: "Tiền mặt", kind: .cash, openingBalance: 50_000_000)
        let client = Account(name: "Khách A", kind: .receivable)
        context.insert(cash)
        context.insert(client)
        context.insert(ReceivableActions.advance(
            receivable: client, from: cash,
            amount: 6_000_000, date: day(2026, 10, 5), note: ""))
        try context.save()

        context.insert(ReceivableActions.repayment(
            receivable: client, to: cash,
            amount: 6_000_000, date: day(2026, 11, 5), note: ""))
        try context.save()

        #expect(client.balance == 0)
        #expect(cash.balance == 50_000_000)
        let snapshot = ReceivableSnapshot.make(account: client)
        #expect(snapshot.isSettled)
        #expect(snapshot.oldestUnpaidDate == nil)
    }

    @Test func partialRepaymentsSettleOldestAdvancesFirst() throws {
        let context = try makeContext()
        let cash = Account(name: "Tiền mặt", kind: .cash)
        let client = Account(name: "Khách A", kind: .receivable)
        context.insert(cash)
        context.insert(client)
        context.insert(ReceivableActions.advance(
            receivable: client, from: cash,
            amount: 5_000_000, date: day(2026, 9, 1), note: ""))
        context.insert(ReceivableActions.advance(
            receivable: client, from: cash,
            amount: 5_000_000, date: day(2026, 11, 1), note: ""))
        context.insert(ReceivableActions.repayment(
            receivable: client, to: cash,
            amount: 7_000_000, date: day(2026, 11, 20), note: ""))
        try context.save()

        let snapshot = ReceivableSnapshot.make(account: client)
        #expect(snapshot.outstanding == 3_000_000)
        // 7M repaid clears the Sep advance (5M) and 2M of the Nov one —
        // what remains is aged from November, not September.
        #expect(snapshot.oldestUnpaidDate == day(2026, 11, 1))
        #expect(snapshot.oldestUnpaidAgeDays(now: day(2026, 11, 22), calendar: calendar) == 21)
        #expect(!snapshot.isOverdue(now: day(2026, 11, 22), calendar: calendar))
    }

    // MARK: - Write-off

    @Test func writeOffIsABusinessExpenseAndShrinksTheReceivable() throws {
        let context = try makeContext()
        let business = Business(name: "Chạy quảng cáo thuê")
        let other = Business(name: "Làm web")
        let client = Account(name: "Khách A", kind: .receivable)
        client.business = business
        let cash = Account(name: "Tiền mặt", kind: .cash)
        context.insert(business)
        context.insert(other)
        context.insert(client)
        context.insert(cash)
        context.insert(ReceivableActions.advance(
            receivable: client, from: cash,
            amount: 4_000_000, date: day(2026, 9, 1), note: ""))
        try context.save()

        let writeOffCategory = LedgerCategory(name: "Chi khác", kind: .expense)
        context.insert(writeOffCategory)
        context.insert(ReceivableActions.writeOff(
            receivable: client, amount: 2_500_000,
            date: day(2026, 11, 10), note: "Khách bỏ trốn",
            category: writeOffCategory))
        try context.save()

        #expect(client.balance == 1_500_000)

        // The write-off is an expense carrying the client's business — it
        // shows up as a business cost, never touching other businesses or
        // the personal totals.
        let interval = ReportDateInterval(start: day(2026, 1, 1), end: day(2027, 1, 1))
        let entries = try fetchAll(LedgerTransaction.self, in: context).map {
            ReportEntry(
                date: $0.date, kind: $0.kind, amount: $0.amount,
                categoryID: $0.category?.id, businessID: $0.business?.id)
        }
        let scoped = ReportSummary.totals(
            entries: entries, in: interval, scope: .business(business.id))
        #expect(scoped.expense == 2_500_000)
        #expect(scoped.income == 0)
        let otherScope = ReportSummary.totals(
            entries: entries, in: interval, scope: .business(other.id))
        #expect(otherScope.expense == 0)
        let personal = ReportSummary.totals(
            entries: entries, in: interval, scope: .personal)
        #expect(personal.expense == 0)
    }

    // MARK: - Service fee

    @Test func serviceFeeIsBusinessIncomeOnTheReceiver() throws {
        let context = try makeContext()
        let business = Business(name: "Chạy quảng cáo thuê")
        let client = Account(name: "Khách A", kind: .receivable)
        client.business = business
        let bank = Account(name: "Ngân hàng", kind: .bank)
        context.insert(business)
        context.insert(client)
        context.insert(bank)
        let feeCategory = LedgerCategory(name: "Doanh thu dịch vụ", kind: .income)
        context.insert(feeCategory)
        try context.save()

        context.insert(ReceivableActions.serviceFee(
            receivable: client, to: bank,
            amount: 3_000_000, date: day(2026, 11, 15), note: "Phí tháng 11",
            category: ReceivableActions.category(
                named: ReceivableActions.serviceFeeCategoryName,
                kind: .income,
                in: try fetchAll(LedgerCategory.self, in: context))))
        try context.save()

        // The fee lands on the receiver, not on the receivable.
        #expect(bank.balance == 3_000_000)
        #expect(client.balance == 0)
        let transaction = try #require(
            try fetchAll(LedgerTransaction.self, in: context).first)
        #expect(transaction.kind == .income)
        #expect(transaction.business?.id == business.id)
        #expect(transaction.category?.name == "Doanh thu dịch vụ")

        let interval = ReportDateInterval(start: day(2026, 1, 1), end: day(2027, 1, 1))
        let totals = ReportSummary.totals(
            entries: [ReportEntry(
                date: transaction.date, kind: transaction.kind,
                amount: transaction.amount, businessID: transaction.business?.id)],
            in: interval, scope: .anyBusiness)
        #expect(totals.income == 3_000_000)
        #expect(totals.expense == 0)
    }

    // MARK: - Category lookup and eligibility

    @Test func categoryLookupMatchesNameAndKind() throws {
        let context = try makeContext()
        try SeedData.seedIfNeeded(context: context)
        let categories = try fetchAll(LedgerCategory.self, in: context)

        let fee = ReceivableActions.category(
            named: ReceivableActions.serviceFeeCategoryName,
            kind: .income, in: categories)
        #expect(fee?.name == "Doanh thu dịch vụ")
        let writeOff = ReceivableActions.category(
            named: ReceivableActions.writeOffCategoryName,
            kind: .expense, in: categories)
        #expect(writeOff?.name == "Chi khác")
        // Same name, wrong kind, or missing name — all nil.
        #expect(ReceivableActions.category(
            named: "Doanh thu dịch vụ", kind: .expense, in: categories) == nil)
        #expect(ReceivableActions.category(
            named: "Không tồn tại", kind: .income, in: categories) == nil)
    }

    @Test func payerAndReceiverEligibility() {
        let cash = Account(name: "Tiền mặt", kind: .cash)
        let bank = Account(name: "Ngân hàng", kind: .bank)
        let wallet = Account(name: "Momo", kind: .eWallet)
        let card = Account(name: "Thẻ", kind: .creditCard)
        let loan = Account(name: "Vay", kind: .loan)
        let client = Account(name: "Khách", kind: .receivable)
        let otherClient = Account(name: "Khách B", kind: .receivable)
        let archived = Account(name: "Cũ", kind: .bank, isArchived: true)
        let all = [cash, bank, wallet, card, loan, client, otherClient, archived]

        let payers = ReceivableActions.advancePayers(all, for: client)
        #expect(Set(payers.map(\.id)) == Set([cash, bank, wallet, card].map(\.id)))

        let receivers = ReceivableActions.receivers(all, for: client)
        #expect(Set(receivers.map(\.id)) == Set([cash, bank, wallet].map(\.id)))
    }

    // MARK: - Client draft

    @Test func clientDraftRequiresNameAndBuildsReceivable() {
        var draft = ReceivableClientDraft()
        draft.name = "   "
        #expect(draft.validate() == .missingName)

        draft.name = "  Khách A  "
        draft.note = "ghi chú"
        let business = Business(name: "Chạy quảng cáo thuê")
        draft.business = business
        #expect(draft.validate() == nil)

        let account = draft.makeAccount(sortOrder: 7)
        #expect(account.name == "Khách A")
        #expect(account.kind == .receivable)
        #expect(account.note == "ghi chú")
        #expect(account.sortOrder == 7)
        #expect(account.business === business)
        #expect(account.icon == AccountKind.receivable.defaultSymbol)
    }
}
