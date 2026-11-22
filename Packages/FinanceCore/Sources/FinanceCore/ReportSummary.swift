import Foundation

/// Reporting and aggregation over ledger entries, feeding the dashboard,
/// the reports tab and the per-business profit-and-loss views.
///
/// Conventions:
/// - Money is Int64 đồng. **All sums saturate at Int64.min/.max rather
///   than trapping** — reporting must never crash on extreme values.
/// - Intervals are half-open [start, end): an entry exactly at `start`
///   is in, an entry exactly at `end` is out.
/// - Transfers never count as income, expense, or entry count.
/// - Every calendar-aware function takes an explicit `Calendar` —
///   callers pass a Gregorian calendar in the user's time zone
///   (Asia/Ho_Chi_Minh); there is no global default.
/// - Orderings are deterministic: ties are broken by UUID string, with
///   "uncategorized" (nil) sorting last, so results do not depend on
///   dictionary iteration order.
public enum ReportSummary {

    // MARK: - Totals

    /// Income, expense, net and count over `interval`, restricted to
    /// `scope`. Transfers are ignored entirely.
    public static func totals(entries: [ReportEntry],
                              in interval: ReportDateInterval,
                              scope: ReportScope = .all) -> ReportTotals {
        var income: Int64 = 0
        var expense: Int64 = 0
        var count = 0
        for entry in entries where interval.contains(entry.date) && matches(entry, scope) {
            switch entry.kind {
            case .income:
                income = saturatingAdd(income, entry.amount)
            case .expense:
                expense = saturatingAdd(expense, entry.amount)
            case .transfer:
                continue
            }
            count += 1
        }
        return ReportTotals(income: income, expense: expense, count: count)
    }

    /// `totals` split by ownership: entries with `businessID == nil`
    /// (personal) vs `businessID != nil` (all businesses combined).
    public static func splitByOwnership(entries: [ReportEntry],
                                        in interval: ReportDateInterval) -> ReportSplit {
        ReportSplit(
            personal: totals(entries: entries, in: interval, scope: .personal),
            business: totals(entries: entries, in: interval, scope: .anyBusiness)
        )
    }

    // MARK: - Categories

    /// Per-category totals for `kind` inside `interval`: one row per
    /// distinct `categoryID` (nil = uncategorized), sorted by `total`
    /// descending. Ties sort uncategorized last, then by UUID string
    /// ascending — a deterministic order independent of input order.
    ///
    /// `share` is the row's fraction of the grand total for `kind`
    /// (0 when that total is 0).
    public static func byCategory(entries: [ReportEntry],
                                  in interval: ReportDateInterval,
                                  kind: TransactionKind,
                                  scope: ReportScope = .all) -> [ReportCategoryRow] {
        var grouped: [UUID?: (total: Int64, count: Int)] = [:]
        var kindTotal: Int64 = 0
        for entry in entries
        where entry.kind == kind && interval.contains(entry.date) && matches(entry, scope) {
            var bucket = grouped[entry.categoryID] ?? (0, 0)
            bucket.total = saturatingAdd(bucket.total, entry.amount)
            bucket.count += 1
            grouped[entry.categoryID] = bucket
            kindTotal = saturatingAdd(kindTotal, entry.amount)
        }
        return grouped.map { categoryID, bucket in
            ReportCategoryRow(
                categoryID: categoryID,
                total: bucket.total,
                count: bucket.count,
                share: kindTotal > 0 ? Double(bucket.total) / Double(kindTotal) : 0
            )
        }.sorted { lhs, rhs in
            guard lhs.total == rhs.total else { return lhs.total > rhs.total }
            switch (lhs.categoryID, rhs.categoryID) {
            case (nil, nil): return false
            case (nil, _?): return false          // uncategorized last on ties
            case (_?, nil): return true
            case let (l?, r?): return l.uuidString < r.uuidString
            }
        }
    }

    /// Top-`limit` variant of `byCategory`: rows past the first
    /// `max(0, limit)` are folded into a single trailing row with
    /// `isOther == true` (its `categoryID` stays nil). When there are
    /// at most `limit` rows the result is identical to `byCategory`.
    public static func topCategories(entries: [ReportEntry],
                                     in interval: ReportDateInterval,
                                     kind: TransactionKind,
                                     limit: Int,
                                     scope: ReportScope = .all) -> [ReportCategoryRow] {
        let rows = byCategory(entries: entries, in: interval, kind: kind, scope: scope)
        let kept = max(0, limit)
        guard rows.count > kept else { return rows }
        var restTotal: Int64 = 0
        var restCount = 0
        for row in rows.dropFirst(kept) {
            restTotal = saturatingAdd(restTotal, row.total)
            restCount += row.count
        }
        let kindTotal = rows.reduce(Int64(0)) { saturatingAdd($0, $1.total) }
        return Array(rows.prefix(kept)) + [
            ReportCategoryRow(
                categoryID: nil,
                total: restTotal,
                count: restCount,
                share: kindTotal > 0 ? Double(restTotal) / Double(kindTotal) : 0,
                isOther: true
            )
        ]
    }

