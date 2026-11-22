import Foundation

/// How often a ``RecurrenceRule`` repeats.
public enum RecurrenceFrequency: String, Codable, CaseIterable, Sendable {
    case daily
    case weekly
    case monthly
    case yearly

    /// Vietnamese label for the UI.
    public var displayName: String {
        switch self {
        case .daily: return "Hằng ngày"
        case .weekly: return "Hằng tuần"
        case .monthly: return "Hằng tháng"
        case .yearly: return "Hằng năm"
        }
    }
}

/// A ``RecurrenceRule`` failed validation.
public enum RecurrenceError: Error, Equatable, Sendable {
    /// `interval` below 1.
    case invalidInterval
    /// `endDate`'s calendar day lies before `startDate`'s.
    case endBeforeStart
    /// `maximumOccurrences` below 1.
    case invalidMaximumOccurrences
}

extension RecurrenceError: LocalizedError {
    public var errorDescription: String? {
        switch self {
        case .invalidInterval:
            return "Khoảng lặp lại phải từ 1 trở lên."
        case .endBeforeStart:
            return "Ngày kết thúc không được trước ngày bắt đầu."
        case .invalidMaximumOccurrences:
            return "Số lần lặp tối đa phải từ 1 trở lên."
        }
    }
}

/// A recurring schedule — the "every N days / weeks / months / years"
/// part of a recurring transaction such as a monthly tool
/// subscription, rent collected from a serviced apartment, or a loan
/// or card payment reminder.
///
/// All computation works at *day* granularity in the caller's
/// `Calendar` (pass a Gregorian calendar in Asia/Ho_Chi_Minh for the
/// app's semantics): occurrences are start-of-day instants and the
/// time of day inside an argument never affects the result.
///
/// Occurrence 0 is `startDate`'s calendar day; each step adds
/// `interval` units. Monthly and yearly rules anchor on `startDate`'s
/// day of month and clamp to the last day of shorter months *without
/// drifting* — a rule starting Jan 31 yields Jan 31, Feb 28/29,
/// Mar 31, Apr 30, … because every occurrence is re-clamped from the
/// anchor rather than derived from the previous one. `endDate` is
/// inclusive: an occurrence on that day still fires.
/// `maximumOccurrences` caps the total number ever produced.
///
/// Every method takes an explicit `calendar` — there is no global
/// default. The stored properties are mutable, so every querying
/// method re-runs ``validate(calendar:)`` before computing.
public struct RecurrenceRule: Equatable, Sendable {
    public var frequency: RecurrenceFrequency
    /// Every N units of `frequency`; must be ≥ 1.
    public var interval: Int
    /// First occurrence; for monthly/yearly also the day-of-month
    /// anchor.
    public var startDate: Date
    /// Last calendar day an occurrence may fall on, inclusive.
    public var endDate: Date?
    /// Total occurrences ever produced; nil for unbounded.
    public var maximumOccurrences: Int?

    public init(
        frequency: RecurrenceFrequency,
        interval: Int = 1,
        startDate: Date,
        endDate: Date? = nil,
        maximumOccurrences: Int? = nil,
        calendar: Calendar
    ) throws {
        self.frequency = frequency
        self.interval = interval
        self.startDate = startDate
        self.endDate = endDate
        self.maximumOccurrences = maximumOccurrences
        try validate(calendar: calendar)
    }

    /// Throws ``RecurrenceError`` when the rule is inconsistent:
    /// `interval` < 1, `maximumOccurrences` < 1, or `endDate`'s
    /// calendar day before `startDate`'s. An `endDate` on `startDate`'s
    /// day is allowed and yields exactly one occurrence.
    public func validate(calendar: Calendar) throws {
        guard interval >= 1 else { throw RecurrenceError.invalidInterval }
        if let maximum = maximumOccurrences {
            guard maximum >= 1 else {
                throw RecurrenceError.invalidMaximumOccurrences
            }
        }
        if let end = endDate,
           calendar.startOfDay(for: end) < calendar.startOfDay(for: startDate) {
            throw RecurrenceError.endBeforeStart
        }
    }

    /// All occurrences whose calendar day lies inside `range`'s
    /// calendar-day span, both bounds inclusive, in chronological
    /// order. A range ending anywhere inside an occurrence's day
    /// includes that occurrence.
    public func occurrences(
        in range: ClosedRange<Date>,
        calendar: Calendar
    ) throws -> [Date] {
        try validate(calendar: calendar)
        return Engine(rule: self, calendar: calendar).occurrences(
            lo: calendar.startOfDay(for: range.lowerBound),
            hi: calendar.startOfDay(for: range.upperBound),
            limit: .max,
            calendar: calendar
        )
    }

