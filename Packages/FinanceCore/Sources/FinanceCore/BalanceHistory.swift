import Foundation

/// Balance-over-time reconstruction for an account whose transaction feed
/// does not carry balances. The caller supplies one trusted figure — either
/// an opening balance before the first known entry, or an anchor balance at
/// a known instant — and every other balance is derived from the signed
/// entry deltas (đồng; positive = money in, negative = money out).
///
/// All arithmetic is checked: a value that does not fit in `Int64`
/// throws `BalanceHistoryError.overflow` instead of trapping.
public enum BalanceHistory {

    // MARK: - Running series

    /// Running balance after each entry, sorted stably by date (entries
    /// sharing a timestamp keep their input order).
    ///
    /// With `.opening` the balance before the first entry is the given
    /// opening balance. With `.anchor` points after the anchor instant are
    /// derived forwards and points before it backwards, so an entry dated
    /// exactly at the anchor instant lands on the anchor balance.
    public static func series(
        entries: [BalanceHistoryEntry],
        basis: BalanceHistoryBasis
    ) throws -> [BalanceHistoryPoint] {
        let sorted = stableSort(entries)
        var balance = try balanceBeforeAllEntries(sortedEntries: sorted, basis: basis)
        var points: [BalanceHistoryPoint] = []
        points.reserveCapacity(sorted.count)
        for entry in sorted {
            balance = try add(balance, entry.delta)
            points.append(BalanceHistoryPoint(date: entry.date, balance: balance))
        }
        return points
    }

    /// Mode A: running balances from an opening balance before the first entry.
    public static func series(
        entries: [BalanceHistoryEntry],
        openingBalance: Int64
    ) throws -> [BalanceHistoryPoint] {
        try series(entries: entries, basis: .opening(openingBalance))
    }

    /// Mode B: running balances derived from a known balance at a known instant.
    public static func series(
        entries: [BalanceHistoryEntry],
        anchor: BalanceHistoryAnchor
    ) throws -> [BalanceHistoryPoint] {
        try series(entries: entries, basis: .anchor(anchor))
    }

    // MARK: - Daily series

    /// Closing balance for each calendar day in the closed range
    /// `start...end`. The range is expanded to whole calendar days in
    /// `calendar`: the first point is the close of the day containing
    /// `start`, the last the close of the day containing `end`. Each point's
    /// `date` is the start of its day in `calendar`.
    ///
    /// Days without entries carry the previous closing balance forward;
    /// days before the first known entry use the value derived from `basis`.
    public static func dailyBalances(
        entries: [BalanceHistoryEntry],
        from start: Date,
        to end: Date,
        basis: BalanceHistoryBasis,
        calendar: Calendar
    ) throws -> [BalanceHistoryPoint] {
        let firstDay = calendar.startOfDay(for: start)
        let lastDay = calendar.startOfDay(for: end)
        guard firstDay <= lastDay else { throw BalanceHistoryError.invalidRange }

        let sorted = stableSort(entries)
        var balance = try balanceBeforeAllEntries(sortedEntries: sorted, basis: basis)
        var points: [BalanceHistoryPoint] = []
        var day = firstDay
        var index = 0
        while day <= lastDay {
            guard let nextDay = calendar.date(byAdding: .day, value: 1, to: day),
                  nextDay > day else { throw BalanceHistoryError.invalidRange }
            // Close of this day = balance after every entry before tomorrow.
            while index < sorted.count, sorted[index].date < nextDay {
                balance = try add(balance, sorted[index].delta)
                index += 1
            }
            points.append(BalanceHistoryPoint(date: day, balance: balance))
            day = nextDay
        }
        return points
    }

    // MARK: - Summary

