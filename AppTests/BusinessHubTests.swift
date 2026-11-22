import Testing
import SwiftData
import Foundation
import FinanceCore
@testable import AMFinance

@MainActor
struct BusinessHubTests {
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

    // MARK: - Fixture

    private let catSalary = UUID()
    private let catTools = UUID()
    private let catAds = UUID()
    private let bizA = UUID()   // Làm web — profitable
    private let bizB = UUID()   // Căn hộ — loss
    private let bizC = UUID()   // Quảng cáo — no activity
    private let bizD = UUID()   // Cũ — archived, still has entries
    private let bizE = UUID()   // Mới — cost only

    /// November 2026 data: income/cost per business, an archived business
    /// that still has entries, personal movements, a business transfer and
    /// previous-period (October) entries for bizA.
    private func dataset() -> [ReportEntry] {
        [
            // Personal, November.
            ReportEntry(date: date(2026, 11, 5), kind: .expense,
                        amount: 500_000),
            ReportEntry(date: date(2026, 11, 2), kind: .income,
                        amount: 20_000_000),
            // bizA, November: revenue 10M, cost 3M (2 categories).
            ReportEntry(date: date(2026, 11, 3), kind: .income,
                        amount: 10_000_000, categoryID: catSalary,
                        businessID: bizA),
            ReportEntry(date: date(2026, 11, 4), kind: .expense,
                        amount: 2_000_000, categoryID: catTools,
                        businessID: bizA),
            ReportEntry(date: date(2026, 11, 6), kind: .expense,
                        amount: 1_000_000, categoryID: catAds,
                        businessID: bizA),
            // bizA transfer between own accounts — never revenue/cost.
            ReportEntry(date: date(2026, 11, 7), kind: .transfer,
                        amount: 99_000_000, businessID: bizA),
            // bizB, November: revenue 4M, cost 5M — a loss.
            ReportEntry(date: date(2026, 11, 8), kind: .income,
                        amount: 4_000_000, categoryID: catSalary,
                        businessID: bizB),
            ReportEntry(date: date(2026, 11, 9), kind: .expense,
                        amount: 5_000_000, categoryID: catTools,
                        businessID: bizB),
            // bizD is archived but its tagged entries still happened.
            ReportEntry(date: date(2026, 11, 5), kind: .income,
                        amount: 7_000_000, businessID: bizD),
            // bizE: cost only, no revenue.
            ReportEntry(date: date(2026, 11, 10), kind: .expense,
                        amount: 1_000_000, businessID: bizE),
            // bizA, previous period (inside the equal-length October window).
            ReportEntry(date: date(2026, 10, 20), kind: .income,
                        amount: 5_000_000, businessID: bizA),
            ReportEntry(date: date(2026, 10, 21), kind: .expense,
                        amount: 2_000_000, businessID: bizA),
            // Far past — outside every window.
            ReportEntry(date: date(2025, 1, 5), kind: .income,
                        amount: 999_000_000, businessID: bizA),
        ]
    }

    private var november2026: ReportDateInterval {
        ReportDateInterval(
            start: date(2026, 11, 1, 0, 0), end: date(2026, 12, 1, 0, 0))
    }

    private var now: Date { date(2026, 11, 22) }

    private func businesses() -> [BusinessHubBusiness] {
        [
            BusinessHubBusiness(
                id: bizA, name: "Làm web",
                icon: "chevron.left.forwardslash.chevron.right",
                colorHex: "0A84FF", sortOrder: 0),
            BusinessHubBusiness(
                id: bizB, name: "Căn hộ dịch vụ",
                icon: "building.2.fill", colorHex: "30B0C7", sortOrder: 1),
            BusinessHubBusiness(
                id: bizC, name: "Chạy quảng cáo thuê",
                icon: "target", colorHex: "FF9F0A", sortOrder: 2),
            BusinessHubBusiness(
                id: bizD, name: "Mảng cũ", sortOrder: 3, isArchived: true),
            BusinessHubBusiness(
                id: bizE, name: "Mảng mới", sortOrder: 4),
        ]
    }

    private var lookupCategories: [UUID: ReportsEntityInfo] {
        [
            catSalary: ReportsEntityInfo(
                name: "Doanh thu dịch vụ", icon: "briefcase.fill",
                colorHex: "30D158"),
            catTools: ReportsEntityInfo(
                name: "Công cụ & phần mềm",
                icon: "wrench.and.screwdriver.fill", colorHex: "5E5CE6"),
            catAds: ReportsEntityInfo(
                name: "Quảng cáo", icon: "megaphone.fill", colorHex: "FF6482"),
        ]
    }