    /// The first occurrence strictly after `date`. Occurrences are
    /// start-of-day instants, so this is the first occurrence on a
    /// later calendar day — one dated the same day as `date` is
    /// already past. Nil once the rule has ended (`endDate` passed or
    /// `maximumOccurrences` produced).
    public func nextOccurrence(
        after date: Date,
        calendar: Calendar
    ) throws -> Date? {
        try validate(calendar: calendar)
        guard let tomorrow = calendar.date(
            byAdding: .day, value: 1,
            to: calendar.startOfDay(for: date)
        ) else { return nil }
        return Engine(rule: self, calendar: calendar).occurrences(
            lo: tomorrow, hi: .distantFuture, limit: 1, calendar: calendar
        ).first
    }

    /// Occurrences that became due since `lastGenerated`, up to `now`:
    /// every occurrence on a calendar day strictly after
    /// `lastGenerated`'s day and on or before `now`'s day, in
    /// chronological order, at most `limit` (the earliest come first,
    /// so persisting them and calling again later picks up the rest).
    /// Used at app launch to create missed transactions. `limit` ≤ 0
    /// or a `now` before `lastGenerated`'s day yields [].
    public func missedOccurrences(
        after lastGenerated: Date,
        upTo now: Date,
        limit: Int,
        calendar: Calendar
    ) throws -> [Date] {
        try validate(calendar: calendar)
        guard limit > 0,
              let lo = calendar.date(
                  byAdding: .day, value: 1,
                  to: calendar.startOfDay(for: lastGenerated)
              )
        else { return [] }
        return Engine(rule: self, calendar: calendar).occurrences(
            lo: lo,
            hi: calendar.startOfDay(for: now),
            limit: limit,
            calendar: calendar
        )
    }

    /// The 0-based position of `date` in the occurrence sequence —
    /// `startDate`'s day is index 0 — or nil when `date`'s day is not
    /// an occurrence (not aligned, before `startDate`, or beyond
    /// `endDate`/`maximumOccurrences`).
    public func index(of date: Date, calendar: Calendar) throws -> Int? {
        try validate(calendar: calendar)
        let engine = Engine(rule: self, calendar: calendar)
        let day = calendar.startOfDay(for: date)
        guard let i = engine.firstIndex(onOrAfter: day, calendar: calendar),
              let d = engine.occurrence(i, calendar: calendar),
              d == day,
              engine.isLive(index: i, date: d)
        else { return nil }
        return i
    }

    /// Human-readable Vietnamese summary — "Hằng ngày", "Mỗi 2 tuần",
    /// "Hằng tháng, ngày 5", "Hằng năm, ngày 29 tháng 2".
    public func summary(calendar: Calendar) -> String {
        var text = interval == 1
            ? frequency.displayName
            : "Mỗi \(interval) \(Self.unitName(for: frequency))"
        switch frequency {
        case .monthly:
            text += ", ngày \(calendar.component(.day, from: startDate))"
        case .yearly:
            let c = calendar.dateComponents([.day, .month], from: startDate)
            text += ", ngày \(c.day ?? 0) tháng \(c.month ?? 0)"
        case .daily, .weekly:
            break
        }
        return text
    }

    /// Singular Vietnamese unit for "Mỗi N <unit>".
    private static func unitName(for frequency: RecurrenceFrequency) -> String {
        switch frequency {
        case .daily: return "ngày"
        case .weekly: return "tuần"
        case .monthly: return "tháng"
        case .yearly: return "năm"
        }
    }

    // MARK: - Private calendar engine

    /// Calendar facts about a rule precomputed once, plus the
    /// enumeration primitives. Every `Date` it produces is a
    /// start-of-day instant in the given calendar; `lo`/`hi` bounds
    /// it takes must already be start-of-day for the day-granularity
    /// contract to hold.
    private struct Engine {
        let frequency: RecurrenceFrequency
        let interval: Int
        /// `startOfDay(startDate)` — also occurrence 0.
        let startDay: Date
        /// Day of month of `startDate`, the clamping anchor.
        let anchorDay: Int
        /// `year * 12 + month - 1` of `startDate`, for month arithmetic
        /// that never wraps at year boundaries.
        let startMonthIndex: Int
        /// `startOfDay(endDate)`, if any.
        let endDay: Date?
        let maximumOccurrences: Int?

        init(rule: RecurrenceRule, calendar: Calendar) {
            let start = calendar.startOfDay(for: rule.startDate)
            let comps = calendar.dateComponents([.year, .month, .day], from: start)
            frequency = rule.frequency
            interval = max(1, rule.interval)
            startDay = start
            anchorDay = comps.day ?? 1
            startMonthIndex = (comps.year ?? 0) * 12 + (comps.month ?? 1) - 1
            endDay = rule.endDate.map { calendar.startOfDay(for: $0) }
            maximumOccurrences = rule.maximumOccurrences
        }