    /// Aggregates the closed instant range `start...end`: entries dated
    /// exactly at `start` or `end` count as inside the range.
    public static func summary(
        entries: [BalanceHistoryEntry],
        from start: Date,
        to end: Date,
        basis: BalanceHistoryBasis
    ) throws -> BalanceHistorySummary {
        guard start <= end else { throw BalanceHistoryError.invalidRange }
        let sorted = stableSort(entries)
        var balance = try balanceBeforeAllEntries(sortedEntries: sorted, basis: basis)

        var index = 0
        while index < sorted.count, sorted[index].date < start {
            balance = try add(balance, sorted[index].delta)
            index += 1
        }
        let opening = balance
        var totalIn: Int64 = 0
        var totalOut: Int64 = 0
        var minimum = BalanceHistoryPoint(date: start, balance: opening)
        var maximum = minimum

        while index < sorted.count, sorted[index].date <= end {
            let entry = sorted[index]
            balance = try add(balance, entry.delta)
            if entry.delta > 0 { totalIn = try add(totalIn, entry.delta) }
            else if entry.delta < 0 { totalOut = try subtract(totalOut, entry.delta) }
            if balance < minimum.balance {
                minimum = BalanceHistoryPoint(date: entry.date, balance: balance)
            }
            if balance > maximum.balance {
                maximum = BalanceHistoryPoint(date: entry.date, balance: balance)
            }
            index += 1
        }

        return BalanceHistorySummary(
            opening: opening,
            closing: balance,
            totalIn: totalIn,
            totalOut: totalOut,
            netChange: try subtract(totalIn, totalOut),
            minimum: minimum,
            maximum: maximum
        )
    }

    // MARK: - Downsample

    /// Keeps at most `maxCount` points for charting. The first point, last
    /// point, and the points with the minimum and maximum balance are always
    /// kept (in that priority order when `maxCount` is smaller than the
    /// number of preserved points); the rest is filled with evenly spaced
    /// samples. Result stays in chronological order.
    public static func downsample(
        _ points: [BalanceHistoryPoint],
        maxCount: Int
    ) -> [BalanceHistoryPoint] {
        let count = points.count
        guard maxCount > 0 else { return [] }
        guard count > maxCount else { return points }

        var minIndex = 0
        var maxIndex = 0
        for i in points.indices {
            if points[i].balance < points[minIndex].balance { minIndex = i }
            if points[i].balance > points[maxIndex].balance { maxIndex = i }
        }
        var selected = Set<Int>()
        for index in [0, count - 1, minIndex, maxIndex] where selected.count < maxCount {
            selected.insert(index)
        }
        if selected.count < maxCount {
            for j in 0..<maxCount where selected.count < maxCount {
                selected.insert(j * (count - 1) / (maxCount - 1))
            }
        }
        if selected.count < maxCount {
            for i in 0..<count where selected.count < maxCount {
                selected.insert(i)
            }
        }
        return selected.sorted().map { points[$0] }
    }

    // MARK: - Reconcile

    /// Compares the balance the app computed against the balance the user
    /// reports from the bank.
    ///
    /// `difference` is `computed - reported` (positive: the app overstates
    /// the balance). `adjustmentDelta` is `reported - computed`: the signed
    /// delta an adjusting entry needs so the computed balance matches the
    /// reported one.
    public static func reconcile(
        computed: Int64,
        reported: Int64
    ) throws -> BalanceHistoryReconciliation {
        let difference = try subtract(computed, reported)
        let adjustment = try subtract(reported, computed)
        return BalanceHistoryReconciliation(
            difference: difference,
            adjustmentDelta: adjustment
        )
    }

    // MARK: - Private

    /// Stable sort by date; `sorted(by:)` alone does not guarantee the
    /// order of entries sharing a timestamp.
    private static func stableSort(_ entries: [BalanceHistoryEntry]) -> [BalanceHistoryEntry] {
        entries
            .enumerated()
            .sorted { lhs, rhs in
                lhs.element.date == rhs.element.date
                    ? lhs.offset < rhs.offset
                    : lhs.element.date < rhs.element.date
            }
            .map(\.element)
    }

