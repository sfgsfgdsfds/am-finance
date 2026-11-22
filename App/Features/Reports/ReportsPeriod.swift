import Foundation
import FinanceCore

/// The period modes the reports tab offers in its segmented control.
enum ReportsPeriodKind: String, CaseIterable, Sendable {
    case month
    case quarter
    case year
    case custom

    /// Vietnamese label shown in the segmented control.
    var displayName: String {
        switch self {
        case .month: return "Tháng"
        case .quarter: return "Quý"
        case .year: return "Năm"
        case .custom: return "Tuỳ chọn"
        }
    }
}

/// The period the reports tab displays: the calendar month, quarter or year
/// containing `anchor`, or an inclusive custom day range. Pure value type —
/// every computation takes an explicit calendar (`AppCalendar.vietnam` in
/// the app, pinned in tests).
struct ReportsPeriod: Equatable, Sendable {
    var kind: ReportsPeriodKind
    /// A date inside the displayed period for month/quarter/year kinds.
    var anchor: Date
    /// First day of the custom range.
    var customStart: Date
    /// Last day of the custom range — inclusive.
    var customEnd: Date

    init(
        kind: ReportsPeriodKind = .month,
        anchor: Date = .now,
        customStart: Date? = nil,
        customEnd: Date? = nil,
        calendar: Calendar
    ) {
        self.kind = kind
        self.anchor = anchor
        self.customStart = customStart
            ?? Self.monthInterval(containing: anchor, calendar: calendar).start
        self.customEnd = customEnd ?? calendar.startOfDay(for: anchor)
    }

    // MARK: - Intervals

    /// The half-open interval [start, end) the period covers.
    func interval(calendar: Calendar) -> ReportDateInterval {
        switch kind {
        case .month:
            return Self.monthInterval(containing: anchor, calendar: calendar)
        case .quarter:
            return Self.quarterInterval(containing: anchor, calendar: calendar)
        case .year:
            return Self.yearInterval(containing: anchor, calendar: calendar)
        case .custom:
            return Self.customInterval(
                from: customStart, through: customEnd, calendar: calendar)
        }
    }

    /// The calendar month containing `date`.
    static func monthInterval(
        containing date: Date, calendar: Calendar
    ) -> ReportDateInterval {
        let start = calendar.dateInterval(of: .month, for: date)?.start
            ?? calendar.startOfDay(for: date)
        let end = calendar.date(byAdding: .month, value: 1, to: start) ?? start
        return ReportDateInterval(start: start, end: end)
    }

    /// The calendar quarter containing `date` — Q1 Jan–Mar … Q4 Oct–Dec.
    static func quarterInterval(
        containing date: Date, calendar: Calendar
    ) -> ReportDateInterval {
        let comps = calendar.dateComponents([.year, .month], from: date)
        let firstMonth = ((comps.month ?? 1) - 1) / 3 * 3 + 1
        let start = calendar.date(from: DateComponents(
            year: comps.year, month: firstMonth, day: 1))
            ?? calendar.startOfDay(for: date)
        let end = calendar.date(byAdding: .month, value: 3, to: start) ?? start
        return ReportDateInterval(start: start, end: end)
    }

    /// The calendar year containing `date`.
    static func yearInterval(
        containing date: Date, calendar: Calendar
    ) -> ReportDateInterval {
        let year = calendar.component(.year, from: date)
        let start = calendar.date(from: DateComponents(year: year, month: 1, day: 1))
            ?? calendar.startOfDay(for: date)
        let end = calendar.date(byAdding: .year, value: 1, to: start) ?? start
        return ReportDateInterval(start: start, end: end)
    }

    /// Inclusive custom range → half-open [firstDay 00:00, lastDay+1 00:00)
    /// so the last picked day counts fully. Reversed bounds are swapped.
    static func customInterval(
        from startDate: Date, through endDate: Date, calendar: Calendar
    ) -> ReportDateInterval {
        var first = calendar.startOfDay(for: startDate)
        var last = calendar.startOfDay(for: endDate)
        if last < first { swap(&first, &last) }
        let end = calendar.date(byAdding: .day, value: 1, to: last) ?? last
        return ReportDateInterval(start: first, end: end)
    }

