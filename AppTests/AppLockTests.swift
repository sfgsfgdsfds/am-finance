import Testing
import Foundation
import SwiftUI
@testable import AMFinance

struct AppLockTests {

    // MARK: - Helpers

    private let t0 = Date(timeIntervalSince1970: 1_700_000_000)

    private func makeDefaults() -> UserDefaults {
        UserDefaults(suiteName: "AppLockTests.\(UUID().uuidString)")!
    }

    private func makeReducer(
        enabled: Bool = true,
        delay: AppLockDelay = .oneMinute,
        hideInAppSwitcher: Bool = true
    ) -> AppLockReducer {
        AppLockReducer(settings: AppLockSettings(
            isEnabled: enabled,
            delay: delay,
            hideInAppSwitcher: hideInAppSwitcher))
    }

    /// Drives a reducer through launch → activation → successful unlock.
    private func unlock(_ reducer: inout AppLockReducer) {
        reducer.reduce(.launched(at: t0))
        reducer.reduce(.sceneBecameActive(at: t0))
        reducer.reduce(.authenticationSucceeded)
    }

    private final class FakeAuthenticator: AppLockAuthenticating, @unchecked Sendable {
        var available = true
        var result = true
        private(set) var calls = 0

        func canAuthenticate() -> Bool { available }

        func authenticate(reason: String) async -> Bool {
            calls += 1
            return result
        }
    }

    // MARK: - AppLockSettingsStore

    @Test func storeDefaultsAndRoundTrip() {
        let store = AppLockSettingsStore(defaults: makeDefaults())
        let fresh = store.load()
        #expect(!fresh.isEnabled)
        #expect(fresh.delay == .immediately)
        #expect(fresh.hideInAppSwitcher)

        let saved = AppLockSettings(
            isEnabled: true, delay: .fiveMinutes, hideInAppSwitcher: false)
        store.save(saved)
        #expect(store.load() == saved)
    }

