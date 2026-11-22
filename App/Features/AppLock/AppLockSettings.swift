import Foundation

/// How long the app may stay in the background before the next activation
/// requires authentication again. Raw values persist in UserDefaults.
enum AppLockDelay: String, CaseIterable, Sendable {
    /// Lock on any backgrounding, however short.
    case immediately
    case oneMinute
    case fiveMinutes

    /// Vietnamese label shown in the settings picker.
    var title: String {
        switch self {
        case .immediately: return "Ngay lập tức"
        case .oneMinute: return "1 phút"
        case .fiveMinutes: return "5 phút"
        }
    }

    /// Whether a session that went to the background `elapsed` seconds ago
    /// must relock. Only call when a background actually happened —
    /// `.immediately` therefore always returns true.
    func shouldRelock(elapsed: TimeInterval) -> Bool {
        switch self {
        case .immediately:
            return true
        case .oneMinute:
            return elapsed > 60
        case .fiveMinutes:
            return elapsed > 300
        }
    }
}

/// User-facing lock settings, persisted in UserDefaults. The lock defaults
/// off; hiding content in the app switcher defaults on.
struct AppLockSettings: Equatable, Sendable {
    var isEnabled: Bool
    var delay: AppLockDelay
    /// Opaque privacy cover while the scene is inactive/backgrounded, so the
    /// app-switcher snapshot reveals nothing. Only meaningful while enabled.
    var hideInAppSwitcher: Bool

    init(
        isEnabled: Bool = false,
        delay: AppLockDelay = .immediately,
        hideInAppSwitcher: Bool = true
    ) {
        self.isEnabled = isEnabled
        self.delay = delay
        self.hideInAppSwitcher = hideInAppSwitcher
    }
}

/// UserDefaults persistence for `AppLockSettings` — three scalar keys, no
/// secrets. (`UserDefaults` is documented thread-safe, hence `@unchecked
/// Sendable`, matching `WalletLinkConfigStore`.)
final class AppLockSettingsStore: @unchecked Sendable {
    static let enabledKey = "appLock.enabled"
    static let delayKey = "appLock.delay"
    static let hideInAppSwitcherKey = "appLock.hideInAppSwitcher"

    let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    func load() -> AppLockSettings {
        var settings = AppLockSettings()
        settings.isEnabled = defaults.bool(forKey: Self.enabledKey)
        if let raw = defaults.string(forKey: Self.delayKey),
           let delay = AppLockDelay(rawValue: raw) {
            settings.delay = delay
        }
        // `hideInAppSwitcher` defaults to true — only an explicit `false`
        // turns it off, so it cannot be read with `bool(forKey:)`.
        if let value = defaults.object(forKey: Self.hideInAppSwitcherKey) as? Bool {
            settings.hideInAppSwitcher = value
        }
        return settings
    }

    func save(_ settings: AppLockSettings) {
        defaults.set(settings.isEnabled, forKey: Self.enabledKey)
        defaults.set(settings.delay.rawValue, forKey: Self.delayKey)
        defaults.set(settings.hideInAppSwitcher, forKey: Self.hideInAppSwitcherKey)
    }

    /// UI tests launch with `-uiTestInMemoryStore` (see `AMFinanceApp`) and
    /// must never be blocked by the lock screen — the flag forces the lock
    /// off no matter what was saved.
    static func isUITestLaunch(
        arguments: [String] = ProcessInfo.processInfo.arguments
    ) -> Bool {
        arguments.contains("-uiTestInMemoryStore")
    }
}
