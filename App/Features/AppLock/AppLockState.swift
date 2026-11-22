import Foundation

/// What the root overlay renders for the current lock state.
enum AppLockPhase: String, Equatable, Sendable {
    /// Normal app content.
    case unlocked
    /// Opaque lock screen ("AM Finance đã khoá") until authentication
    /// succeeds — the app icon badge and a "Mở khoá" button.
    case locked
    /// Opaque privacy cover while the scene is inactive or backgrounded, so
    /// the app-switcher snapshot reveals nothing.
    case covered
}

/// Inputs to the lock state machine. Times ride on the events so the reducer
/// stays pure and tests can drive it with fixed dates.
enum AppLockEvent: Equatable, Sendable {
    case launched(at: Date)
    case sceneBecameInactive(at: Date)
    case sceneMovedToBackground(at: Date)
    case sceneBecameActive(at: Date)
    case authenticationSucceeded
    case authenticationFailed
    case settingsChanged(AppLockSettings)
}

/// Side effects the reducer asks the controller to perform.
enum AppLockEffect: Equatable, Sendable {
    /// Fire the system authentication prompt once. Emitted when the scene
    /// becomes active while locked — never on authentication failure, so a
    /// failed prompt does not loop.
    case promptAuthentication
}

/// Pure state machine for the app lock. Feed it lifecycle/authentication
/// events; read `phase` for what the overlay should show and the returned
/// effect for one-shot actions. All state lives in this value type so every
/// transition is unit-testable.
struct AppLockReducer: Equatable, Sendable {
    private(set) var settings: AppLockSettings
    /// Whether this session has been unlocked since launch.
    private(set) var authenticated = false
    private(set) var sceneIsActive = false
    /// When the scene last entered the background — consumed (and cleared)
    /// on the next activation to decide whether the delay expired.
    private(set) var backgroundedAt: Date?

    init(settings: AppLockSettings) {
        self.settings = settings
    }

    /// Locked beats covered: the lock screen is itself opaque, so an
    /// unauthenticated session shows it even while the scene is inactive.
    var phase: AppLockPhase {
        guard settings.isEnabled else { return .unlocked }
        guard authenticated else { return .locked }
        return (!sceneIsActive && settings.hideInAppSwitcher) ? .covered : .unlocked
    }

    @discardableResult
    mutating func reduce(_ event: AppLockEvent) -> AppLockEffect? {
        switch event {
        case .launched:
            // Cold start begins unauthenticated — the very first frame is
            // already covered/locked, so no content can flash.
            authenticated = false
            sceneIsActive = false
            backgroundedAt = nil
            return nil

        case .sceneBecameInactive:
            sceneIsActive = false
            return nil

        case .sceneMovedToBackground(let at):
            sceneIsActive = false
            backgroundedAt = at
            // "Ngay lập tức" relocks on any background — already at this
            // point, so the app-switcher snapshot shows the lock screen.
            if authenticated, settings.delay.shouldRelock(elapsed: 0) {
                authenticated = false
            }
            return nil

        case .sceneBecameActive(let at):
            if authenticated, let backgroundedAt,
               settings.delay.shouldRelock(
                   elapsed: at.timeIntervalSince(backgroundedAt)) {
                authenticated = false
            }
            sceneIsActive = true
            backgroundedAt = nil
            // Becoming active while locked prompts once. A later background
            // round-trip fires the event again — still once per activation.
            return phase == .locked ? .promptAuthentication : nil

        case .authenticationSucceeded:
            authenticated = true
            return nil

        case .authenticationFailed:
            // Stay locked; no new prompt — the user retries with "Mở khoá".
            return nil

        case .settingsChanged(let new):
            settings = new
            if !new.isEnabled {
                // Lock off opens the session; a stale background timestamp
                // must not relock the moment the lock is re-enabled… the
                // enable flow itself requires authentication anyway.
                authenticated = true
                backgroundedAt = nil
            }
            // Enabling while authenticated (the enable flow authenticates
            // first) keeps the session open; enabling otherwise locks now.
            return (phase == .locked && sceneIsActive) ? .promptAuthentication : nil
        }
    }
}
