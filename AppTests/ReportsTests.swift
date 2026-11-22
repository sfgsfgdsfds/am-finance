import Testing
import SwiftData
import Foundation
import FinanceCore
@testable import AMFinance

@MainActor
struct ReportsTests {
    private let calendar = AppCalendar.vietnam

    private func makeContext() throws -> ModelContext {
        ModelContext(try AppModelContainer.make(inMemory: true))
    }

    private func date(
        _ year: Int, _ month: Int, _ day: Int,
        _ hour: Int = 12, _ minute: Int = 0
    ) -> Date {
        calendar.date(from: DateComponents(
            year: year, month: month, day: day, hour: hour, minute: minute
        ))!
    }

    // MARK: - Period intervals & titles

    @Test func monthIntervalCoversWholeMonth() {
        let period = ReportsPeriod(
            kind: .month, anchor: date(2026, 11, 22), calendar: calendar)
        let interval = period.interval(calendar: calendar)
        #expect(interval.start == date(2026, 11, 1, 0, 0))
        #expect(interval.end == date(2026, 12, 1, 0, 0))
        #expect(period.title(calendar: calendar) == "Tháng 11/2026")
    }

    @Test func quarterOneStartsInJanuary() {
        let period = ReportsPeriod(
            kind: .quarter, anchor: date(2026, 2, 15), calendar: calendar)
        let interval = period.interval(calendar: calendar)
        #expect(interval.start == date(2026, 1, 1, 0, 0))
        #expect(interval.end == date(2026, 4, 1, 0, 0))
        #expect(period.title(calendar: calendar) == "Quý 1/2026")
    }

    @Test func quarterFourCrossesYearBoundary() {
        let period = ReportsPeriod(
            kind: .quarter, anchor: date(2026, 11, 22), calendar: calendar)
        let interval = period.interval(calendar: calendar)
        #expect(interval.start == date(2026, 10, 1, 0, 0))
        #expect(interval.end == date(2027, 1, 1, 0, 0))
        #expect(period.title(calendar: calendar) == "Quý 4/2026")
    }

    @Test func yearIntervalCoversWholeYear() {
        let period = ReportsPeriod(
            kind: .year, anchor: date(2026, 6, 15), calendar: calendar)
        let interval = period.interval(calendar: calendar)
        #expect(interval.start == date(2026, 1, 1, 0, 0))
        #expect(interval.end == date(2027, 1, 1, 0, 0))
        #expect(period.title(calendar: calendar) == "Năm 2026")
    }

    @Test func customRangeIsInclusiveOfLastDay() {
        let period = ReportsPeriod(
            kind: .custom,
            customStart: date(2026, 10, 1),
            customEnd: date(2026, 11, 15),
            calendar: calendar)
        let interval = period.interval(calendar: calendar)
        #expect(interval.start == date(2026, 10, 1, 0, 0))
        #expect(interval.end == date(2026, 11, 16, 0, 0))
        // The last picked day counts fully.
        #expect(interval.contains(date(2026, 11, 15, 23, 59)))
        #expect(!interval.contains(date(2026, 11, 16, 0, 1)))
        #expect(period.title(calendar: calendar) == "01/10 – 15/11/2026")
    }

    @Test func customRangeAcrossYearsShowsBothYears() {
        let period = ReportsPeriod(
            kind: .custom,
            customStart: date(2025, 12, 15),
            customEnd: date(2026, 1, 10),
            calendar: calendar)
        #expect(period.title(calendar: calendar) == "15/12/2025 – 10/01/2026")
    }

    @Test func customReversedBoundsAreSwapped() {
        let period = ReportsPeriod(
            kind: .custom,
            customStart: date(2026, 11, 15),
            customEnd: date(2026, 10, 1),
            calendar: calendar)
        let interval = period.interval(calendar: calendar)
        #expect(interval.start == date(2026, 10, 1, 0, 0))
        #expect(interval.end == date(2026, 11, 16, 0, 0))
    }

    // MARK: - Period navigation