        /// The date of occurrence `index` ignoring `endDate`/
        /// `maximumOccurrences` — nil when the calendar cannot
        /// represent it (effectively the end of the sequence).
        func occurrence(_ index: Int, calendar: Calendar) -> Date? {
            guard index >= 0 else { return nil }
            switch frequency {
            case .daily, .weekly:
                let (step, stepOverflow) = interval.multipliedReportingOverflow(
                    by: frequency == .weekly ? 7 : 1)
                guard !stepOverflow else { return index == 0 ? startDay : nil }
                let (offset, offsetOverflow) =
                    index.multipliedReportingOverflow(by: step)
                guard !offsetOverflow,
                      let d = calendar.date(byAdding: .day, value: offset,
                                            to: startDay)
                else { return nil }
                return calendar.startOfDay(for: d)
            case .monthly, .yearly:
                let (step, stepOverflow) = interval.multipliedReportingOverflow(
                    by: frequency == .yearly ? 12 : 1)
                guard !stepOverflow else {
                    return index == 0
                        ? monthDate(startMonthIndex, calendar: calendar)
                        : nil
                }
                let (offset, offsetOverflow) =
                    index.multipliedReportingOverflow(by: step)
                let (total, addOverflow) =
                    startMonthIndex.addingReportingOverflow(offset)
                guard !offsetOverflow, !addOverflow else { return nil }
                return monthDate(total, calendar: calendar)
            }
        }

        /// Whether occurrence `index` dated `date` is inside the
        /// rule's `endDate`/`maximumOccurrences` limits.
        func isLive(index: Int, date: Date) -> Bool {
            if let maximum = maximumOccurrences, index >= maximum {
                return false
            }
            if let end = endDay, date > end { return false }
            return true
        }

        /// Index of the first occurrence on or after `day` — nil when
        /// no representable occurrence qualifies.
        func firstIndex(onOrAfter day: Date, calendar: Calendar) -> Int? {
            var i = roughIndex(to: day, calendar: calendar)
            // The estimate can overshoot or fall short by a step or
            // two (clamped months, DST boundaries): settle exactly.
            while i > 0,
                  let previous = occurrence(i - 1, calendar: calendar),
                  previous >= day {
                i -= 1
            }
            while let d = occurrence(i, calendar: calendar), d < day {
                i += 1
            }
            return occurrence(i, calendar: calendar) == nil ? nil : i
        }

        /// Up to `limit` occurrences on days in `[lo, hi]` inclusive,
        /// chronological, honoring `endDate` and
        /// `maximumOccurrences`. `lo` and `hi` must be start-of-day.
        func occurrences(
            lo: Date, hi: Date, limit: Int, calendar: Calendar
        ) -> [Date] {
            guard lo <= hi, limit > 0,
                  var i = firstIndex(onOrAfter: lo, calendar: calendar)
            else { return [] }
            var dates: [Date] = []
            while dates.count < limit {
                guard let d = occurrence(i, calendar: calendar), d <= hi,
                      isLive(index: i, date: d)
                else { break }
                dates.append(d)
                i += 1
            }
            return dates
        }

        /// A starting estimate for the index of the first occurrence
        /// near `day`, from component arithmetic, so seeking does not
        /// walk from index 0. May be off by a step or two either way;
        /// ``firstIndex(onOrAfter:calendar:)`` settles it.
        private func roughIndex(to day: Date, calendar: Calendar) -> Int {
            guard day > startDay else { return 0 }
            switch frequency {
            case .daily:
                let n = calendar.dateComponents(
                    [.day], from: startDay, to: day).day ?? 0
                return max(0, n / interval)
            case .weekly:
                let n = calendar.dateComponents(
                    [.day], from: startDay, to: day).day ?? 0
                return max(0, n / 7 / interval)
            case .monthly:
                let n = calendar.dateComponents(
                    [.month], from: startDay, to: day).month ?? 0
                return max(0, n / interval)
            case .yearly:
                let n = calendar.dateComponents(
                    [.year], from: startDay, to: day).year ?? 0
                return max(0, n / interval)
            }
        }

        /// The day `anchorDay` clamped to the length of absolute month
        /// `totalMonth` (`year * 12 + month - 1`).
        private func monthDate(
            _ totalMonth: Int, calendar: Calendar
        ) -> Date? {
            guard totalMonth >= 0 else { return nil }
            let year = totalMonth / 12
            let month = totalMonth % 12 + 1
            guard let first = calendar.date(
                from: DateComponents(year: year, month: month, day: 1)),
                  let days = calendar.range(
                    of: .day, in: .month, for: first)?.count
            else { return nil }
            return calendar.date(from: DateComponents(
                year: year, month: month, day: min(anchorDay, days)))
        }
    }
}
