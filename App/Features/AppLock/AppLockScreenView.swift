import SwiftUI

/// App-icon style badge: white SF Symbol on an accent-gradient squircle.
/// Used on the lock screen and the privacy cover.
struct AppLockBadge: View {
    var size: CGFloat = 120
    var symbol: String = "lock.fill"

    var body: some View {
        Image(systemName: symbol)
            .font(.system(size: size * 0.42, weight: .semibold))
            .foregroundStyle(.white)
            .frame(width: size, height: size)
            .background(
                LinearGradient(
                    colors: [Color.accentColor, Color.accentColor.opacity(0.72)],
                    startPoint: .topLeading,
                    endPoint: .bottomTrailing
                ),
                in: RoundedRectangle(
                    cornerRadius: size * 0.24, style: .continuous)
            )
            .shadow(color: .black.opacity(0.15), radius: 10, y: 4)
            .accessibilityHidden(true)
    }
}

/// Opaque full-screen lock screen shown until LocalAuthentication succeeds.
/// Covers every pixel — no app content may flash underneath on cold start.
struct AppLockScreenView: View {
    let onUnlock: () -> Void

    var body: some View {
        ZStack {
            Color(.systemBackground)
                .ignoresSafeArea()
            VStack(spacing: 0) {
                Spacer()
                AppLockBadge()
                Text("AM Finance đã khoá")
                    .font(.title2.weight(.semibold))
                    .padding(.top, 24)
                Spacer()
                Button("Mở khoá", action: onUnlock)
                    .buttonStyle(.borderedProminent)
                    .controlSize(.large)
                    .accessibilityIdentifier("appLock.unlockButton")
                    .padding(.bottom, 48)
            }
            .padding(.horizontal, 24)
        }
        .accessibilityIdentifier("appLock.screen")
    }
}

/// Opaque cover shown while the scene is inactive or backgrounded when
/// "hide content in the app switcher" is on, so the system snapshot reveals
/// nothing. No button — it is transient, not an interaction surface.
struct AppLockPrivacyCover: View {
    var body: some View {
        ZStack {
            Color(.systemBackground)
                .ignoresSafeArea()
            AppLockBadge(size: 96)
        }
        .accessibilityIdentifier("appLock.privacyCover")
    }
}

#Preview("Locked") {
    AppLockScreenView(onUnlock: {})
}

#Preview("Privacy cover") {
    AppLockPrivacyCover()
}
