import Foundation
import FinanceCore

/// Everything the budgets screen and the dashboard summary card render,
/// computed once per render from lightweight inputs — stored limits, the
/// month's expenses and category styling — so all evaluation is testable
/// without SwiftData or SwiftUI.
///
/// Per-limit math comes from `BudgetMath` (FinanceCore); this type only
/// decides which spends each limit sees: the overall budget
/// (`categoryID == nil`) counts personal expenses only (spends with
/// `isBusiness == false`), while a category budget counts every expense
/// of its category, business ones included.
struct BudgetsSnapshot: Equatable {

    // MARK: - Inputs

    /// One stored `Budget`, flattened. `categoryID == nil` is the overall
    /// personal budget.
    struct LimitInput: Equatable, Sendable {
        var id: UUID
        var categoryID: UUID?
        /// Monthly cap in đồng; non-positive limits are skipped.
        var monthlyLimit: Int64
        var isActive: Bool
        var note: String

        init(id: UUID, categoryID: UUID? = nil, monthlyLimit: Int64,
             isActive: Bool = true, note: String = "") {
            self.id = id
            self.categoryID = categoryID
            self.monthlyLimit = monthlyLimit
            self.isActive = isActive
            self.note = note
        }
    }

    /// One expense of the fetched window — `amount` a đồng magnitude,
    /// `isBusiness` the transaction's `business != nil`. Pass expenses
    /// only: income and transfers never count against budgets.
    struct SpendInput: Equatable, Sendable {
        var categoryID: UUID?
        var date: Date
        var amount: Int64
        var isBusiness: Bool

        init(categoryID: UUID? = nil, date: Date, amount: Int64,
             isBusiness: Bool = false) {
            self.categoryID = categoryID
            self.date = date
            self.amount = amount
            self.isBusiness = isBusiness
        }
    }

    /// Name/icon/color styling for a category, looked up by id so the
    /// snapshot never touches SwiftData models.
    struct Visual: Equatable, Sendable {
        var name: String = ""
        var icon: String = ""
        var colorHex: String = ""

        init(name: String = "", icon: String = "", colorHex: String = "") {
            self.name = name
            self.icon = icon
            self.colorHex = colorHex
        }
    }

    // MARK: - Outputs

    /// One rendered row: the limit's identity and styling plus the
    /// `BudgetProgress` `BudgetMath.evaluate` computed for it.
    struct Row: Equatable, Identifiable, Sendable {
        /// Id of the backing `Budget` — used to open the editor.
        var budgetID: UUID
        /// nil = the overall personal budget.
        var categoryID: UUID?
        var name: String
        var icon: String
        var colorHex: String
        var note: String
        var progress: BudgetProgress

        var id: UUID { budgetID }
        var isOverall: Bool { categoryID == nil }
    }

    /// "Tháng 11/2026" — the displayed month.
    let monthTitle: String
    /// True when `month` is the calendar month containing `now`; other
    /// months are evaluated over their whole span.
    let isCurrentMonth: Bool
    /// The overall personal budget (`categoryID == nil`) — pinned on top.
    let overall: Row?
    /// Category rows: `.exceeded` first, then `.warning`, then `.ok`, each
    /// group by `fractionUsed` descending, ties in input order.
    let categories: [Row]
    /// Sum of every active `monthlyLimit` (đồng, saturated).
    let totalLimit: Int64
    /// Every expense inside the evaluated window, each counted once —
    /// the month's real total spend, independent of budget scoping.
    let totalSpent: Int64
    let okCount: Int
    let warningCount: Int
    let exceededCount: Int

    /// No active budget to display (inactive or invalid limits excluded).
    var isEmpty: Bool { overall == nil && categories.isEmpty }

    // MARK: - Builder

