import Testing
import Foundation
import SwiftData
import FinanceCore
@testable import AMFinance

@MainActor
struct BalanceTrendTests {

    private let calendar = AppCalendar.vietnam

    private func makeContext() throws -> ModelContext {
        ModelContext(try AppModelContainer.make(inMemory: true))
    }

    /// Start-of-day (or a given hour) in the app calendar.
    private func ymd(_ year: Int, _ month: Int, _ day: Int, hour: Int = 0) -> Date {
        calendar.date(from: DateComponents(year: year, month: month, day: day, hour: hour))!
    }

    private func series(
        openingBalance: Int64 = 0,
        entries: [BalanceHistoryEntry],
        range: BalanceTrendRange,
        isLiability: Bool = false,
        now: Date
    ) throws -> BalanceTrendSeries {
        try BalanceTrendSeries.build(
            entries: entries,
            openingBalance: openingBalance,
            range: range,
            now: now,
            isLiability: isLiability,
            calendar: calendar
        )
    }

    // MARK: - Ranges

    @Test func rangesCoverExpectedSpans() throws {
        let now = ymd(2026, 11, 22, hour: 15)
        let entries = [BalanceHistoryEntry(date: ymd(2026, 10, 10, hour: 9), delta: 1_000)]

        let thirty = try series(entries: entries, range: .days30, now: now)
        #expect(thirty.start == ymd(2026, 10, 23))
        #expect(thirty.dailyPoints.count == 31)
        #expect(thirty.dailyPoints.last?.date == ymd(2026, 11, 22))

        let ninety = try series(entries: entries, range: .days90, now: now)
        #expect(ninety.start == ymd(2026, 8, 24))
        #expect(ninety.dailyPoints.count == 91)

        let year = try series(entries: entries, range: .year, now: now)
        #expect(year.start == ymd(2025, 11, 22))
        #expect(year.dailyPoints.count == 366)

        // "Tất cả" starts at the earliest entry, not at a fixed look-back.
        let all = try series(entries: entries, range: .all, now: now)
        #expect(all.start == ymd(2026, 10, 10))
        #expect(all.dailyPoints.count == 44)
    }

    @Test func allRangeWithNoEntriesIsOneDayAtOpening() throws {
        let now = ymd(2026, 11, 22, hour: 15)
        let all = try series(
            openingBalance: 2_500_000, entries: [], range: .all, now: now
        )
        #expect(all.dailyPoints == [BalanceHistoryPoint(date: ymd(2026, 11, 22), balance: 2_500_000)])
        #expect(all.opening == 2_500_000)
        #expect(all.closing == 2_500_000)
        #expect(all.totalIn == 0 && all.totalOut == 0 && all.netChange == 0)
    }

    @Test func daysWithoutEntriesCarryClosingForward() throws {
        let now = ymd(2026, 11, 22, hour: 15)
        let entries = [
            BalanceHistoryEntry(date: ymd(2026, 11, 18, hour: 8), delta: 100_000),
            BalanceHistoryEntry(date: ymd(2026, 11, 22, hour: 9), delta: -30_000),
        ]
        let all = try series(entries: entries, range: .all, now: now)
        #expect(all.dailyPoints.map(\.balance) == [100_000, 100_000, 100_000, 100_000, 70_000])
    }

    // MARK: - Liability sign flip

    @Test func liabilityPlotsDebtAsPositive() throws {
        let now = ymd(2026, 11, 22, hour: 15)
        let entries = [
            BalanceHistoryEntry(date: ymd(2026, 11, 20, hour: 10), delta: -500_000), // chi thẻ
            BalanceHistoryEntry(date: ymd(2026, 11, 21, hour: 10), delta: 200_000),  // trả thẻ
        ]
        let card = try series(
            openingBalance: -1_000_000, entries: entries,
            range: .all, isLiability: true, now: now
        )
        // Signed balances are -1.5M, -1.3M, -1.3M — displayed as positive debt.
        #expect(card.dailyPoints.map(\.balance) == [1_500_000, 1_300_000, 1_300_000])
        #expect(card.opening == 1_000_000)
        #expect(card.closing == 1_300_000)
        // Largest debt (lowest signed balance, right after the purchase)
        // wins "cao nhất"; the smallest debt is the opening carried into the
        // range ("thấp nhất" at the range's first day).
        #expect(card.highest == BalanceHistoryPoint(date: ymd(2026, 11, 20, hour: 10), balance: 1_500_000))
        #expect(card.lowest == BalanceHistoryPoint(date: ymd(2026, 11, 20), balance: 1_000_000))
    }

