import Foundation
import LocalAuthentication

/// System authentication behind a protocol so tests and previews can fake
/// it. The policy is `deviceOwnerAuthentication`: biometrics first, device
/// passcode as the built-in fallback.
protocol AppLockAuthenticating: Sendable {
    /// Whether the device can currently run `deviceOwnerAuthentication` —
    /// i.e. biometrics or a passcode is configured.
    func canAuthenticate() -> Bool

    /// Presents the system prompt. Returns true only on success; user
    /// cancel, fallback cancel and system errors all report false.
    func authenticate(reason: String) async -> Bool
}

/// Live implementation over `LAContext`. A fresh context per call — a used
/// context is not reliably reusable.
struct AppLockAuthenticator: AppLockAuthenticating {
    init() {}

    func canAuthenticate() -> Bool {
        LAContext().canEvaluatePolicy(.deviceOwnerAuthentication, error: nil)
    }

    func authenticate(reason: String) async -> Bool {
        let context = LAContext()
        do {
            return try await context.evaluatePolicy(
                .deviceOwnerAuthentication, localizedReason: reason)
        } catch {
            return false
        }
    }
}

#if DEBUG
/// Authenticator stub for Xcode previews — always available, always
/// succeeds, never shows a real prompt.
struct AppLockPreviewAuthenticator: AppLockAuthenticating {
    func canAuthenticate() -> Bool { true }
    func authenticate(reason: String) async -> Bool { true }
}
#endif