    // MARK: - Business profit & loss

    /// Profit-and-loss per business inside `interval`: revenue (income),
    /// cost (expense), profit (revenue - cost) and margin
    /// (profit / revenue, 0 when revenue is 0). Only entries with a
    /// non-nil `businessID` count; transfers are ignored. Sorted by
    /// profit descending, ties by UUID string ascending.
    public static func byBusiness(entries: [ReportEntry],
                                  in interval: ReportDateInterval) -> [ReportBusinessResult] {
        var revenue: [UUID: Int64] = [:]
        var cost: [UUID: Int64] = [:]
        for entry in entries where interval.contains(entry.date) {
            guard let id = entry.businessID else { continue }
            switch entry.kind {
            case .income:
                revenue[id] = saturatingAdd(revenue[id] ?? 0, entry.amount)
            case .expense:
                cost[id] = saturatingAdd(cost[id] ?? 0, entry.amount)
            case .transfer:
                continue
            }
        }
        return Set(revenue.keys).union(cost.keys).map { id in
            ReportBusinessResult(businessID: id,
                                 revenue: revenue[id] ?? 0,
                                 cost: cost[id] ?? 0)
        }.sorted { lhs, rhs in
            lhs.profit != rhs.profit
                ? lhs.profit > rhs.profit
                : lhs.businessID.uuidString < rhs.businessID.uuidString
        }
    }

    // MARK: - Calendar series

    /// The half-open interval covering the whole calendar month
    /// containing `date`: the 1st at 00:00 local through the 1st of the
    /// next month at 00:00 local.
    public static func monthInterval(containing date: Date,
                                     calendar: Calendar) -> ReportDateInterval {
        var comps = calendar.dateComponents([.year, .month], from: date)
        comps.day = 1
        let start = calendar.date(from: comps)!
        let end = calendar.date(byAdding: .month, value: 1, to: start)!
        return ReportDateInterval(start: start, end: end)
    }

    /// The last `months` calendar months ending with the month
    /// containing `reference`, oldest first. Months without entries are
    /// present with zeros. `scope` filters to one business or to
    /// personal (nil businessID) entries.
    public static func monthly(entries: [ReportEntry],
                               months: Int,
                               endingAt reference: Date,
                               calendar: Calendar,
                               scope: ReportScope = .all) -> [ReportMonthPoint] {
        guard months > 0 else { return [] }
        let lastStart = monthInterval(containing: reference, calendar: calendar).start
        return (0..<months).map { index in
            let start = calendar.date(byAdding: .month,
                                      value: index - (months - 1),
                                      to: lastStart)!
            let end = calendar.date(byAdding: .month, value: 1, to: start)!
            var income: Int64 = 0
            var expense: Int64 = 0
            for entry in entries
            where entry.date >= start && entry.date < end && matches(entry, scope) {
                switch entry.kind {
                case .income: income = saturatingAdd(income, entry.amount)
                case .expense: expense = saturatingAdd(expense, entry.amount)
                case .transfer: continue
                }
            }
            return ReportMonthPoint(monthStart: start, income: income, expense: expense)
        }
    }

    /// Income and expense per calendar day of the month containing
    /// `date`, one point per day (28-31 points), zero-filled, each
    /// point's `date` the start of that day in `calendar`.
    public static func daily(entries: [ReportEntry],
                             inMonthContaining date: Date,
                             calendar: Calendar,
                             scope: ReportScope = .all) -> [ReportDayPoint] {
        let month = monthInterval(containing: date, calendar: calendar)
        let dayCount = calendar.dateComponents([.day], from: month.start, to: month.end).day!
        var income = [Int64](repeating: 0, count: dayCount)
        var expense = [Int64](repeating: 0, count: dayCount)
        for entry in entries
        where month.contains(entry.date) && matches(entry, scope) {
            let day = calendar.startOfDay(for: entry.date)
            guard let index = calendar.dateComponents([.day], from: month.start, to: day).day,
                  index >= 0, index < dayCount else { continue }
            switch entry.kind {
            case .income: income[index] = saturatingAdd(income[index], entry.amount)
            case .expense: expense[index] = saturatingAdd(expense[index], entry.amount)
            case .transfer: continue
            }
        }
        return (0..<dayCount).map { index in
            ReportDayPoint(
                date: calendar.date(byAdding: .day, value: index, to: month.start)!,
                income: income[index],
                expense: expense[index]
            )
        }
    }

