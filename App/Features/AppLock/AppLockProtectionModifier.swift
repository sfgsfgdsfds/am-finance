import SwiftUI

/// Wires the lock state machine to a root view: feeds `scenePhase` changes
/// into the controller and layers the opaque lock screen / privacy cover on
/// top of the app content. The overlay is part of the very first layout
/// pass, so a locked cold start never flashes real content.
private struct AppLockProtectionModifier: ViewModifier {
    let controller: AppLockController

    @Environment(\.scenePhase) private var scenePhase

    func body(content: Content) -> some View {
        content
            .overlay {
                switch controller.phase {
                case .unlocked:
                    EmptyView()
                case .covered:
                    AppLockPrivacyCover()
                case .locked:
                    AppLockScreenView { controller.requestUnlock() }
                }
            }
            .onChange(of: scenePhase, initial: true) { _, newPhase in
                controller.scenePhaseChanged(newPhase)
            }
    }
}

extension View {
    /// Covers the app with the Face ID lock screen (passcode fallback) and
    /// the app-switcher privacy cover according to `AppLockSettings`.
    /// Attach once to the root view.
    @MainActor
    func appLockProtected(
        controller: AppLockController = .shared
    ) -> some View {
        modifier(AppLockProtectionModifier(controller: controller))
    }
}

#Preview {
    let defaults = UserDefaults(suiteName: "AppLockProtection.preview")!
    let controller = AppLockController(
        store: AppLockSettingsStore(defaults: defaults),
        authenticator: AppLockPreviewAuthenticator())
    return Text("Nội dung ứng dụng")
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .appLockProtected(controller: controller)
}