    @Test func previousNextMonthAcrossYear() {
        let period = ReportsPeriod(
            kind: .month, anchor: date(2026, 1, 15), calendar: calendar)
        #expect(period.shifted(by: -1, calendar: calendar)
            .interval(calendar: calendar).start == date(2025, 12, 1, 0, 0))
        #expect(period.shifted(by: 1, calendar: calendar)
            .interval(calendar: calendar).start == date(2026, 2, 1, 0, 0))
    }

    @Test func previousNextQuarterAcrossYear() {
        let q4 = ReportsPeriod(
            kind: .quarter, anchor: date(2026, 11, 10), calendar: calendar)
        #expect(q4.shifted(by: 1, calendar: calendar)
            .title(calendar: calendar) == "Quý 1/2027")
        #expect(q4.shifted(by: -1, calendar: calendar)
            .title(calendar: calendar) == "Quý 3/2026")
    }

    @Test func previousNextYear() {
        let period = ReportsPeriod(
            kind: .year, anchor: date(2026, 6, 1), calendar: calendar)
        #expect(period.shifted(by: -1, calendar: calendar)
            .title(calendar: calendar) == "Năm 2025")
        #expect(period.shifted(by: 1, calendar: calendar)
            .title(calendar: calendar) == "Năm 2027")
    }

    @Test func shiftedCustomMovesByItsOwnLength() {
        // 15-day range: Oct 1 – Oct 15.
        let period = ReportsPeriod(
            kind: .custom,
            customStart: date(2026, 10, 1),
            customEnd: date(2026, 10, 15),
            calendar: calendar)
        let next = period.shifted(by: 1, calendar: calendar)
        #expect(next.interval(calendar: calendar).start == date(2026, 10, 16, 0, 0))
        #expect(next.interval(calendar: calendar).end == date(2026, 10, 31, 0, 0))
        let back = next.shifted(by: -1, calendar: calendar)
        #expect(back.interval(calendar: calendar) == period.interval(calendar: calendar))
    }

    @Test func fetchIntervalCoversPreviousAndTrend() {
        // November 2026: trend is Dec 2025 – Nov 2026, previous is the
        // equal-length October window — the fetch starts Dec 1, 2025.
        let period = ReportsPeriod(
            kind: .month, anchor: date(2026, 11, 15), calendar: calendar)
        let fetch = period.fetchInterval(trendMonths: 12, calendar: calendar)
        #expect(fetch.start == date(2025, 12, 1, 0, 0))
        #expect(fetch.end == date(2026, 12, 1, 0, 0))
    }

    // MARK: - Snapshot fixture

    private let catFood = UUID()
    private let catFuel = UUID()
    private let catSalary = UUID()
    private let bizA = UUID()
    private let bizB = UUID()

    /// November 2026 report data: personal + business entries, a transfer,
    /// previous-period (October) entries, and a far-past entry that must
    /// never be counted.
    private func dataset() -> [ReportEntry] {
        [
            // Personal, November.
            ReportEntry(date: date(2026, 11, 5), kind: .expense,
                        amount: 500_000, categoryID: catFood),
            ReportEntry(date: date(2026, 11, 10), kind: .expense,
                        amount: 300_000, categoryID: catFuel),
            ReportEntry(date: date(2026, 11, 2), kind: .income,
                        amount: 20_000_000, categoryID: catSalary),
            // Business A, November.
            ReportEntry(date: date(2026, 11, 3), kind: .income,
                        amount: 10_000_000, categoryID: catSalary,
                        businessID: bizA),
            ReportEntry(date: date(2026, 11, 4), kind: .expense,
                        amount: 2_000_000, categoryID: catFood,
                        businessID: bizA),
            ReportEntry(date: date(2026, 11, 8), kind: .income,
                        amount: 4_000_000, categoryID: catSalary,
                        businessID: bizB),
            // A transfer — never income, expense or count.
            ReportEntry(date: date(2026, 11, 6), kind: .transfer,
                        amount: 99_000_000),
            // Previous period (October, inside the equal-length window).
            ReportEntry(date: date(2026, 10, 20), kind: .expense,
                        amount: 400_000, categoryID: catFood),
            ReportEntry(date: date(2026, 10, 10), kind: .income,
                        amount: 5_000_000, categoryID: catSalary),
            // Outside every window.
            ReportEntry(date: date(2025, 1, 5), kind: .income,
                        amount: 999_000_000),
        ]
    }

    private var november2026: ReportDateInterval {
        ReportDateInterval(
            start: date(2026, 11, 1, 0, 0), end: date(2026, 12, 1, 0, 0))
    }

    private var lookupCategories: [UUID: ReportsEntityInfo] {
        [
            catFood: ReportsEntityInfo(
                name: "Ăn uống", icon: "fork.knife", colorHex: "FF9500"),
            catFuel: ReportsEntityInfo(
                name: "Di chuyển", icon: "car.fill", colorHex: "0A84FF"),
            catSalary: ReportsEntityInfo(
                name: "Lương & thù lao", icon: "banknote", colorHex: "34C759"),
        ]
    }

    private var lookupBusinesses: [UUID: ReportsEntityInfo] {
        [
            bizA: ReportsEntityInfo(
                name: "Làm web",
                icon: "chevron.left.forwardslash.chevron.right",
                colorHex: "0A84FF"),
            bizB: ReportsEntityInfo(
                name: "Căn hộ dịch vụ", icon: "building.2.fill",
                colorHex: "30B0C7"),
        ]
    }

    private func makeSnapshot(
        scope: ReportScope = .all,
        interval: ReportDateInterval? = nil,
        dailyInMonth: Date? = nil,
        entries: [ReportEntry]? = nil
    ) -> ReportsSnapshot {
        ReportsSnapshot.make(
            entries: entries ?? dataset(),
            interval: interval ?? november2026,
            scope: scope,
            categories: lookupCategories,
            businesses: lookupBusinesses,
            trendAnchor: date(2026, 11, 30),
            dailyInMonth: dailyInMonth,
            calendar: calendar
        )
    }

    // MARK: - Snapshot: totals & scopes

    @Test func snapshotAllScopeTotals() {
        let snapshot = makeSnapshot()
        // 20M + 10M + 4M income; 0.5M + 0.3M + 2M expense. The 99M
        // transfer and the 2025 entry are ignored.
        #expect(snapshot.comparison.current.income == 34_000_000)
        #expect(snapshot.comparison.current.expense == 2_800_000)
        #expect(snapshot.comparison.current.net == 31_200_000)
        #expect(snapshot.comparison.current.count == 6)
        // Previous period: Oct 2 – Nov 1.
        #expect(snapshot.comparison.previous.income == 5_000_000)
        #expect(snapshot.comparison.previous.expense == 400_000)
        #expect(snapshot.comparison.income.percent != nil)
        #expect(!snapshot.isEmpty)
    }

    @Test func snapshotPersonalScopeExcludesBusiness() {
        let snapshot = makeSnapshot(scope: .personal)
        #expect(snapshot.comparison.current.income == 20_000_000)
        #expect(snapshot.comparison.current.expense == 800_000)
        #expect(snapshot.comparison.current.count == 3)
    }

    @Test func snapshotOneBusinessScope() {
        let snapshot = makeSnapshot(scope: .business(bizA))
        #expect(snapshot.comparison.current.income == 10_000_000)
        #expect(snapshot.comparison.current.expense == 2_000_000)
        #expect(snapshot.comparison.current.count == 2)
        // Trend is scoped too: only bizA's November income appears.
        let november = snapshot.trend.last
        #expect(november?.income == 10_000_000)
        #expect(november?.expense == 2_000_000)
    }

    @Test func snapshotEmptyPeriod() {
        let january = ReportDateInterval(
            start: date(2026, 1, 1, 0, 0), end: date(2026, 2, 1, 0, 0))
        let snapshot = makeSnapshot(interval: january)
        #expect(snapshot.isEmpty)
        #expect(snapshot.expense.isEmpty)
        #expect(snapshot.income.isEmpty)
    }

    // MARK: - Snapshot: categories

    @Test func expenseCategoriesSortedWithNamesAndShares() {
        let snapshot = makeSnapshot()
        // Ăn uống 2.5M (personal + bizA), Di chuyển 0.3M.
        #expect(snapshot.expense.map(\.name) == ["Ăn uống", "Di chuyển"])
        #expect(snapshot.expense.map(\.total) == [2_500_000, 300_000])
        #expect(snapshot.expense.map(\.count) == [2, 1])
        #expect(snapshot.expense[0].icon == "fork.knife")
        #expect(snapshot.expense[0].colorHex == "FF9500")
        let shareSum = snapshot.expense.reduce(0.0) { $0 + $1.share }
        #expect(abs(shareSum - 1) < 0.0001)
        #expect(snapshot.expense[0].share == 2_500_000.0 / 2_800_000.0)
    }

    @Test func incomeCategoriesAndUncategorized() {
        var entries = dataset()
        entries.append(ReportEntry(
            date: date(2026, 11, 12), kind: .income,
            amount: 1_000_000)) // no category
        let snapshot = makeSnapshot(entries: entries)
        // Salary 34M first, then "Chưa phân loại" 1M.
        #expect(snapshot.income.map(\.name) == ["Lương & thù lao", "Chưa phân loại"])
        #expect(snapshot.income[1].categoryID == nil)
        #expect(snapshot.income[1].icon == "questionmark")
        let shareSum = snapshot.income.reduce(0.0) { $0 + $1.share }
        #expect(abs(shareSum - 1) < 0.0001)
    }

    @Test func chartSlicesFoldIntoOther() {
        // Seven categories force the donut to fold the tail into "Khác".
        let entries = (1...7).map { index in
            ReportEntry(
                date: date(2026, 11, index), kind: .expense,
                amount: Int64(index) * 100_000, categoryID: UUID())
        }
        let snapshot = makeSnapshot(entries: entries)
        #expect(snapshot.expense.count == 7)
        #expect(snapshot.expenseChart.count == ReportsSnapshot.chartLimit + 1)
        let other = snapshot.expenseChart.last
        #expect(other?.isOther == true)
        #expect(other?.name == "Khác")
        #expect(other?.total == 100_000) // the smallest slice folds away
        let chartShare = snapshot.expenseChart.reduce(0.0) { $0 + $1.share }
        #expect(abs(chartShare - 1) < 0.0001)
    }

    // MARK: - Snapshot: business P&L

    @Test func businessProfitAndLoss() {
        let snapshot = makeSnapshot()
        // bizA: revenue 10M, cost 2M → profit 8M, margin 80%.
        // bizB: revenue 4M, cost 0 → profit 4M, margin 100%.
        #expect(snapshot.businesses.map(\.businessID) == [bizA, bizB])
        let first = snapshot.businesses[0]
        #expect(first.name == "Làm web")
        #expect(first.revenue == 10_000_000)
        #expect(first.cost == 2_000_000)
        #expect(first.profit == 8_000_000)
        #expect(abs(first.margin - 0.8) < 0.0001)
        let second = snapshot.businesses[1]
        #expect(second.profit == 4_000_000)
        #expect(abs(second.margin - 1.0) < 0.0001)
    }

    @Test func businessLossShowsNegativeProfitAndMargin() {
        let entries = [
            ReportEntry(date: date(2026, 11, 3), kind: .income,
                        amount: 1_000_000, businessID: bizA),
            ReportEntry(date: date(2026, 11, 4), kind: .expense,
                        amount: 3_000_000, businessID: bizA),
        ]
        let snapshot = makeSnapshot(entries: entries)
        #expect(snapshot.businesses.count == 1)
        #expect(snapshot.businesses[0].profit == -2_000_000)
        #expect(abs(snapshot.businesses[0].margin - (-2.0)) < 0.0001)
    }

    // MARK: - Snapshot: trend & daily

    @Test func trendHasTwelveMonthsEndingAtPeriod() {
        let snapshot = makeSnapshot()
        #expect(snapshot.trend.count == 12)
        #expect(snapshot.trend.last?.monthStart == date(2026, 11, 1, 0, 0))
        #expect(snapshot.trend.first?.monthStart == date(2025, 12, 1, 0, 0))
        // November 2026 and October 2026 totals land in their months.
        #expect(snapshot.trend.last?.income == 34_000_000)
        #expect(snapshot.trend.last?.expense == 2_800_000)
        #expect(snapshot.trend[10].income == 5_000_000)
        // Empty months are zero-filled, and the 2025 entry is out of range.
        #expect(snapshot.trend[0].income == 0)
    }

    @Test func dailySeriesOnlyWhenRequested() {
        let withDaily = makeSnapshot(dailyInMonth: date(2026, 11, 20))
        #expect(withDaily.daily.count == 30)
        #expect(withDaily.daily[3].expense == 2_000_000)   // Nov 4
        #expect(withDaily.daily[4].expense == 500_000)     // Nov 5
        #expect(withDaily.daily[9].expense == 300_000)     // Nov 10
        let withoutDaily = makeSnapshot()
        #expect(withoutDaily.daily.isEmpty)
    }

    // MARK: - SwiftData mapping (mirrors the view's entry conversion)

    @Test func entriesFromSwiftDataCarryCategoryAndBusiness() throws {
        let context = try makeContext()
        let cash = Account(name: "Tiền mặt", kind: .cash)
        let food = LedgerCategory(name: "Ăn uống", kind: .expense)
        let shop = Business(name: "Làm web")
        context.insert(cash)
        context.insert(food)
        context.insert(shop)
        context.insert(LedgerTransaction(
            kind: .expense, amount: 700_000, date: date(2026, 11, 5),
            account: cash, category: food, business: shop))
        context.insert(LedgerTransaction(
            kind: .transfer, amount: 5_000_000, date: date(2026, 11, 6),
            account: cash))
        try context.save()

        let start = date(2026, 11, 1, 0, 0)
        let end = date(2026, 12, 1, 0, 0)
        let fetched = try context.fetch(FetchDescriptor<LedgerTransaction>(
            predicate: #Predicate { $0.date >= start && $0.date < end }))
        // The transfer is fetched but excluded from every total.
        #expect(fetched.count == 2)

        let entries = fetched.map {
            ReportEntry(
                date: $0.date, kind: $0.kind, amount: $0.amount,
                categoryID: $0.category?.id, businessID: $0.business?.id)
        }
        let snapshot = ReportsSnapshot.make(
            entries: entries,
            interval: ReportDateInterval(start: start, end: end),
            scope: .all,
            categories: [food.id: ReportsEntityInfo(name: food.name)],
            businesses: [shop.id: ReportsEntityInfo(name: shop.name)],
            trendAnchor: date(2026, 11, 30),
            dailyInMonth: nil,
            calendar: calendar)

        #expect(snapshot.comparison.current.expense == 700_000)
        #expect(snapshot.comparison.current.count == 1)
        #expect(snapshot.expense.first?.name == "Ăn uống")
        #expect(snapshot.businesses.first?.businessID == shop.id)
        #expect(snapshot.businesses.first?.cost == 700_000)
    }
}