    // MARK: - Period comparison

    /// Totals for `interval` compared against the equal-length interval
    /// immediately before it ([start - length, start)). Percent changes
    /// are nil wherever the previous value is 0.
    public static func comparison(entries: [ReportEntry],
                                  in interval: ReportDateInterval,
                                  scope: ReportScope = .all) -> ReportComparison {
        let current = totals(entries: entries, in: interval, scope: scope)
        let previous = totals(entries: entries, in: interval.previous, scope: scope)
        return ReportComparison(
            current: current,
            previous: previous,
            income: ReportChange(current: current.income, previous: previous.income),
            expense: ReportChange(current: current.expense, previous: previous.expense),
            net: ReportChange(current: current.net, previous: previous.net),
            count: ReportChange(current: Int64(current.count), previous: Int64(previous.count))
        )
    }

    // MARK: - Private helpers

    private static func matches(_ entry: ReportEntry, _ scope: ReportScope) -> Bool {
        switch scope {
        case .all: return true
        case .personal: return entry.businessID == nil
        case .anyBusiness: return entry.businessID != nil
        case .business(let id): return entry.businessID == id
        }
    }

    private static func saturatingAdd(_ a: Int64, _ b: Int64) -> Int64 {
        let (result, overflow) = a.addingReportingOverflow(b)
        return overflow ? (a < 0 ? .min : .max) : result
    }
}

// MARK: - Input

/// One dated movement eligible for reporting. `amount` is a magnitude
/// in đồng — negative values are clamped to 0 so totals keep their
/// ≥ 0 invariants. `categoryID == nil` means uncategorized;
/// `businessID == nil` means personal.
public struct ReportEntry: Equatable, Sendable {
    public let date: Date
    public let kind: TransactionKind
    public let amount: Int64
    public let categoryID: UUID?
    public let businessID: UUID?

    public init(date: Date, kind: TransactionKind, amount: Int64,
                categoryID: UUID? = nil, businessID: UUID? = nil) {
        self.date = date
        self.kind = kind
        self.amount = max(0, amount)
        self.categoryID = categoryID
        self.businessID = businessID
    }
}

/// Which entries a report covers.
public enum ReportScope: Equatable, Sendable {
    /// Every entry.
    case all
    /// Only entries with `businessID == nil`.
    case personal
    /// Only entries with `businessID != nil`, all businesses combined.
    case anyBusiness
    /// Only entries for this one `businessID`.
    case business(UUID)
}

/// A half-open date interval [start, end). Callers must pass
/// `start <= end`; an empty interval matches nothing.
public struct ReportDateInterval: Equatable, Sendable {
    /// Inclusive lower bound.
    public let start: Date
    /// Exclusive upper bound.
    public let end: Date

    public init(start: Date, end: Date) {
        self.start = start
        self.end = end
    }

    public func contains(_ date: Date) -> Bool {
        date >= start && date < end
    }

    /// `end - start` in seconds.
    public var length: TimeInterval {
        end.timeIntervalSince(start)
    }

    /// The equal-length interval immediately before this one.
    public var previous: ReportDateInterval {
        ReportDateInterval(start: start.addingTimeInterval(-length), end: start)
    }

    /// The equal-length interval immediately after this one.
    public var next: ReportDateInterval {
        ReportDateInterval(start: end, end: end.addingTimeInterval(length))
    }
}

// MARK: - Results

/// Income, expense and count totals for a set of entries.
public struct ReportTotals: Equatable, Sendable {
    /// Income entries summed, đồng ≥ 0 (saturated).
    public let income: Int64
    /// Expense entries summed, đồng ≥ 0 (saturated).
    public let expense: Int64
    /// Number of income/expense entries counted — transfers excluded.
    public let count: Int

    public init(income: Int64, expense: Int64, count: Int) {
        self.income = income
        self.expense = expense
        self.count = count
    }

    /// `income - expense`, saturating (negative means net spending).
    public var net: Int64 {
        let (result, overflow) = income.subtractingReportingOverflow(expense)
        return overflow ? (income < 0 ? .min : .max) : result
    }

