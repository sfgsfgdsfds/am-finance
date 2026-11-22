import Foundation

/// Monthly spending-limit ("hạn mức") math for expense categories.
///
/// A `BudgetLimit` caps how much may be spent in one calendar month —
/// either for one expense category, or for everything when its
/// `categoryID` is nil (the overall budget). `BudgetMath.evaluate`
/// measures the month containing a reference date against one limit;
/// `BudgetMath.summary` aggregates every limit into a sorted overview.
/// Both take an explicit `Calendar` — callers pass a Gregorian calendar
/// in the user's time zone (Asia/Ho_Chi_Minh); there is no global
/// default.
///
/// Spending is counted month-to-date: a spend counts when its calendar
/// day lies inside the month and not after the reference day. All
/// `Int64` arithmetic is checked — a total that does not fit throws
/// `BudgetError.overflow` instead of trapping.
public enum BudgetMath {

    /// Evaluates `limit` against `spends` for the calendar month
    /// containing `asOf`.
    ///
    /// A spend counts toward the limit when its calendar day is inside
    /// the month and not after `asOf`'s calendar day, and — for a
    /// category limit — its `categoryID` matches. A nil `categoryID` on
    /// the limit (the overall budget) counts every spend of the month.
    ///
    /// `warningThreshold` is the `spent / monthlyLimit` fraction at
    /// which the status turns `.warning`; it is clamped to 0...1 and
    /// defaults to 0.8.
    public static func evaluate(
        limit: BudgetLimit,
        spends: [BudgetSpend],
        asOf reference: Date,
        calendar: Calendar,
        warningThreshold: Double = 0.8
    ) throws -> BudgetProgress {
        let daysInMonth = calendar.range(of: .day, in: .month, for: reference)!.count
        let daysElapsed = calendar.component(.day, from: reference)
        let daysLeft = daysInMonth - daysElapsed

        var spent: Int64 = 0
        for spend in spends
        where counted(spend, by: limit, asOf: reference, calendar: calendar) {
            spent = try add(spent, spend.amount)
        }

        let remaining = try subtract(limit.monthlyLimit, spent)
        let fraction = Double(spent) / Double(limit.monthlyLimit)
        let threshold = min(1, max(0, warningThreshold))
        let status: BudgetStatus = spent > limit.monthlyLimit
            ? .exceeded
            : (fraction >= threshold ? .warning : .ok)

        let average = Double(spent) / Double(daysElapsed)
        let projected = saturatingInt64(average * Double(daysInMonth))
        let safeDaily = remaining > 0 ? remaining / Int64(max(1, daysLeft)) : 0

        return BudgetProgress(
            limit: limit,
            spent: spent,
            remaining: remaining,
            fractionUsed: fraction,
            status: status,
            daysElapsed: daysElapsed,
            daysLeft: daysLeft,
            averageDailySpend: average,
            projectedMonthEndSpend: projected,
            safeDailySpend: safeDaily,
            projectionExceedsLimit: projected > limit.monthlyLimit
        )
    }

    /// Evaluates every limit for the month containing `asOf` and
    /// aggregates the results.
    ///
    /// `rows` is sorted for display: `.exceeded` rows first, then
    /// `.warning`, then `.ok`, each group ordered by `fractionUsed`
    /// descending; equal keys keep the input order of `limits`.
    /// `totalLimit` sums the monthly limits; `totalSpent` sums every
    /// spend of the month, each counted once no matter how many limits
    /// it fed into.
    public static func summary(
        limits: [BudgetLimit],
        spends: [BudgetSpend],
        asOf reference: Date,
        calendar: Calendar,
        warningThreshold: Double = 0.8
    ) throws -> BudgetSummary {
        var rows: [BudgetProgress] = []
        rows.reserveCapacity(limits.count)
        var totalLimit: Int64 = 0
        var ok = 0
        var warning = 0
        var exceeded = 0
        for limit in limits {
            let row = try evaluate(
                limit: limit, spends: spends, asOf: reference,
                calendar: calendar, warningThreshold: warningThreshold)
            totalLimit = try add(totalLimit, limit.monthlyLimit)
            switch row.status {
            case .ok: ok += 1
            case .warning: warning += 1
            case .exceeded: exceeded += 1
            }
            rows.append(row)
        }

        var totalSpent: Int64 = 0
        for spend in spends
        where inMonthToDate(spend, asOf: reference, calendar: calendar) {
            totalSpent = try add(totalSpent, spend.amount)
        }

        let sorted = rows.enumerated()
            .sorted { lhs, rhs in
                let lRank = lhs.element.status.sortRank
                let rRank = rhs.element.status.sortRank
                if lRank != rRank { return lRank < rRank }
                if lhs.element.fractionUsed != rhs.element.fractionUsed {
                    return lhs.element.fractionUsed > rhs.element.fractionUsed
                }
                return lhs.offset < rhs.offset
            }
            .map(\.element)

        return BudgetSummary(
            rows: sorted,
            totalLimit: totalLimit,
            totalSpent: totalSpent,
            okCount: ok,
            warningCount: warning,
            exceededCount: exceeded
        )
    }