    /// [earliest data needed, interval.end): covers the equal-length previous
    /// period (for the comparison row) plus the `trendMonths`-month window
    /// ending at the period's last month. The tab fetches exactly this range
    /// with one date predicate — never the whole table.
    func fetchInterval(trendMonths: Int, calendar: Calendar) -> ReportDateInterval {
        let current = interval(calendar: calendar)
        var earliest = current.previous.start
        if trendMonths > 0 {
            let lastMonth = Self.monthInterval(
                containing: trendAnchor(calendar: calendar), calendar: calendar
            ).start
            let trendStart = calendar.date(
                byAdding: .month, value: -(trendMonths - 1), to: lastMonth
            ) ?? lastMonth
            earliest = min(earliest, trendStart)
        }
        return ReportDateInterval(start: earliest, end: current.end)
    }

    /// The last moment of the period — the trend window ends at the month
    /// containing this date (the displayed month, December for a year, …).
    func trendAnchor(calendar: Calendar) -> Date {
        interval(calendar: calendar).end.addingTimeInterval(-1)
    }

    // MARK: - Navigation

    /// The same kind of period `offset` steps away: the adjacent calendar
    /// month / quarter / year, or a custom range moved by its own length
    /// in days.
    func shifted(by offset: Int, calendar: Calendar) -> ReportsPeriod {
        var copy = self
        switch kind {
        case .month:
            copy.anchor = calendar.date(
                byAdding: .month, value: offset, to: anchor) ?? anchor
        case .quarter:
            copy.anchor = calendar.date(
                byAdding: .month, value: 3 * offset, to: anchor) ?? anchor
        case .year:
            copy.anchor = calendar.date(
                byAdding: .year, value: offset, to: anchor) ?? anchor
        case .custom:
            let first = calendar.startOfDay(for: customStart)
            let last = max(first, calendar.startOfDay(for: customEnd))
            let days = (calendar.dateComponents(
                [.day], from: first, to: last).day ?? 0) + 1
            copy.customStart = calendar.date(
                byAdding: .day, value: days * offset, to: customStart) ?? customStart
            copy.customEnd = calendar.date(
                byAdding: .day, value: days * offset, to: customEnd) ?? customEnd
            copy.anchor = copy.customEnd
        }
        return copy
    }

    // MARK: - Title

    /// "Tháng 11/2026", "Quý 4/2026", "Năm 2026", "01/10 – 15/11/2026".
    func title(calendar: Calendar) -> String {
        let current = interval(calendar: calendar)
        switch kind {
        case .month:
            return AppDateFormat.monthTitle(current.start, calendar: calendar)
        case .quarter:
            let month = calendar.component(.month, from: current.start)
            let year = calendar.component(.year, from: current.start)
            return "Quý \((month - 1) / 3 + 1)/\(year)"
        case .year:
            return "Năm \(calendar.component(.year, from: current.start))"
        case .custom:
            let lastDay = calendar.date(
                byAdding: .day, value: -1, to: current.end) ?? current.end
            let endText = Self.formatter("dd/MM/yyyy", calendar: calendar)
                .string(from: lastDay)
            let sameYear = calendar.component(.year, from: current.start)
                == calendar.component(.year, from: lastDay)
            let startText = Self.formatter(
                sameYear ? "dd/MM" : "dd/MM/yyyy", calendar: calendar
            ).string(from: current.start)
            return "\(startText) – \(endText)"
        }
    }

    private static func formatter(_ format: String, calendar: Calendar) -> DateFormatter {
        let formatter = DateFormatter()
        formatter.calendar = calendar
        formatter.timeZone = calendar.timeZone
        formatter.locale = calendar.locale
        formatter.dateFormat = format
        return formatter
    }
}