    public static let zero = ReportTotals(income: 0, expense: 0, count: 0)
}

/// Totals split by ownership.
public struct ReportSplit: Equatable, Sendable {
    /// Entries with `businessID == nil`.
    public let personal: ReportTotals
    /// Entries with `businessID != nil`, all businesses combined.
    public let business: ReportTotals

    public init(personal: ReportTotals, business: ReportTotals) {
        self.personal = personal
        self.business = business
    }
}

/// One row of a category breakdown.
public struct ReportCategoryRow: Equatable, Sendable {
    /// `nil` = uncategorized. On the folded "other" row produced by
    /// `topCategories` this is also nil — `isOther` distinguishes it.
    public let categoryID: UUID?
    /// Total đồng for the category, ≥ 0 (saturated).
    public let total: Int64
    /// Entries counted.
    public let count: Int
    /// Fraction of the kind's grand total (0 when that total is 0).
    public let share: Double
    /// True only for the aggregated "other" row from `topCategories`.
    public let isOther: Bool

    public init(categoryID: UUID?, total: Int64, count: Int,
                share: Double, isOther: Bool = false) {
        self.categoryID = categoryID
        self.total = total
        self.count = count
        self.share = share
        self.isOther = isOther
    }
}

/// Profit and loss for one business.
public struct ReportBusinessResult: Equatable, Sendable {
    public let businessID: UUID
    /// Income entries summed, đồng ≥ 0 (saturated).
    public let revenue: Int64
    /// Expense entries summed, đồng ≥ 0 (saturated).
    public let cost: Int64
    /// `revenue - cost`, saturating; negative means a loss.
    public let profit: Int64
    /// `profit / revenue`; 0 when revenue is 0.
    public let margin: Double

    public init(businessID: UUID, revenue: Int64, cost: Int64) {
        self.businessID = businessID
        self.revenue = revenue
        self.cost = cost
        let (p, overflow) = revenue.subtractingReportingOverflow(cost)
        self.profit = overflow ? (revenue < 0 ? .min : .max) : p
        self.margin = revenue > 0 ? Double(profit) / Double(revenue) : 0
    }
}

/// One month of a monthly series.
public struct ReportMonthPoint: Equatable, Sendable {
    /// The 1st of the month at 00:00 in the calendar that produced it.
    public let monthStart: Date
    public let income: Int64
    public let expense: Int64

    public init(monthStart: Date, income: Int64, expense: Int64) {
        self.monthStart = monthStart
        self.income = income
        self.expense = expense
    }

    /// `income - expense`, saturating.
    public var net: Int64 {
        let (result, overflow) = income.subtractingReportingOverflow(expense)
        return overflow ? (income < 0 ? .min : .max) : result
    }
}

/// One day of a daily series.
public struct ReportDayPoint: Equatable, Sendable {
    /// Start of the day in the calendar that produced it.
    public let date: Date
    public let income: Int64
    public let expense: Int64

    public init(date: Date, income: Int64, expense: Int64) {
        self.date = date
        self.income = income
        self.expense = expense
    }

    /// `income - expense`, saturating.
    public var net: Int64 {
        let (result, overflow) = income.subtractingReportingOverflow(expense)
        return overflow ? (income < 0 ? .min : .max) : result
    }
}

/// Change between a current and a previous value.
public struct ReportChange: Equatable, Sendable {
    /// `current - previous`, saturating.
    public let delta: Int64
    /// `delta / previous` as a fraction (0.25 = +25%); nil when
    /// `previous` is 0.
    public let percent: Double?

    public init(current: Int64, previous: Int64) {
        let (d, overflow) = current.subtractingReportingOverflow(previous)
        self.delta = overflow ? (current < 0 ? .min : .max) : d
        self.percent = previous == 0 ? nil : Double(delta) / Double(previous)
    }
}

/// Current-vs-previous comparison of an interval against the
/// equal-length interval immediately before it.
public struct ReportComparison: Equatable, Sendable {
    public let current: ReportTotals
    public let previous: ReportTotals
    public let income: ReportChange
    public let expense: ReportChange
    public let net: ReportChange
    public let count: ReportChange

    public init(current: ReportTotals, previous: ReportTotals,
                income: ReportChange, expense: ReportChange,
                net: ReportChange, count: ReportChange) {
        self.current = current
        self.previous = previous
        self.income = income
        self.expense = expense
        self.net = net
        self.count = count
    }
}
