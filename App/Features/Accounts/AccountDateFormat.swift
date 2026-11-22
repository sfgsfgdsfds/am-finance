import Foundation

/// Full "dd/MM/yyyy" dates on the app calendar — used by the accounts
/// feature for statement closing and payment due dates, which can cross a
/// year boundary where `AppDateFormat.shortDate` ("dd/MM") would mislead.
enum AccountDateFormat {
    static func full(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.calendar = AppCalendar.vietnam
        formatter.timeZone = AppCalendar.vietnam.timeZone
        formatter.locale = AppCalendar.vietnam.locale
        formatter.dateFormat = "dd/MM/yyyy"
        return formatter.string(from: date)
    }
}