    // MARK: - Summary

    @Test func summaryCoversOpeningFlowsAndExtremes() throws {
        let now = ymd(2026, 11, 22, hour: 15)
        let entries = [
            BalanceHistoryEntry(date: ymd(2026, 10, 1, hour: 10), delta: 1_000_000),  // before range
            BalanceHistoryEntry(date: ymd(2026, 11, 20, hour: 9), delta: 500_000),
            BalanceHistoryEntry(date: ymd(2026, 11, 21, hour: 9), delta: -200_000),
        ]
        let s = try series(entries: entries, range: .days30, now: now)

        #expect(s.opening == 1_000_000)   // close of the day before the range
        #expect(s.totalIn == 500_000)
        #expect(s.totalOut == 200_000)
        #expect(s.netChange == 300_000)
        #expect(s.closing == 1_300_000)
        #expect(s.highest == BalanceHistoryPoint(date: ymd(2026, 11, 20, hour: 9), balance: 1_500_000))
        #expect(s.lowest == BalanceHistoryPoint(date: s.start, balance: 1_000_000))
    }

    // MARK: - Downsample

    @Test func chartPointsAreCappedAt120() throws {
        let now = ymd(2026, 11, 22, hour: 15)
        // One entry per day for 150 days → 150 daily points.
        let entries = (0..<150).map { offset in
            BalanceHistoryEntry(
                date: ymd(2026, 6, 25, hour: 12).addingTimeInterval(TimeInterval(offset * 86_400)),
                delta: Int64(offset + 1) * 1_000
            )
        }
        let all = try series(entries: entries, range: .all, now: now)

        // 150 entry days + today (no entry) = 151 daily points.
        #expect(all.dailyPoints.count == 151)
        #expect(all.chartPoints.count == BalanceTrendSeries.maxChartPoints)
        // First and last days survive the thinning.
        #expect(all.chartPoints.first == all.dailyPoints.first)
        #expect(all.chartPoints.last == all.dailyPoints.last)
        #expect(all.chartPoints.count <= 120)
    }

    // MARK: - Entries from the ledger

