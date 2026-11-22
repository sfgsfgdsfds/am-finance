import SwiftUI

/// Vietnamese date strings for the UI. Pure functions: the caller passes the
/// moment to render plus `now` and the calendar, so tests can pin all three.
enum AppDateFormat {

    /// Section header for a transaction day: "Hôm nay", "Hôm qua", otherwise
    /// the weekday and date — "Thứ Hai, 16/11/2026".
    static func dayHeader(
        _ date: Date,
        now: Date,
        calendar: Calendar = AppCalendar.vietnam
    ) -> String {
        if calendar.isDate(date, inSameDayAs: now) {
            return "Hôm nay"
        }
        let yesterday = calendar.date(byAdding: .day, value: -1, to: now) ?? now
        if calendar.isDate(date, inSameDayAs: yesterday) {
            return "Hôm qua"
        }
        return formatter("EEEE, dd/MM/yyyy", calendar: calendar).string(from: date)
    }

    /// "22/11" — short day/month for rows and pickers.
    static func shortDate(
        _ date: Date,
        calendar: Calendar = AppCalendar.vietnam
    ) -> String {
        formatter("dd/MM", calendar: calendar).string(from: date)
    }

    /// "Tháng 11/2026" — title for a month section or report.
    static func monthTitle(
        _ date: Date,
        calendar: Calendar = AppCalendar.vietnam
    ) -> String {
        let month = calendar.component(.month, from: date)
        let year = calendar.component(.year, from: date)
        return "Tháng \(month)/\(year)"
    }

    /// "14:05" — 24-hour clock.
    static func time(
        _ date: Date,
        calendar: Calendar = AppCalendar.vietnam
    ) -> String {
        formatter("HH:mm", calendar: calendar).string(from: date)
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

#Preview {
    let now = Date.now
    let yesterday = AppCalendar.vietnam.date(byAdding: .day, value: -1, to: now) ?? now
    return VStack(alignment: .leading, spacing: 8) {
        Text(AppDateFormat.dayHeader(now, now: now))
        Text(AppDateFormat.dayHeader(yesterday, now: now))
        Text(AppDateFormat.dayHeader(now.addingTimeInterval(-5 * 86_400), now: now))
        Text(AppDateFormat.shortDate(now))
        Text(AppDateFormat.monthTitle(now))
        Text(AppDateFormat.time(now))
    }
    .padding()
}
