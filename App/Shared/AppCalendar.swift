import Foundation

/// The app's single calendar. Vietnam has one time zone (UTC+7, no DST) and
/// uses the Gregorian calendar, so every date computation and every rendered
/// date string goes through this to stay consistent.
enum AppCalendar {
    static let vietnam: Calendar = {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "Asia/Ho_Chi_Minh")!
        calendar.locale = Locale(identifier: "vi_VN")
        return calendar
    }()
}