    @Test func entriesComeFromSourceRoleAndTransferDestination() throws {
        let context = try makeContext()
        let a = Account(name: "A", kind: .bank)
        let b = Account(name: "B", kind: .cash)
        context.insert(a)
        context.insert(b)

        let expenseDate = ymd(2026, 11, 20, hour: 10)
        context.insert(LedgerTransaction(
            kind: .expense, amount: 100_000, date: expenseDate, account: a
        ))
        let transferDate = ymd(2026, 11, 21, hour: 10)
        context.insert(LedgerTransaction(
            kind: .transfer, amount: 50_000, date: transferDate, account: a, toAccount: b
        ))
        try context.save()

        let aEntries = a.balanceTrendEntries
        #expect(aEntries == [
            BalanceHistoryEntry(date: expenseDate, delta: -100_000),
            BalanceHistoryEntry(date: transferDate, delta: -50_000),
        ])
        // B only sees the transfer destination side: +50.000.
        #expect(b.balanceTrendEntries == [
            BalanceHistoryEntry(date: transferDate, delta: 50_000),
        ])
    }

    // MARK: - Anchor math

    @Test func signedTargetNegatesTypedDebtForLiabilities() {
        #expect(BalanceTrendAnchor.signedTarget(typed: 2_000_000, isLiability: true) == -2_000_000)
        #expect(BalanceTrendAnchor.signedTarget(typed: 2_000_000, isLiability: false) == 2_000_000)
        #expect(BalanceTrendAnchor.signedTarget(typed: -50, isLiability: true) == 0)
    }

    @Test func openingBalanceModeForAsset() {
        // computed = 1.3M (opening 1M + entries), real balance is 2M →
        // shift the opening up by the 700k gap.
        let newOpening = BalanceTrendAnchor.newOpeningBalance(
            opening: 1_000_000, computed: 1_300_000, target: 2_000_000
        )
        #expect(newOpening == 1_700_000)
    }

    @Test func openingBalanceModeForLiability() {
        // Card shows debt 5.5M (balance -5.5M, opening -5M), real debt is 4M
        // → target -4M; the opening shifts +1.5M to -3.5M.
        let newOpening = BalanceTrendAnchor.newOpeningBalance(
            opening: -5_000_000, computed: -5_500_000, target: -4_000_000
        )
        #expect(newOpening == -3_500_000)
    }

    @Test func transactionModeForAssetAndLiability() {
        // Asset: app shows 1M, real is 1.5M → income 500k; real is 700k →
        // expense 300k.
        #expect(BalanceTrendAnchor.adjustment(computed: 1_000_000, target: 1_500_000)?.kind == .income)
        #expect(BalanceTrendAnchor.adjustment(computed: 1_000_000, target: 1_500_000)?.amount == 500_000)
        #expect(BalanceTrendAnchor.adjustment(computed: 1_000_000, target: 700_000)?.kind == .expense)
        #expect(BalanceTrendAnchor.adjustment(computed: 1_000_000, target: 700_000)?.amount == 300_000)
        // Liability: app debt 5M, real debt 4M → income 1M pushes the balance
        // back towards zero.
        let adj = BalanceTrendAnchor.adjustment(computed: -5_000_000, target: -4_000_000)
        #expect(adj?.kind == .income)
        #expect(adj?.amount == 1_000_000)
    }

    @Test func zeroDifferenceIsNoOp() {
        #expect(BalanceTrendAnchor.adjustment(computed: 1_000_000, target: 1_000_000) == nil)
        #expect(BalanceTrendAnchor.newOpeningBalance(
            opening: 500_000, computed: 1_000_000, target: 1_000_000
        ) == nil)
        #expect(BalanceTrendAnchor.displayedDifference(
            computed: 1_000_000, target: 1_000_000, isLiability: false
        ) == 0)
    }

    @Test func displayedDifferenceFlipsForLiabilities() {
        // Asset: typed 1.5M vs computed 1M → +500k.
        #expect(BalanceTrendAnchor.displayedDifference(
            computed: 1_000_000, target: 1_500_000, isLiability: false
        ) == 500_000)
        // Card debt 5M, typed debt 4M → displayed difference -1M.
        #expect(BalanceTrendAnchor.displayedDifference(
            computed: -5_000_000, target: -4_000_000, isLiability: true
        ) == -1_000_000)
    }

    // MARK: - End to end

    @Test func openingBalanceModeLandsOnTarget() throws {
        let context = try makeContext()
        let account = Account(name: "Ngân hàng", kind: .bank, openingBalance: 1_000_000)
        context.insert(account)
        context.insert(LedgerTransaction(kind: .expense, amount: 300_000, account: account))
        try context.save()
        #expect(account.balance == 700_000)

        let target = BalanceTrendAnchor.signedTarget(typed: 2_000_000, isLiability: false)
        let newOpening = try #require(BalanceTrendAnchor.newOpeningBalance(
            opening: account.openingBalance, computed: account.balance, target: target
        ))
        account.openingBalance = newOpening
        try context.save()
        #expect(account.balance == 2_000_000)
    }

    @Test func openingBalanceModeLandsOnTargetForLiability() throws {
        let context = try makeContext()
        let card = Account(name: "Thẻ", kind: .creditCard, openingBalance: -5_000_000)
        context.insert(card)
        context.insert(LedgerTransaction(kind: .expense, amount: 500_000, account: card))
        try context.save()
        #expect(card.balance == -5_500_000)

        // Typed real debt 4M → after the shift the balance must read -4M.
        let target = BalanceTrendAnchor.signedTarget(typed: 4_000_000, isLiability: true)
        let newOpening = try #require(BalanceTrendAnchor.newOpeningBalance(
            opening: card.openingBalance, computed: card.balance, target: target
        ))
        card.openingBalance = newOpening
        try context.save()
        #expect(card.balance == -4_000_000)
        #expect(BalanceTrendSeries.displayed(card.balance, isLiability: true) == 4_000_000)
    }

    @Test func transactionModeLandsOnTarget() throws {
        let context = try makeContext()
        let account = Account(name: "Tiền mặt", kind: .cash, openingBalance: 1_000_000)
        context.insert(account)
        context.insert(LedgerTransaction(kind: .expense, amount: 300_000, account: account))
        try context.save()

        let adjustment = try #require(BalanceTrendAnchor.adjustment(
            computed: account.balance, target: 2_000_000
        ))
        context.insert(LedgerTransaction(
            kind: adjustment.kind, amount: adjustment.amount,
            note: BalanceTrendAnchor.adjustmentNote, account: account
        ))
        try context.save()

        #expect(account.balance == 2_000_000)
        let inserted = try context.fetch(
            FetchDescriptor<LedgerTransaction>(predicate: #Predicate {
                $0.note == "Điều chỉnh số dư"
            })
        )
        #expect(inserted.count == 1)
        #expect(inserted.first?.kind == .income)
        #expect(inserted.first?.amount == 1_300_000)
    }
}