    // MARK: - Private

    /// A spend counts toward a limit when it is inside the
    /// month-to-date and either the limit is the overall one
    /// (`categoryID` nil) or the spend shares its category.
    private static func counted(_ spend: BudgetSpend, by limit: BudgetLimit,
                                asOf reference: Date, calendar: Calendar) -> Bool {
        inMonthToDate(spend, asOf: reference, calendar: calendar)
            && (limit.categoryID == nil || spend.categoryID == limit.categoryID)
    }

    /// Month-to-date membership: the spend's calendar day lies inside
    /// the month of `reference` and not after `reference`'s day.
    private static func inMonthToDate(_ spend: BudgetSpend, asOf reference: Date,
                                      calendar: Calendar) -> Bool {
        let spendDay = calendar.startOfDay(for: spend.date)
        return calendar.isDate(spendDay, equalTo: reference, toGranularity: .month)
            && spendDay <= calendar.startOfDay(for: reference)
    }

    private static func add(_ lhs: Int64, _ rhs: Int64) throws -> Int64 {
        let (result, overflow) = lhs.addingReportingOverflow(rhs)
        if overflow { throw BudgetError.overflow }
        return result
    }

    private static func subtract(_ lhs: Int64, _ rhs: Int64) throws -> Int64 {
        let (result, overflow) = lhs.subtractingReportingOverflow(rhs)
        if overflow { throw BudgetError.overflow }
        return result
    }

    /// Nearest whole đồng, saturated to the `Int64` range.
    private static func saturatingInt64(_ value: Double) -> Int64 {
        if value.isNaN { return 0 }
        if value >= Double(Int64.max) { return .max }
        if value <= Double(Int64.min) { return .min }
        return Int64(value.rounded())
    }
}

// MARK: - Supporting types

/// A monthly spending cap. `categoryID` nil means the overall monthly
/// budget, which counts every expense of the month.
public struct BudgetLimit: Equatable, Sendable {
    /// The expense category this cap watches; nil = overall budget.
    public let categoryID: UUID?
    /// Monthly cap in đồng — strictly positive.
    public let monthlyLimit: Int64

    public init(categoryID: UUID? = nil, monthlyLimit: Int64) throws {
        guard monthlyLimit > 0 else { throw BudgetError.nonPositiveLimit }
        self.categoryID = categoryID
        self.monthlyLimit = monthlyLimit
    }
}

/// One expense counted against budgets. `amount` is a positive đồng
/// magnitude; non-positive amounts are rejected at construction.
public struct BudgetSpend: Equatable, Sendable {
    /// The expense category; nil = uncategorized.
    public let categoryID: UUID?
    public let date: Date
    /// Expense amount in đồng — strictly positive.
    public let amount: Int64

    public init(categoryID: UUID? = nil, date: Date, amount: Int64) throws {
        guard amount > 0 else { throw BudgetError.nonPositiveAmount }
        self.categoryID = categoryID
        self.date = date
        self.amount = amount
    }
}

/// Health of a budget against its monthly limit.
public enum BudgetStatus: String, Equatable, Sendable, CaseIterable {
    /// Under the warning threshold.
    case ok
    /// At or over the warning threshold, but not over the limit.
    case warning
    /// Spent more than the monthly limit.
    case exceeded
}

