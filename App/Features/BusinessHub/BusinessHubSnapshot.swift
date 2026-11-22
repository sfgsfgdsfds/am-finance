import Foundation
import FinanceCore

/// Lightweight input describing one business for the hub snapshot — id,
/// display fields and the user's manual order — so the builders stay pure
/// value-type code that never touches SwiftData.
struct BusinessHubBusiness: Equatable, Sendable {
    var id: UUID
    var name: String
    var icon: String
    var colorHex: String
    var sortOrder: Int
    var isArchived: Bool

    init(
        id: UUID,
        name: String,
        icon: String = "",
        colorHex: String = "",
        sortOrder: Int = 0,
        isArchived: Bool = false
    ) {
        self.id = id
        self.name = name
        self.icon = icon
        self.colorHex = colorHex
        self.sortOrder = sortOrder
        self.isArchived = isArchived
    }
}

/// One business card on the hub screen: the period's profit and loss plus a
/// short monthly-profit series for the sparkline.
struct BusinessHubStream: Identifiable, Equatable, Sendable {
    var businessID: UUID
    var name: String
    var icon: String
    var colorHex: String
    /// Income entries summed, đồng ≥ 0.
    var revenue: Int64
    /// Expense entries summed, đồng ≥ 0.
    var cost: Int64
    /// `revenue - cost`, saturating; negative means a loss.
    var profit: Int64
    /// `profit / revenue`; 0 when revenue is 0.
    var margin: Double
    /// Monthly profit, oldest first — `sparklineMonths` points, zero-filled.
    var sparkline: [Int64]

    var id: UUID { businessID }
}

/// Everything `BusinessHubView` shows for one period: the combined business
/// totals, one card per active business and the personal-spending context
/// figure. Computed once from lightweight values — `ReportEntry` lists plus
/// `BusinessHubBusiness` — so the view is a thin renderer.
struct BusinessHubSnapshot: Equatable, Sendable {
    /// Revenue across all business-tagged entries, đồng ≥ 0.
    var revenue: Int64
    /// Cost across all business-tagged entries, đồng ≥ 0.
    var cost: Int64
    /// `revenue - cost`, saturating.
    var profit: Int64
    /// `profit / revenue`; 0 when revenue is 0.
    var margin: Double
    /// Personal (`businessID == nil`) expense in the period — shown as the
    /// "Chi tiêu cá nhân kỳ này" context row.
    var personalSpend: Int64
    /// One card per non-archived business, sorted by profit descending
    /// (ties keep the user's manual `sortOrder`, then UUID).
    var streams: [BusinessHubStream]

    /// True when there is no non-archived business — the view shows the
    /// empty state instead of zeroed cards.
    var isEmpty: Bool { streams.isEmpty }

    init(
        revenue: Int64,
        cost: Int64,
        profit: Int64,
        margin: Double,
        personalSpend: Int64,
        streams: [BusinessHubStream]
    ) {
        self.revenue = revenue
        self.cost = cost
        self.profit = profit
        self.margin = margin
        self.personalSpend = personalSpend
        self.streams = streams
    }

    /// How many months each business card's sparkline covers.
    static let sparklineMonths = 6

    /// Builds the hub snapshot. `now` clamps the monthly series so a period
    /// in the future never produces future-dated points.
    static func make(
        entries: [ReportEntry],
        interval: ReportDateInterval,
        businesses: [BusinessHubBusiness],
        now: Date,
        sparklineMonths: Int = BusinessHubSnapshot.sparklineMonths,
        calendar: Calendar
    ) -> BusinessHubSnapshot {
        let totals = ReportSummary.totals(
            entries: entries, in: interval, scope: .anyBusiness)
        let personal = ReportSummary.totals(
            entries: entries, in: interval, scope: .personal)
        let results = Dictionary(
            uniqueKeysWithValues: ReportSummary.byBusiness(
                entries: entries, in: interval
            ).map { ($0.businessID, $0) }
        )
        let anchor = seriesAnchor(interval: interval, now: now)
        let sortOrders = Dictionary(
            uniqueKeysWithValues: businesses.map { ($0.id, $0.sortOrder) }
        )
        let streams = businesses
            .filter { !$0.isArchived }
            .map { business in
                let result = results[business.id]
                let monthly = ReportSummary.monthly(
                    entries: entries,
                    months: sparklineMonths,
                    endingAt: anchor,
                    calendar: calendar,
                    scope: .business(business.id)
                )
                return BusinessHubStream(
                    businessID: business.id,
                    name: business.name.isEmpty ? "Kinh doanh" : business.name,
                    icon: business.icon,
                    colorHex: business.colorHex.isEmpty
                        ? "8E8E93" : business.colorHex,
                    revenue: result?.revenue ?? 0,
                    cost: result?.cost ?? 0,
                    profit: result?.profit ?? 0,
                    margin: result?.margin ?? 0,
                    sparkline: monthly.map(\.net)
                )
            }
            .sorted { lhs, rhs in
                if lhs.profit != rhs.profit { return lhs.profit > rhs.profit }
                let left = sortOrders[lhs.businessID] ?? 0
                let right = sortOrders[rhs.businessID] ?? 0
                return left != right
                    ? left < right
                    : lhs.businessID.uuidString < rhs.businessID.uuidString
            }
        return BusinessHubSnapshot(
            revenue: totals.income,
            cost: totals.expense,
            profit: totals.net,
            margin: Self.margin(income: totals.income, net: totals.net),
            personalSpend: personal.expense,
            streams: streams
        )
    }

