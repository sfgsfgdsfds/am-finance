import Foundation

/// The bounded date windows the agent sheet offers. Every option resolves
/// to a half-open `DateInterval` of whole Vietnam-local days and can never
/// exceed `AIAgentWindowSelection.maxCustomWindow` (~3 months) — a
/// deliberate picker bound, tighter than the tools' `maxWindow`.
enum AIAgentWindowKind: String, CaseIterable, Sendable {
    /// The calendar month containing `now`.
    case thisMonth
    /// Today plus the six days before it.
    case last7Days
    /// Today plus the twenty-nine days before it.
    case last30Days
    /// Two user-picked days, inclusive — the only option that can be
    /// invalid (inverted or over the ~3-month bound).
    case custom

    /// Vietnamese label on the picker.
    var title: String {
        switch self {
        case .thisMonth: return "Tháng này"
        case .last7Days: return "7 ngày qua"
        case .last30Days: return "30 ngày qua"
        case .custom: return "Tuỳ chọn"
        }
    }
}

/// The picker's editable state: the preset plus the two custom days.
/// Pure value type — every computation takes `now` and the calendar.
struct AIAgentWindowSelection: Equatable, Sendable {
    /// The widest `.custom` range the picker allows — kept at ~3 months
    /// on purpose even though `AIAgentLedgerTools.maxWindow` grew: the
    /// legacy sheet's picker stays a small, day-granularity choice.
    nonisolated static let maxCustomWindow: TimeInterval = 93 * 86_400

    var kind: AIAgentWindowKind = .thisMonth
    /// First day of a `.custom` range — ignored by the presets.
    var customStart: Date
    /// Last day of a `.custom` range, inclusive — ignored by the presets.
    var customEnd: Date

    init(
        kind: AIAgentWindowKind = .thisMonth,
        customStart: Date? = nil,
        customEnd: Date? = nil,
        now: Date = .now,
        calendar: Calendar = AppCalendar.vietnam
    ) {
        self.kind = kind
        self.customStart = customStart
            ?? calendar.date(byAdding: .day, value: -6, to: now) ?? now
        self.customEnd = customEnd ?? now
    }

    /// The resolved half-open interval, or nil when `.custom` is invalid
    /// — inverted days or a span wider than the tools' bound. Validated
    /// before any `DateInterval` is built so a bad range can't trap the
    /// type's `start <= end` precondition.
    func interval(
        now: Date = .now,
        calendar: Calendar = AppCalendar.vietnam
    ) -> DateInterval? {
        switch kind {
        case .thisMonth:
            return calendar.dateInterval(of: .month, for: now)
        case .last7Days:
            return daysWindow(endingAt: now, days: 7, calendar: calendar)
        case .last30Days:
            return daysWindow(endingAt: now, days: 30, calendar: calendar)
        case .custom:
            let start = calendar.startOfDay(for: customStart)
            let last = calendar.startOfDay(for: customEnd)
            guard last >= start,
                  let end = calendar.date(byAdding: .day, value: 1, to: last)
            else { return nil }
            let interval = DateInterval(start: start, end: end)
            guard interval.duration <= Self.maxCustomWindow
            else { return nil }
            return interval
        }
    }

    /// The `.custom` validation message, or nil when the range resolves.
    func errorText(
        now: Date = .now,
        calendar: Calendar = AppCalendar.vietnam
    ) -> String? {
        guard kind == .custom else { return nil }
        if calendar.startOfDay(for: customEnd)
            < calendar.startOfDay(for: customStart) {
            return "Ngày kết thúc phải bằng hoặc sau ngày bắt đầu."
        }
        if interval(now: now, calendar: calendar) == nil {
            return "Khoảng ngày tối đa 93 ngày — hãy chọn lại."
        }
        return nil
    }

    /// `[startOfDay(now - days + 1), startOfDay(now) + 1 day)` — whole
    /// local days ending today.
    private func daysWindow(
        endingAt now: Date, days: Int, calendar: Calendar
    ) -> DateInterval? {
        guard let first = calendar.date(
            byAdding: .day, value: -(days - 1),
            to: calendar.startOfDay(for: now)),
            let end = calendar.date(
                byAdding: .day, value: 1,
                to: calendar.startOfDay(for: now))
        else { return nil }
        return DateInterval(start: first, end: end)
    }
}