/// One evaluated budget: a limit measured against the spends of a
/// calendar month. Built by `BudgetMath.evaluate`.
public struct BudgetProgress: Equatable, Sendable {
    /// The limit this row evaluates.
    public let limit: BudgetLimit
    /// Total spend of the month-to-date counted toward `limit` (đồng ≥ 0).
    public let spent: Int64
    /// `monthlyLimit - spent` — negative once the limit is passed.
    public let remaining: Int64
    /// `spent / monthlyLimit`; exceeds 1 when over budget.
    public let fractionUsed: Double
    /// Status against the warning threshold in effect.
    public let status: BudgetStatus
    /// Days of the month up to and including the reference day (≥ 1).
    public let daysElapsed: Int
    /// Days left in the month after the reference day — 0 on the last day.
    public let daysLeft: Int
    /// `spent / daysElapsed`.
    public let averageDailySpend: Double
    /// `averageDailySpend` × days in the month, rounded to whole đồng
    /// and saturated to the `Int64` range.
    public let projectedMonthEndSpend: Int64
    /// `remaining` split evenly over `daysLeft` (whole đồng, floored).
    /// On the last day of the month the whole `remaining` is safe for
    /// today; 0 when nothing remains.
    public let safeDailySpend: Int64
    /// `projectedMonthEndSpend > monthlyLimit`.
    public let projectionExceedsLimit: Bool

    public init(
        limit: BudgetLimit,
        spent: Int64,
        remaining: Int64,
        fractionUsed: Double,
        status: BudgetStatus,
        daysElapsed: Int,
        daysLeft: Int,
        averageDailySpend: Double,
        projectedMonthEndSpend: Int64,
        safeDailySpend: Int64,
        projectionExceedsLimit: Bool
    ) {
        self.limit = limit
        self.spent = spent
        self.remaining = remaining
        self.fractionUsed = fractionUsed
        self.status = status
        self.daysElapsed = daysElapsed
        self.daysLeft = daysLeft
        self.averageDailySpend = averageDailySpend
        self.projectedMonthEndSpend = projectedMonthEndSpend
        self.safeDailySpend = safeDailySpend
        self.projectionExceedsLimit = projectionExceedsLimit
    }

    /// Vietnamese one-liner describing the row, e.g.
    /// "Còn 1.200.000 ₫ cho 12 ngày" or "Vượt 350.000 ₫".
    public var message: String {
        if status == .exceeded {
            return "Vượt \(VND.format(overshoot))"
        }
        if remaining <= 0 { return "Đã hết hạn mức" }
        if daysLeft == 0 { return "Còn \(VND.format(remaining)) cho hôm nay" }
        return "Còn \(VND.format(remaining)) cho \(daysLeft) ngày"
    }

    /// Amount spent beyond the limit (0 when inside it).
    private var overshoot: Int64 {
        remaining == .min ? .max : max(0, -remaining)
    }
}

/// Aggregated view of every limit for one month, built by
/// `BudgetMath.summary`.
public struct BudgetSummary: Equatable, Sendable {
    /// Per-limit evaluations, sorted `.exceeded` first, then `.warning`,
    /// then `.ok` — each group by `fractionUsed` descending.
    public let rows: [BudgetProgress]
    /// Sum of every limit's `monthlyLimit` (đồng).
    public let totalLimit: Int64
    /// Sum of every spend in the month, each counted once (đồng) —
    /// independent of how many limits each spend was counted under.
    public let totalSpent: Int64
    public let okCount: Int
    public let warningCount: Int
    public let exceededCount: Int

    public init(
        rows: [BudgetProgress],
        totalLimit: Int64,
        totalSpent: Int64,
        okCount: Int,
        warningCount: Int,
        exceededCount: Int
    ) {
        self.rows = rows
        self.totalLimit = totalLimit
        self.totalSpent = totalSpent
        self.okCount = okCount
        self.warningCount = warningCount
        self.exceededCount = exceededCount
    }
}

/// Errors thrown by `BudgetMath` and the budget value types; integer
/// overflow is reported, never trapped.
public enum BudgetError: Error, Equatable, Sendable {
    /// `BudgetLimit.monthlyLimit` was not positive.
    case nonPositiveLimit
    /// `BudgetSpend.amount` was not positive.
    case nonPositiveAmount
    /// A spend or limit total did not fit in `Int64`.
    case overflow
}

extension BudgetError: LocalizedError {
    public var errorDescription: String? {
        switch self {
        case .nonPositiveLimit: return "Hạn mức phải lớn hơn 0."
        case .nonPositiveAmount: return "Số tiền chi phải lớn hơn 0."
        case .overflow: return "Số liệu vượt quá giới hạn tính toán."
        }
    }
}

extension BudgetStatus {
    /// Summary sort order: exceeded rows first, then warning, then ok.
    fileprivate var sortRank: Int {
        switch self {
        case .exceeded: return 0
        case .warning: return 1
        case .ok: return 2
        }
    }
}