    /// Where a monthly series ends: the last instant of the viewed period,
    /// clamped to `now`. For the current period this lands in its last
    /// month; for a past period, in that period's last month.
    static func seriesAnchor(
        interval: ReportDateInterval, now: Date
    ) -> Date {
        min(now, interval.end.addingTimeInterval(-1))
    }

    /// The date window the views fetch: covers the displayed period, the
    /// equal-length previous period and the `trendMonths`-month series
    /// ending at `seriesAnchor` — never the whole table.
    static func fetchInterval(
        interval: ReportDateInterval,
        trendMonths: Int,
        now: Date,
        calendar: Calendar
    ) -> ReportDateInterval {
        var start = interval.previous.start
        if trendMonths > 0 {
            let lastMonth = ReportSummary.monthInterval(
                containing: seriesAnchor(interval: interval, now: now),
                calendar: calendar
            ).start
            let trendStart = calendar.date(
                byAdding: .month, value: -(trendMonths - 1), to: lastMonth
            ) ?? lastMonth
            start = min(start, trendStart)
        }
        return ReportDateInterval(start: start, end: interval.end)
    }

    /// `net / income` as a fraction; 0 when income is 0.
    static func margin(income: Int64, net: Int64) -> Double {
        income > 0 ? Double(net) / Double(income) : 0
    }
}

/// Everything `BusinessHubDetailView` shows for one business and period:
/// totals with the change versus the equal-length previous period, revenue
/// and cost broken down by category, and a twelve-month revenue/cost/profit
/// series for the chart.
struct BusinessHubDetailSnapshot: Equatable, Sendable {
    /// This business's income/expense/count in the period — transfers
    /// excluded.
    var current: ReportTotals
    /// The same totals for the equal-length interval immediately before.
    var previous: ReportTotals
    var revenueChange: ReportChange
    var costChange: ReportChange
    var profitChange: ReportChange
    /// `margin - previousMargin` as a fraction (0.05 = +5 percentage
    /// points); always defined since margin is 0 on empty periods.
    var marginChange: Double
    /// Income rows by category, sorted by total desc.
    var revenueByCategory: [ReportsCategorySlice]
    /// Expense rows by category, sorted by total desc.
    var costByCategory: [ReportsCategorySlice]
    /// Revenue/cost per month, oldest first, ending at the period's last
    /// month (clamped to `now`); `net` is the month's profit.
    var months: [ReportMonthPoint]

    /// `current.net` — the period's profit (negative is a loss).
    var profit: Int64 { current.net }
    /// `profit / revenue`; 0 when revenue is 0.
    var margin: Double {
        BusinessHubSnapshot.margin(income: current.income, net: current.net)
    }
    var previousProfit: Int64 { previous.net }
    var previousMargin: Double {
        BusinessHubSnapshot.margin(income: previous.income, net: previous.net)
    }
    /// True when the period holds no income/expense entry for this business.
    var isEmpty: Bool { current.count == 0 }

    /// How many months the detail chart covers.
    static let trendMonths = 12

    /// Builds the detail snapshot for `businessID`.
    static func make(
        entries: [ReportEntry],
        interval: ReportDateInterval,
        businessID: UUID,
        categories: [UUID: ReportsEntityInfo],
        now: Date,
        trendMonths: Int = BusinessHubDetailSnapshot.trendMonths,
        calendar: Calendar
    ) -> BusinessHubDetailSnapshot {
        let scope = ReportScope.business(businessID)
        let current = ReportSummary.totals(
            entries: entries, in: interval, scope: scope)
        let previous = ReportSummary.totals(
            entries: entries, in: interval.previous, scope: scope)
        let anchor = BusinessHubSnapshot.seriesAnchor(
            interval: interval, now: now)
        return BusinessHubDetailSnapshot(
            current: current,
            previous: previous,
            revenueChange: ReportChange(
                current: current.income, previous: previous.income),
            costChange: ReportChange(
                current: current.expense, previous: previous.expense),
            profitChange: ReportChange(
                current: current.net, previous: previous.net),
            marginChange: BusinessHubSnapshot.margin(
                income: current.income, net: current.net)
                - BusinessHubSnapshot.margin(
                    income: previous.income, net: previous.net),
            revenueByCategory: slices(
                ReportSummary.byCategory(
                    entries: entries, in: interval, kind: .income,
                    scope: scope),
                categories: categories),
            costByCategory: slices(
                ReportSummary.byCategory(
                    entries: entries, in: interval, kind: .expense,
                    scope: scope),
                categories: categories),
            months: ReportSummary.monthly(
                entries: entries, months: trendMonths,
                endingAt: anchor, calendar: calendar, scope: scope)
        )
    }

    /// Resolves `ReportCategoryRow`s for display — same name/icon/color
    /// fallbacks the reports tab uses.
    private static func slices(
        _ rows: [ReportCategoryRow],
        categories: [UUID: ReportsEntityInfo]
    ) -> [ReportsCategorySlice] {
        rows.map { row in
            let info = row.categoryID.flatMap { categories[$0] }
            return ReportsCategorySlice(
                categoryID: row.categoryID,
                name: info.flatMap { $0.name.isEmpty ? nil : $0.name }
                    ?? "Chưa phân loại",
                icon: info?.icon ?? "questionmark",
                colorHex: info?.colorHex ?? "8E8E93",
                total: row.total,
                count: row.count,
                share: row.share,
                isOther: false
            )
        }
    }
}
