import Foundation
import UserNotifications

/// What the background refresh needs from a notification center — the
/// real implementation wraps `UNUserNotificationCenter`, tests use a
/// fake. Kept apart from `ReminderNotificationCentering` because this
/// feature delivers immediately and never plans ahead.
protocol BackgroundRefreshNotificationCentering: Sendable {
    func authorizationStatus() async -> ReminderAuthorizationStatus
    /// Delivers the notification right away (no trigger).
    func deliver(_ item: BackgroundRefreshNotificationPlan.Item) async throws
}

/// `UNUserNotificationCenter` behind `BackgroundRefreshNotificationCentering`.
/// The center is a shared system object predating strict concurrency —
/// its methods are safe to call from any actor, hence `@unchecked Sendable`.
struct BackgroundRefreshUserNotificationCenter:
    BackgroundRefreshNotificationCentering, @unchecked Sendable {
    private let center: UNUserNotificationCenter

    init(center: UNUserNotificationCenter = .current()) {
        self.center = center
    }

    func authorizationStatus() async -> ReminderAuthorizationStatus {
        ReminderAuthorizationStatus(
            from: await center.notificationSettings().authorizationStatus)
    }

    /// A nil trigger means "deliver now" — the app is already in the
    /// background when the refresh task runs.
    func deliver(_ item: BackgroundRefreshNotificationPlan.Item) async throws {
        let content = UNMutableNotificationContent()
        content.title = item.title
        content.body = item.body
        content.sound = .default
        try await center.add(UNNotificationRequest(
            identifier: item.identifier, content: content, trigger: nil))
    }
}
