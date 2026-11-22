import Foundation
import SwiftUI

/// Outcome of the settings toggle's enable flow — the screen keeps the
/// toggle off for every case except `.enabled`.
enum AppLockEnableOutcome: Equatable, Sendable {
    case enabled
    case disabled
    /// The prompt ran but did not succeed (cancel or failed biometrics).
    case authenticationFailed
    /// No biometrics and no device passcode configured (or the lock is
    /// force-disabled for UI tests) — the screen explains this in Vietnamese.
    case unavailable
}

/// Glue between SwiftUI and the lock state machine: forwards scene-phase
/// events, fires the single automatic prompt the reducer asks for, runs the
/// enable flow (authenticate first, then persist) and owns the UserDefaults
/// store. One shared instance backs both the root modifier and the settings
/// screen, so a toggle flip takes effect immediately.
@MainActor @Observable
final class AppLockController {
    /// Shared instance for the app — standard UserDefaults,
    /// LocalAuthentication, real clock, UI-test launch check.
    static let shared = AppLockController()

    private let store: AppLockSettingsStore
    private let authenticator: any AppLockAuthenticating
    private let isUITestProcess: Bool
    private let now: @Sendable () -> Date
    private var reducer: AppLockReducer
    /// Guards against stacking a second system prompt while one is showing.
    private var isAuthenticating = false

    init(
        store: AppLockSettingsStore = AppLockSettingsStore(),
        authenticator: any AppLockAuthenticating = AppLockAuthenticator(),
        isUITestProcess: Bool = AppLockSettingsStore.isUITestLaunch(),
        now: @escaping @Sendable () -> Date = { Date() }
    ) {
        self.store = store
        self.authenticator = authenticator
        self.isUITestProcess = isUITestProcess
        self.now = now
        var settings = store.load()
        if isUITestProcess { settings.isEnabled = false }
        var reducer = AppLockReducer(settings: settings)
        reducer.reduce(.launched(at: now()))
        self.reducer = reducer
    }

    var settings: AppLockSettings { reducer.settings }
    var phase: AppLockPhase { reducer.phase }

    /// Localized reason shown inside the system authentication prompt.
    static let unlockReason = "Mở khoá AM Finance"

    // MARK: - Lifecycle

    /// Forwards a `ScenePhase` change into the state machine.
    func scenePhaseChanged(_ newPhase: ScenePhase) {
        switch newPhase {
        case .active: handle(.sceneBecameActive(at: now()))
        case .inactive: handle(.sceneBecameInactive(at: now()))
        case .background: handle(.sceneMovedToBackground(at: now()))
        @unknown default: break
        }
    }

    /// Single funnel for reducer events: republishes state and applies the
    /// emitted effect (the one-shot automatic prompt).
    func handle(_ event: AppLockEvent) {
        let effect = reducer.reduce(event)
        if effect == .promptAuthentication {
            requestUnlock()
        }
    }

    // MARK: - Unlocking

    /// The "Mở khoá" button and the automatic prompt both end up here;
    /// `isAuthenticating` keeps a second system prompt from stacking.
    func requestUnlock() {
        guard !isAuthenticating, phase == .locked else { return }
        isAuthenticating = true
        Task { [weak self] in
            let ok = await self?.authenticator
                .authenticate(reason: Self.unlockReason) ?? false
            guard let self else { return }
            self.isAuthenticating = false
            self.handle(ok ? .authenticationSucceeded : .authenticationFailed)
        }
    }

    // MARK: - Settings edits

    /// Settings toggle. Enabling proves identity with the system prompt
    /// first — a failure or missing biometrics/passcode keeps the lock off.
    /// Disabling is immediate.
    @discardableResult
    func setEnabled(_ enabled: Bool) async -> AppLockEnableOutcome {
        guard enabled else {
            update { $0.isEnabled = false }
            return .disabled
        }
        guard !isUITestProcess, authenticator.canAuthenticate() else {
            return .unavailable
        }
        guard await authenticator.authenticate(reason: Self.unlockReason) else {
            return .authenticationFailed
        }
        // The user just proved identity — the session counts as unlocked
        // before the enabled flag lands, so enabling never locks the user
        // out of the settings screen itself.
        handle(.authenticationSucceeded)
        update { $0.isEnabled = true }
        return .enabled
    }

    func setDelay(_ delay: AppLockDelay) {
        update { $0.delay = delay }
    }

    func setHideInAppSwitcher(_ hide: Bool) {
        update { $0.hideInAppSwitcher = hide }
    }

    /// Persists a settings edit then feeds it to the reducer so the overlay
    /// reacts immediately.
    private func update(_ change: (inout AppLockSettings) -> Void) {
        var new = settings
        change(&new)
        store.save(new)
        handle(.settingsChanged(new))
    }
}