    private func makeSnapshot(
        entries: [ReportEntry]? = nil,
        interval: ReportDateInterval? = nil,
        businesses: [BusinessHubBusiness]? = nil
    ) -> BusinessHubSnapshot {
        BusinessHubSnapshot.make(
            entries: entries ?? dataset(),
            interval: interval ?? november2026,
            businesses: businesses ?? self.businesses(),
            now: now,
            calendar: calendar
        )
    }

    private func makeDetail(
        businessID: UUID? = nil,
        entries: [ReportEntry]? = nil,
        interval: ReportDateInterval? = nil
    ) -> BusinessHubDetailSnapshot {
        BusinessHubDetailSnapshot.make(
            entries: entries ?? dataset(),
            interval: interval ?? november2026,
            businessID: businessID ?? bizA,
            categories: lookupCategories,
            now: now,
            calendar: calendar
        )
    }

    // MARK: - Hub snapshot: per-business P&L

    @Test func streamRevenueCostProfitAndMargin() {
        let snapshot = makeSnapshot()
        let web = snapshot.streams.first { $0.businessID == bizA }
        #expect(web?.revenue == 10_000_000)
        #expect(web?.cost == 3_000_000)
        #expect(web?.profit == 7_000_000)
        #expect(abs((web?.margin ?? 0) - 0.7) < 0.0001)
        let apartment = snapshot.streams.first { $0.businessID == bizB }
        #expect(apartment?.revenue == 4_000_000)
        #expect(apartment?.cost == 5_000_000)
        #expect(apartment?.profit == -1_000_000)
        #expect(abs((apartment?.margin ?? 0) - (-0.25)) < 0.0001)
    }

    @Test func businessWithNoActivityStillGetsZeroedCard() {
        let snapshot = makeSnapshot()
        let stream = snapshot.streams.first { $0.businessID == bizC }
        #expect(stream?.revenue == 0)
        #expect(stream?.cost == 0)
        #expect(stream?.profit == 0)
        #expect(stream?.margin == 0)
        #expect(stream?.sparkline == [0, 0, 0, 0, 0, 0])
    }

    @Test func zeroRevenueGivesZeroMargin() {
        // bizE has cost but no revenue — margin is 0, not NaN or negative.
        let snapshot = makeSnapshot()
        let stream = snapshot.streams.first { $0.businessID == bizE }
        #expect(stream?.revenue == 0)
        #expect(stream?.cost == 1_000_000)
        #expect(stream?.profit == -1_000_000)
        #expect(stream?.margin == 0)
    }

    @Test func streamsSortedByProfitDescending() {
        let snapshot = makeSnapshot()
        // A 7M > C 0 > B -1M = E -1M; the tie keeps manual sortOrder (B < E).
        #expect(snapshot.streams.map(\.businessID) == [bizA, bizC, bizB, bizE])
    }

    @Test func archivedBusinessIsNotAStream() {
        let snapshot = makeSnapshot()
        #expect(!snapshot.streams.contains { $0.businessID == bizD })
        // …but its tagged income still counts in the combined totals.
        #expect(snapshot.revenue == 21_000_000)
    }

    @Test func combinedTotalsExcludePersonalMovements() {
        let snapshot = makeSnapshot()
        // 10M + 4M + 7M business income; personal income of 20M is out.
        #expect(snapshot.revenue == 21_000_000)
        // 3M + 5M + 1M business cost; the 500k personal expense is out.
        #expect(snapshot.cost == 9_000_000)
        #expect(snapshot.profit == 12_000_000)
        #expect(snapshot.personalSpend == 500_000)
    }

    @Test func transfersNeverCounted() {
        // Without the 99M transfer the numbers are identical.
        let entries = dataset().filter { $0.kind != .transfer }
        #expect(makeSnapshot(entries: entries) == makeSnapshot())
        #expect(makeDetail(entries: entries) == makeDetail())
    }

    @Test func sparklineIsSixMonthsOfProfitZeroFilled() {
        let snapshot = makeSnapshot()
        let web = snapshot.streams.first { $0.businessID == bizA }
        // Jun–Nov 2026: Oct profit 3M (5M − 2M), Nov profit 7M; rest zero.
        #expect(web?.sparkline == [0, 0, 0, 0, 3_000_000, 7_000_000])
    }

    @Test func emptyWhenNoActiveBusiness() {
        let onlyArchived = [
            BusinessHubBusiness(id: bizD, name: "Cũ", isArchived: true),
        ]
        let snapshot = makeSnapshot(businesses: onlyArchived)
        #expect(snapshot.isEmpty)
        #expect(!makeSnapshot().isEmpty)
    }

