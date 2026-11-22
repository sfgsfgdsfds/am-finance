import Foundation
import FinanceCore

/// Display info for a category or business — name, SF Symbol and hex color
/// as stored on the model. Lightweight input for `ReportsSnapshot`.
struct ReportsEntityInfo: Equatable, Sendable {
    var name: String
    var icon: String
    var colorHex: String

    init(name: String, icon: String = "", colorHex: String = "") {
        self.name = name
        self.icon = icon
        self.colorHex = colorHex
    }
}

/// One row of a category breakdown, resolved for display.
struct ReportsCategorySlice: Identifiable, Equatable, Sendable {
    /// nil = uncategorized; on the folded chart row `isOther` is true.
    let categoryID: UUID?
    let name: String
    let icon: String
    let colorHex: String
    let total: Int64
    let count: Int
    /// Fraction of the kind's grand total (0 when that total is 0).
    let share: Double
    /// True only for the aggregated "Khác" slice used in charts.
    let isOther: Bool

    var id: String {
        (isOther ? "other-" : "") + (categoryID?.uuidString ?? "uncategorized")
    }
}

/// Profit-and-loss for one business, resolved for display.
struct ReportsBusinessSlice: Identifiable, Equatable, Sendable {
    let businessID: UUID
    let name: String
    let icon: String
    let colorHex: String
    let revenue: Int64
    let cost: Int64
    let profit: Int64
    /// `profit / revenue`; 0 when revenue is 0.
    let margin: Double

    var id: UUID { businessID }
}

/// Everything the reports tab shows for one period and scope, computed once
/// from lightweight values — `ReportEntry` lists plus display lookups — so
/// the view stays a thin renderer and the numbers stay testable.
struct ReportsSnapshot: Equatable, Sendable {
    /// Current period vs the equal-length interval immediately before it.
    var comparison: ReportComparison
    /// Expense rows sorted by total desc — the list under the donut.
    var expense: [ReportsCategorySlice]
    /// Income rows sorted by total desc.
    var income: [ReportsCategorySlice]
    /// Top expense slices with the rest folded into "Khác" — for the donut.
    var expenseChart: [ReportsCategorySlice]
    /// Top income slices with the rest folded into "Khác".
    var incomeChart: [ReportsCategorySlice]
    /// P&L per business — only rendered for scope `.all`.
    var businesses: [ReportsBusinessSlice]
    /// Income/expense per month, oldest first, ending at the period's
    /// last month.
    var trend: [ReportMonthPoint]
    /// Per-day points of the displayed month — present for month periods
    /// only (empty otherwise).
    var daily: [ReportDayPoint]

    /// True when the period holds no income/expense entry at all — the view
    /// shows the empty state. Transfers never count.
    var isEmpty: Bool { comparison.current.count == 0 }

    init(
        comparison: ReportComparison,
        expense: [ReportsCategorySlice],
        income: [ReportsCategorySlice],
        expenseChart: [ReportsCategorySlice],
        incomeChart: [ReportsCategorySlice],
        businesses: [ReportsBusinessSlice],
        trend: [ReportMonthPoint],
        daily: [ReportDayPoint]
    ) {
        self.comparison = comparison
        self.expense = expense
        self.income = income
        self.expenseChart = expenseChart
        self.incomeChart = incomeChart
        self.businesses = businesses
        self.trend = trend
        self.daily = daily
    }

    /// How many category slices the donut shows before folding into "Khác".
    static let chartLimit = 6

    /// Builds the whole snapshot. `dailyInMonth` non-nil adds the daily
    /// series for the calendar month containing that date.
    static func make(
        entries: [ReportEntry],
        interval: ReportDateInterval,
        scope: ReportScope,
        categories: [UUID: ReportsEntityInfo],
        businesses: [UUID: ReportsEntityInfo],
        trendAnchor: Date,
        dailyInMonth: Date?,
        trendMonths: Int = 12,
        calendar: Calendar
    ) -> ReportsSnapshot {
        ReportsSnapshot(
            comparison: ReportSummary.comparison(
                entries: entries, in: interval, scope: scope),
            expense: slices(
                ReportSummary.byCategory(
                    entries: entries, in: interval, kind: .expense, scope: scope),
                categories: categories),
            income: slices(
                ReportSummary.byCategory(
                    entries: entries, in: interval, kind: .income, scope: scope),
                categories: categories),
            expenseChart: slices(
                ReportSummary.topCategories(
                    entries: entries, in: interval, kind: .expense,
                    limit: chartLimit, scope: scope),
                categories: categories),
            incomeChart: slices(
                ReportSummary.topCategories(
                    entries: entries, in: interval, kind: .income,
                    limit: chartLimit, scope: scope),
                categories: categories),
            businesses: ReportSummary.byBusiness(entries: entries, in: interval)
                .map { businessSlice($0, info: businesses) },
            trend: ReportSummary.monthly(
                entries: entries, months: trendMonths,
                endingAt: trendAnchor, calendar: calendar, scope: scope),
            daily: dailyInMonth.map {
                ReportSummary.daily(
                    entries: entries, inMonthContaining: $0,
                    calendar: calendar, scope: scope)
            } ?? []
        )
    }

    // MARK: - Resolution

    private static func slices(
        _ rows: [ReportCategoryRow],
        categories: [UUID: ReportsEntityInfo]
    ) -> [ReportsCategorySlice] {
        rows.map { row in
            let info = row.categoryID.flatMap { categories[$0] }
            let name: String
            let icon: String
            if row.isOther {
                name = "Khác"
                icon = "ellipsis.circle.fill"
            } else if let info {
                name = info.name.isEmpty ? "Chưa phân loại" : info.name
                icon = info.icon
            } else {
                name = "Chưa phân loại"
                icon = "questionmark"
            }
            return ReportsCategorySlice(
                categoryID: row.isOther ? nil : row.categoryID,
                name: name,
                icon: icon,
                colorHex: info?.colorHex ?? "8E8E93",
                total: row.total,
                count: row.count,
                share: row.share,
                isOther: row.isOther
            )
        }
    }

    private static func businessSlice(
        _ result: ReportBusinessResult,
        info: [UUID: ReportsEntityInfo]
    ) -> ReportsBusinessSlice {
        let entity = info[result.businessID]
        let name = entity.flatMap { $0.name.isEmpty ? nil : $0.name } ?? "Kinh doanh"
        return ReportsBusinessSlice(
            businessID: result.businessID,
            name: name,
            icon: entity?.icon ?? "",
            colorHex: entity?.colorHex ?? "8E8E93",
            revenue: result.revenue,
            cost: result.cost,
            profit: result.profit,
            margin: result.margin
        )
    }
}