    /// Builds the snapshot for the calendar month containing `month`.
    ///
    /// The evaluation reference is `now` inside the current month
    /// (month-to-date); for past or future months it is the month's last
    /// day so the whole month counts. Inactive limits, non-positive
    /// limits and non-positive spend amounts are skipped.
    static func make(
        limits: [LimitInput],
        spends: [SpendInput],
        categories: [UUID: Visual],
        month: Date,
        now: Date,
        calendar: Calendar
    ) -> BudgetsSnapshot {
        let interval = ReportSummary.monthInterval(
            containing: month, calendar: calendar)
        let isCurrent = interval.contains(now)
        let reference = isCurrent
            ? now
            : (calendar.date(byAdding: .day, value: -1, to: interval.end)
                ?? interval.start)

        var overall: Row?
        var categoryRows: [(row: Row, order: Int)] = []
        var totalLimit: Int64 = 0
        var ok = 0
        var warning = 0
        var exceeded = 0

        for (order, input) in limits.enumerated()
        where input.isActive && input.monthlyLimit > 0 {
            guard let limit = try? BudgetLimit(
                categoryID: input.categoryID, monthlyLimit: input.monthlyLimit
            ) else { continue }

            // The overall budget counts personal expenses only; a
            // category budget counts every expense of its category.
            let relevant = spends
                .filter {
                    input.categoryID == nil
                        ? !$0.isBusiness
                        : $0.categoryID == input.categoryID
                }
                .compactMap {
                    try? BudgetSpend(
                        categoryID: $0.categoryID, date: $0.date,
                        amount: $0.amount)
                }
            guard let progress = try? BudgetMath.evaluate(
                limit: limit, spends: relevant,
                asOf: reference, calendar: calendar
            ) else { continue }

            let visual = input.categoryID
                .flatMap { categories[$0] }
                ?? (input.categoryID == nil ? .overall : .missingCategory)
            let row = Row(
                budgetID: input.id,
                categoryID: input.categoryID,
                name: visual.name,
                icon: visual.icon,
                colorHex: visual.colorHex,
                note: input.note,
                progress: progress
            )

            switch progress.status {
            case .ok: ok += 1
            case .warning: warning += 1
            case .exceeded: exceeded += 1
            }
            totalLimit = saturatingAdd(totalLimit, input.monthlyLimit)

            // Only the first nil-category limit reads as the overall
            // budget — the form never offers a second one.
            if input.categoryID == nil {
                if overall == nil { overall = row }
            } else {
                categoryRows.append((row, order))
            }
        }

        categoryRows.sort {
            let lRank = sortRank(of: $0.row.progress.status)
            let rRank = sortRank(of: $1.row.progress.status)
            if lRank != rRank { return lRank < rRank }
            if $0.row.progress.fractionUsed != $1.row.progress.fractionUsed {
                return $0.row.progress.fractionUsed > $1.row.progress.fractionUsed
            }
            return $0.order < $1.order
        }

        var totalSpent: Int64 = 0
        for spend in spends
        where inMonthToDate(spend, asOf: reference, calendar: calendar) {
            totalSpent = saturatingAdd(totalSpent, max(0, spend.amount))
        }

        return BudgetsSnapshot(
            monthTitle: AppDateFormat.monthTitle(interval.start, calendar: calendar),
            isCurrentMonth: isCurrent,
            overall: overall,
            categories: categoryRows.map(\.row),
            totalLimit: totalLimit,
            totalSpent: totalSpent,
            okCount: ok,
            warningCount: warning,
            exceededCount: exceeded
        )
    }

    // MARK: - Private

    /// Same order as `BudgetMath.summary`: exceeded first, then warning,
    /// then ok.
    private static func sortRank(of status: BudgetStatus) -> Int {
        switch status {
        case .exceeded: return 0
        case .warning: return 1
        case .ok: return 2
        }
    }

    /// Month-to-date membership — mirrors `BudgetMath`'s window: the
    /// spend's calendar day lies inside `reference`'s month and not
    /// after `reference`'s day.
    private static func inMonthToDate(
        _ spend: SpendInput, asOf reference: Date, calendar: Calendar
    ) -> Bool {
        let spendDay = calendar.startOfDay(for: spend.date)
        return calendar.isDate(spendDay, equalTo: reference, toGranularity: .month)
            && spendDay <= calendar.startOfDay(for: reference)
    }

    private static func saturatingAdd(_ a: Int64, _ b: Int64) -> Int64 {
        let (result, overflow) = a.addingReportingOverflow(b)
        return overflow ? (a < 0 ? .min : .max) : result
    }
}

extension BudgetsSnapshot.Visual {
    /// Fixed styling of the overall personal budget row.
    static let overall = BudgetsSnapshot.Visual(
        name: "Ngân sách chi tiêu cá nhân",
        icon: "person.fill",
        colorHex: "0A84FF"
    )
    /// Fallback for a budget whose category can no longer be resolved.
    static let missingCategory = BudgetsSnapshot.Visual(
        name: "Danh mục đã xoá",
        icon: "tag.fill",
        colorHex: "8E8E93"
    )
}