    // MARK: - Series anchor & fetch window

    @Test func seriesAnchorClampsToPeriodEndForPastPeriods() {
        let september = ReportDateInterval(
            start: date(2026, 9, 1, 0, 0), end: date(2026, 10, 1, 0, 0))
        let anchor = BusinessHubSnapshot.seriesAnchor(
            interval: september, now: now)
        #expect(calendar.component(.month, from: anchor) == 9)
    }

    @Test func seriesAnchorClampsToNowForFuturePeriods() {
        let december = ReportDateInterval(
            start: date(2026, 12, 1, 0, 0), end: date(2027, 1, 1, 0, 0))
        let anchor = BusinessHubSnapshot.seriesAnchor(
            interval: december, now: now)
        #expect(anchor == now)
    }

    @Test func fetchIntervalCoversPreviousPeriodAndTrend() {
        // Six-month sparkline ending Nov 2026 starts Jun 2026; the
        // equal-length previous window (Oct 2 – Nov 1) sits inside it.
        let hubFetch = BusinessHubSnapshot.fetchInterval(
            interval: november2026, trendMonths: 6,
            now: now, calendar: calendar)
        #expect(hubFetch.start == date(2026, 6, 1, 0, 0))
        #expect(hubFetch.end == date(2026, 12, 1, 0, 0))
        let detailFetch = BusinessHubSnapshot.fetchInterval(
            interval: november2026, trendMonths: 12,
            now: now, calendar: calendar)
        #expect(detailFetch.start == date(2025, 12, 1, 0, 0))
        // A future period still fetches the series ending at now.
        let december = ReportDateInterval(
            start: date(2026, 12, 1, 0, 0), end: date(2027, 1, 1, 0, 0))
        let futureFetch = BusinessHubSnapshot.fetchInterval(
            interval: december, trendMonths: 6,
            now: now, calendar: calendar)
        #expect(futureFetch.start == date(2026, 6, 1, 0, 0))
        #expect(futureFetch.end == december.end)
    }

    // MARK: - Detail snapshot

    @Test func detailTotalsAndPreviousPeriodChange() {
        let detail = makeDetail()
        #expect(detail.current.income == 10_000_000)
        #expect(detail.current.expense == 3_000_000)
        #expect(detail.current.count == 3)
        #expect(detail.profit == 7_000_000)
        #expect(abs(detail.margin - 0.7) < 0.0001)
        // October: revenue 5M, cost 2M → profit 3M, margin 60%.
        #expect(detail.previous.income == 5_000_000)
        #expect(detail.previous.expense == 2_000_000)
        #expect(detail.previousProfit == 3_000_000)
        #expect(detail.revenueChange.delta == 5_000_000)
        #expect(abs((detail.revenueChange.percent ?? 0) - 1.0) < 0.0001)
        #expect(detail.costChange.delta == 1_000_000)
        #expect(detail.profitChange.delta == 4_000_000)
        #expect(abs(detail.marginChange - 0.1) < 0.0001)
    }

    @Test func detailNilChangeWhenPreviousIsZero() {
        // bizC had nothing in either period.
        let detail = makeDetail(businessID: bizC)
        #expect(detail.revenueChange.percent == nil)
        #expect(detail.costChange.percent == nil)
        #expect(detail.profitChange.percent == nil)
        #expect(detail.marginChange == 0)
        #expect(detail.isEmpty)
    }

