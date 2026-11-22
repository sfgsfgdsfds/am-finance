import Foundation
import FinanceCore

/// The "Trung bình 3 tháng gần nhất" suggestion on the budget form: the
/// average monthly expense over the `months` complete calendar months
/// preceding the displayed month, rounded to the nearest `rounding`
/// đồng (10.000 ₫ by default). Months without matching spends count as
/// 0; `nil` means there is nothing to suggest and the chip stays hidden.
enum BudgetsSuggestion {

    /// Which spends feed the average — mirrors the counting rule of the
    /// budget being created.
    enum Scope: Equatable, Sendable {
        /// The overall personal budget: spends with `isBusiness == false`.
        case personal
        /// A category budget: every spend of that category.
        case category(UUID)
    }

    /// Average monthly spend in the `months` calendar months immediately
    /// preceding the month containing `forMonth`, rounded to the nearest
    /// `rounding` đồng (half-up). Returns nil when the total or the
    /// rounded result is not positive.
    static func monthlyAverage(
        spends: [BudgetsSnapshot.SpendInput],
        scope: Scope,
        forMonth month: Date,
        calendar: Calendar,
        months: Int = 3,
        rounding: Int64 = 10_000
    ) -> Int64? {
        guard months > 0, rounding > 0 else { return nil }
        let monthStart = ReportSummary.monthInterval(
            containing: month, calendar: calendar).start
        let windowStart = calendar.date(
            byAdding: .month, value: -months, to: monthStart) ?? monthStart

        var total: Int64 = 0
        for spend in spends
        where spend.date >= windowStart && spend.date < monthStart
            && spend.amount > 0 && matches(spend, scope: scope) {
            let (sum, overflow) = total.addingReportingOverflow(spend.amount)
            total = overflow ? .max : sum
            if overflow { break }
        }
        guard total > 0 else { return nil }

        let units = (Double(total) / Double(months) / Double(rounding)).rounded()
        guard units > 0, units <= Double(Int64.max / rounding) else { return nil }
        return Int64(units) * rounding
    }

    private static func matches(
        _ spend: BudgetsSnapshot.SpendInput, scope: Scope
    ) -> Bool {
        switch scope {
        case .personal: return !spend.isBusiness
        case .category(let id): return spend.categoryID == id
        }
    }
}