    @Test func uiTestLaunchArgumentDisablesLock() {
        #expect(AppLockSettingsStore.isUITestLaunch(
            arguments: ["AMFinance", "-uiTestInMemoryStore"]))
        #expect(!AppLockSettingsStore.isUITestLaunch(arguments: ["AMFinance"]))
    }

    // MARK: - Cold start

    @Test func lockedOnColdStartWhenEnabled() {
        var reducer = makeReducer(enabled: true)
        reducer.reduce(.launched(at: t0))
        #expect(reducer.phase == .locked)

        // First activation stays locked and asks for one prompt.
        #expect(reducer.reduce(.sceneBecameActive(at: t0)) == .promptAuthentication)
        #expect(reducer.phase == .locked)
    }

    @Test func unlockedOnColdStartWhenDisabled() {
        var reducer = makeReducer(enabled: false)
        reducer.reduce(.launched(at: t0))
        #expect(reducer.phase == .unlocked)
        #expect(reducer.reduce(.sceneBecameActive(at: t0)) == nil)
        #expect(reducer.phase == .unlocked)
    }

    // MARK: - Authentication

    @Test func unlocksOnAuthenticationSuccess() {
        var reducer = makeReducer()
        reducer.reduce(.launched(at: t0))
        reducer.reduce(.sceneBecameActive(at: t0))
        #expect(reducer.phase == .locked)

        reducer.reduce(.authenticationSucceeded)
        #expect(reducer.phase == .unlocked)
    }

    @Test func staysLockedOnAuthenticationFailure() {
        var reducer = makeReducer()
        reducer.reduce(.launched(at: t0))
        reducer.reduce(.sceneBecameActive(at: t0))

        // Failure keeps the lock — and does not re-fire the prompt (that
        // would loop); the user retries via "Mở khoá".
        #expect(reducer.reduce(.authenticationFailed) == nil)
        #expect(reducer.phase == .locked)

        // But a new activation while locked prompts once more.
        reducer.reduce(.sceneMovedToBackground(at: t0 + 10))
        #expect(reducer.reduce(.sceneBecameActive(at: t0 + 20)) == .promptAuthentication)
        #expect(reducer.phase == .locked)
    }

    // MARK: - Auto-lock delay

    @Test func immediateDelayRelocksOnAnyBackground() {
        var reducer = makeReducer(delay: .immediately)
        unlock(&reducer)
        #expect(reducer.phase == .unlocked)

        // Already locked while still in the background, so the switcher
        // snapshot shows the lock screen.
        reducer.reduce(.sceneMovedToBackground(at: t0 + 5))
        #expect(reducer.phase == .locked)
        #expect(reducer.reduce(.sceneBecameActive(at: t0 + 5.5)) == .promptAuthentication)
        #expect(reducer.phase == .locked)
    }

    @Test func oneMinuteDelayRelocksOnlyAfterElapsed() {
        var reducer = makeReducer(delay: .oneMinute)
        unlock(&reducer)

        // 30 s in the background → still unlocked on return.
        reducer.reduce(.sceneMovedToBackground(at: t0 + 10))
        #expect(reducer.phase == .covered)
        #expect(reducer.reduce(.sceneBecameActive(at: t0 + 40)) == nil)
        #expect(reducer.phase == .unlocked)

        // 61 s in the background → relocks.
        reducer.reduce(.sceneMovedToBackground(at: t0 + 100))
        #expect(reducer.reduce(.sceneBecameActive(at: t0 + 161)) == .promptAuthentication)
        #expect(reducer.phase == .locked)
    }

    @Test func fiveMinuteDelayRelocksOnlyAfterElapsed() {
        var reducer = makeReducer(delay: .fiveMinutes)
        unlock(&reducer)

        reducer.reduce(.sceneMovedToBackground(at: t0 + 10))
        #expect(reducer.reduce(.sceneBecameActive(at: t0 + 309)) == nil)
        #expect(reducer.phase == .unlocked)

        reducer.reduce(.sceneMovedToBackground(at: t0 + 400))
        #expect(reducer.reduce(.sceneBecameActive(at: t0 + 701)) == .promptAuthentication)
        #expect(reducer.phase == .locked)
    }

    @Test func backgroundWithoutActivationThenQuickReturn() {
        var reducer = makeReducer(delay: .oneMinute)
        unlock(&reducer)

        // Inactive (e.g. Control Center) is not a background — no relock.
        reducer.reduce(.sceneBecameInactive(at: t0 + 10))
        #expect(reducer.phase == .covered)
        #expect(reducer.reduce(.sceneBecameActive(at: t0 + 400)) == nil)
        #expect(reducer.phase == .unlocked)
    }

    // MARK: - Disabled

    @Test func disabledSettingNeverLocks() {
        var reducer = makeReducer(enabled: false)
        reducer.reduce(.launched(at: t0))
        reducer.reduce(.sceneBecameActive(at: t0))
        reducer.reduce(.sceneMovedToBackground(at: t0 + 10))
        #expect(reducer.reduce(.sceneBecameActive(at: t0 + 10_000)) == nil)
        #expect(reducer.phase == .unlocked)
    }

    // MARK: - Privacy cover

    @Test func coversWhileInactiveWhenHideEnabled() {
        var reducer = makeReducer(hideInAppSwitcher: true)
        unlock(&reducer)

        reducer.reduce(.sceneBecameInactive(at: t0 + 1))
        #expect(reducer.phase == .covered)

        // Still covered in the background (the switcher snapshot is opaque).
        reducer.reduce(.sceneMovedToBackground(at: t0 + 2))
        #expect(reducer.phase == .covered)
    }

    @Test func noCoverWhileInactiveWhenHideDisabled() {
        var reducer = makeReducer(hideInAppSwitcher: false)
        unlock(&reducer)

        reducer.reduce(.sceneBecameInactive(at: t0 + 1))
        #expect(reducer.phase == .unlocked)
    }

    // MARK: - Enable flow (controller + fake authenticator)

    /// Fixed clock for controller tests — passed as a capture-free closure
    /// because `now` is `@Sendable`.
    private static var testNow: @Sendable () -> Date {
        { Date(timeIntervalSince1970: 1_700_000_000) }
    }

    @MainActor @Test func enablingRequiresSuccessfulAuthentication() async {
        let store = AppLockSettingsStore(defaults: makeDefaults())
        let authenticator = FakeAuthenticator()
        let controller = AppLockController(
            store: store, authenticator: authenticator,
            isUITestProcess: false, now: Self.testNow)

        // Failed authentication → stays off, nothing persisted.
        authenticator.result = false
        #expect(await controller.setEnabled(true) == .authenticationFailed)
        #expect(!controller.settings.isEnabled)
        #expect(!store.load().isEnabled)

        // Successful authentication → enabled and persisted.
        authenticator.result = true
        #expect(await controller.setEnabled(true) == .enabled)
        #expect(controller.settings.isEnabled)
        #expect(store.load().isEnabled)
        #expect(authenticator.calls == 2)
    }

    @MainActor @Test func enablingUnavailableWithoutBiometricsOrPasscode() async {
        let store = AppLockSettingsStore(defaults: makeDefaults())
        let authenticator = FakeAuthenticator()
        authenticator.available = false
        let controller = AppLockController(
            store: store, authenticator: authenticator,
            isUITestProcess: false, now: Self.testNow)

        #expect(await controller.setEnabled(true) == .unavailable)
        #expect(authenticator.calls == 0)   // never prompted
        #expect(!controller.settings.isEnabled)
        #expect(!store.load().isEnabled)
    }

    @MainActor @Test func disablingStopsLocking() async {
        let store = AppLockSettingsStore(defaults: makeDefaults())
        let authenticator = FakeAuthenticator()
        let controller = AppLockController(
            store: store, authenticator: authenticator,
            isUITestProcess: false, now: Self.testNow)

        #expect(await controller.setEnabled(true) == .enabled)
        #expect(await controller.setEnabled(false) == .disabled)
        #expect(!controller.settings.isEnabled)
        #expect(!store.load().isEnabled)
        #expect(controller.phase == .unlocked)
    }

    @MainActor @Test func uiTestProcessKeepsLockOff() async {
        let defaults = makeDefaults()
        let store = AppLockSettingsStore(defaults: defaults)
        store.save(AppLockSettings(isEnabled: true))
        let authenticator = FakeAuthenticator()
        let controller = AppLockController(
            store: store, authenticator: authenticator,
            isUITestProcess: true, now: Self.testNow)

        // Saved "enabled" is overridden, and enabling is refused.
        #expect(controller.phase == .unlocked)
        #expect(!controller.settings.isEnabled)
        #expect(await controller.setEnabled(true) == .unavailable)
        #expect(authenticator.calls == 0)
    }

    @MainActor @Test func lockedPhaseUnlocksThroughController() async {
        let defaults = makeDefaults()
        let store = AppLockSettingsStore(defaults: defaults)
        store.save(AppLockSettings(isEnabled: true, delay: .immediately))
        let authenticator = FakeAuthenticator()
        let controller = AppLockController(
            store: store, authenticator: authenticator,
            isUITestProcess: false, now: Self.testNow)

        // Cold start locked; activation triggers the automatic prompt once.
        #expect(controller.phase == .locked)
        controller.scenePhaseChanged(.active)
        // Allow the prompt task to resolve.
        try? await Task.sleep(nanoseconds: 50_000_000)
        #expect(authenticator.calls == 1)
        #expect(controller.phase == .unlocked)

        // Immediate delay: a background round-trip relocks.
        controller.handle(.sceneMovedToBackground(at: Date()))
        #expect(controller.phase == .locked)
    }
}