    @Test func detailCategoryBreakdowns() {
        let detail = makeDetail()
        #expect(detail.revenueByCategory.map(\.name) == ["Doanh thu dịch vụ"])
        #expect(detail.revenueByCategory[0].share == 1)
        // Cost split: Công cụ 2M (2/3) then Quảng cáo 1M (1/3).
        #expect(detail.costByCategory.map(\.name)
            == ["Công cụ & phần mềm", "Quảng cáo"])
        #expect(detail.costByCategory.map(\.total) == [2_000_000, 1_000_000])
        #expect(abs(detail.costByCategory[0].share - 2.0 / 3.0) < 0.0001)
        #expect(detail.costByCategory[0].icon == "wrench.and.screwdriver.fill")
    }

    @Test func detailUncategorizedRowsGetFallbackName() {
        var entries = dataset()
        entries.append(ReportEntry(
            date: date(2026, 11, 12), kind: .expense,
            amount: 700_000, businessID: bizA))
        let detail = makeDetail(entries: entries)
        let last = detail.costByCategory.last
        #expect(last?.name == "Chưa phân loại")
        #expect(last?.icon == "questionmark")
        #expect(last?.total == 700_000)
    }

    @Test func twelveMonthSeriesIsZeroFilled() {
        let detail = makeDetail()
        #expect(detail.months.count == 12)
        // Dec 2025 – Nov 2026, oldest first.
        #expect(detail.months.first?.monthStart == date(2025, 12, 1, 0, 0))
        #expect(detail.months.last?.monthStart == date(2026, 11, 1, 0, 0))
        // bizA November and October; other months and the Jan-2025 entry
        // are out of the window.
        #expect(detail.months.last?.income == 10_000_000)
        #expect(detail.months.last?.expense == 3_000_000)
        #expect(detail.months.last?.net == 7_000_000)
        #expect(detail.months[10].income == 5_000_000)
        #expect(detail.months[0].income == 0)
        #expect(detail.months[0].expense == 0)
    }

    @Test func detailScopedToOneBusiness() {
        // bizB only sees its own November loss, not bizA's numbers.
        let detail = makeDetail(businessID: bizB)
        #expect(detail.current.income == 4_000_000)
        #expect(detail.current.expense == 5_000_000)
        #expect(detail.profit == -1_000_000)
        #expect(detail.months.last?.net == -1_000_000)
    }

    // MARK: - SwiftData mapping (mirrors the views' entry conversion)

    @Test func entriesFromSwiftDataCarryBusinessAndRespectWindow() throws {
        let context = try makeContext()
        let cash = Account(name: "Tiền mặt", kind: .cash)
        let bank = Account(name: "Ngân hàng", kind: .bank)
        let shop = Business(name: "Làm web", icon: "briefcase.fill")
        let home = Business(name: "Căn hộ", isArchived: true)
        let service = LedgerCategory(name: "Dịch vụ", kind: .income)
        context.insert(cash)
        context.insert(bank)
        context.insert(shop)
        context.insert(home)
        context.insert(service)
        context.insert(LedgerTransaction(
            kind: .income, amount: 8_000_000, date: date(2026, 11, 3),
            account: cash, category: service, business: shop))
        context.insert(LedgerTransaction(
            kind: .expense, amount: 2_000_000, date: date(2026, 11, 4),
            account: cash, business: shop))
        // Personal — must not reach the business totals.
        context.insert(LedgerTransaction(
            kind: .expense, amount: 400_000, date: date(2026, 11, 5),
            account: cash))
        // Archived business — tagged, still business money.
        context.insert(LedgerTransaction(
            kind: .income, amount: 3_000_000, date: date(2026, 11, 6),
            account: cash, business: home))
        // Transfer — fetched, never counted.
        context.insert(LedgerTransaction(
            kind: .transfer, amount: 5_000_000, date: date(2026, 11, 7),
            account: cash, toAccount: bank, business: shop))
        try context.save()

        let fetch = BusinessHubSnapshot.fetchInterval(
            interval: november2026, trendMonths: 6,
            now: now, calendar: calendar)
        let start = fetch.start
        let end = fetch.end
        let fetched = try context.fetch(FetchDescriptor<LedgerTransaction>(
            predicate: #Predicate { $0.date >= start && $0.date < end }))
        #expect(fetched.count == 5)

        let entries = fetched.map {
            ReportEntry(
                date: $0.date, kind: $0.kind, amount: $0.amount,
                categoryID: $0.category?.id, businessID: $0.business?.id)
        }
        let hub = BusinessHubSnapshot.make(
            entries: entries, interval: november2026,
            businesses: [
                BusinessHubBusiness(
                    id: shop.id, name: shop.name, icon: shop.icon),
                BusinessHubBusiness(
                    id: home.id, name: home.name, isArchived: true),
            ],
            now: now, calendar: calendar)
        #expect(hub.revenue == 11_000_000)
        #expect(hub.cost == 2_000_000)
        #expect(hub.personalSpend == 400_000)
        #expect(hub.streams.map(\.businessID) == [shop.id])
        #expect(hub.streams[0].profit == 6_000_000)

        let detail = BusinessHubDetailSnapshot.make(
            entries: entries, interval: november2026,
            businessID: shop.id, categories: [:],
            now: now, calendar: calendar)
        #expect(detail.current.income == 8_000_000)
        #expect(detail.current.expense == 2_000_000)
        #expect(detail.current.count == 2)
        #expect(detail.revenueByCategory.first?.name == "Chưa phân loại")
    }
}