    /// The balance before the first entry. For `.anchor` this is the anchor
    /// balance with every entry at or before the anchor instant removed —
    /// which makes both modes reduce to the same forward accumulation.
    private static func balanceBeforeAllEntries(
        sortedEntries: [BalanceHistoryEntry],
        basis: BalanceHistoryBasis
    ) throws -> Int64 {
        switch basis {
        case .opening(let opening):
            return opening
        case .anchor(let anchor):
            var balance = anchor.balance
            for entry in sortedEntries where entry.date <= anchor.date {
                balance = try subtract(balance, entry.delta)
            }
            return balance
        }
    }

    private static func add(_ lhs: Int64, _ rhs: Int64) throws -> Int64 {
        let (result, overflow) = lhs.addingReportingOverflow(rhs)
        if overflow { throw BalanceHistoryError.overflow }
        return result
    }

    private static func subtract(_ lhs: Int64, _ rhs: Int64) throws -> Int64 {
        let (result, overflow) = lhs.subtractingReportingOverflow(rhs)
        if overflow { throw BalanceHistoryError.overflow }
        return result
    }
}

// MARK: - Supporting types

/// A signed money movement at an instant: positive `delta` đồng is money
/// in, negative is money out.
public struct BalanceHistoryEntry: Equatable, Sendable {
    public var date: Date
    public var delta: Int64

    public init(date: Date, delta: Int64) {
        self.date = date
        self.delta = delta
    }
}

/// A balance at an instant: an entry's running balance in a series, or a
/// day's closing balance in a daily series.
public struct BalanceHistoryPoint: Equatable, Sendable {
    public var date: Date
    public var balance: Int64

    public init(date: Date, balance: Int64) {
        self.date = date
        self.balance = balance
    }
}

/// A known balance at a known instant. The balance already includes every
/// entry dated at or before `date`.
public struct BalanceHistoryAnchor: Equatable, Sendable {
    public var date: Date
    public var balance: Int64

    public init(date: Date, balance: Int64) {
        self.date = date
        self.balance = balance
    }
}

/// The trusted figure the rest of a history is derived from.
public enum BalanceHistoryBasis: Equatable, Sendable {
    /// Balance before the first known entry.
    case opening(Int64)
    /// Known balance at a known instant.
    case anchor(BalanceHistoryAnchor)
}

/// Opening/closing totals and extremes over a range.
public struct BalanceHistorySummary: Equatable, Sendable {
    /// Balance carried into the range, after the last entry before `from`.
    public var opening: Int64
    /// Balance after the last entry in the range.
    public var closing: Int64
    /// Sum of positive deltas in the range.
    public var totalIn: Int64
    /// Sum of negative deltas in the range, as a positive magnitude.
    public var totalOut: Int64
    /// `totalIn - totalOut`, equal to `closing - opening`.
    public var netChange: Int64
    /// Lowest balance seen in the range (first occurrence on ties).
    public var minimum: BalanceHistoryPoint
    /// Highest balance seen in the range (first occurrence on ties).
    public var maximum: BalanceHistoryPoint

    public init(
        opening: Int64,
        closing: Int64,
        totalIn: Int64,
        totalOut: Int64,
        netChange: Int64,
        minimum: BalanceHistoryPoint,
        maximum: BalanceHistoryPoint
    ) {
        self.opening = opening
        self.closing = closing
        self.totalIn = totalIn
        self.totalOut = totalOut
        self.netChange = netChange
        self.minimum = minimum
        self.maximum = maximum
    }
}

/// The outcome of comparing a computed balance with a bank-reported one.
public struct BalanceHistoryReconciliation: Equatable, Sendable {
    /// `computed - reported`.
    public var difference: Int64
    /// Signed delta an adjusting entry needs so computed matches reported.
    public var adjustmentDelta: Int64

    public init(difference: Int64, adjustmentDelta: Int64) {
        self.difference = difference
        self.adjustmentDelta = adjustmentDelta
    }
}

/// Errors thrown by `BalanceHistory`; integer overflow is reported, never
/// trapped.
public enum BalanceHistoryError: Error, Equatable {
    /// A balance or total did not fit in `Int64`.
    case overflow
    /// `from` was later than `to`.
    case invalidRange
}
