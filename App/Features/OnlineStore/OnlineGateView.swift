import SwiftUI

/// Shows `content` (the root tabs) only while the online store is
/// `ready`; before that it shows the sign-in, loading or error + retry
/// screen. Everything that mutates the ledger on activation hangs off
/// `content`, so it cannot run against an empty in-memory store.
struct OnlineGate<Content: View>: View {
    let store: OnlineStore
    @ViewBuilder var content: () -> Content
    @Environment(\.scenePhase) private var scenePhase

    var body: some View {
        Group {
            switch store.phase {
            case .ready:
                content()
                    .overlay {
                        if !store.isOnline {
                            OnlineOfflineOverlay()
                        }
                    }
                    .alert(
                        "Dữ liệu cũ trên iPhone",
                        isPresented: Binding(
                            get: { store.legacyNotice != nil },
                            set: { if !$0 { store.dismissLegacyNotice() } })
                    ) {
                        Button("Đã hiểu", role: .cancel) {}
                    } message: {
                        Text(store.legacyNotice ?? "")
                    }
                    .alert(
                        store.rejectionMessage ?? "Máy chủ từ chối thay đổi",
                        isPresented: Binding(
                            get: { store.rejectionMessage != nil },
                            set: { if !$0 { store.dismissRejection() } })
                    ) {
                        Button("Đã hiểu", role: .cancel) {}
                    } message: {
                        Text("Dữ liệu trên máy đã được tải lại theo máy chủ.")
                    }
            case .starting, .loading:
                OnlineGateProgressView(
                    text: "Đang tải dữ liệu từ máy chủ…",
                    identifier: "online.gate.loading")
            case .migratingLegacy:
                OnlineGateProgressView(
                    text: "Đang chuyển dữ liệu cũ trên iPhone lên máy chủ…",
                    identifier: "online.gate.migrating")
            case .signedOut:
                OnlineSignInView(store: store)
            case .failed(let message):
                OnlineFailedView(message: message) {
                    Task { await store.retry() }
                }
            }
        }
        .task { await store.start() }
        .onAppear { store.setForeground(scenePhase == .active) }
        .onChange(of: scenePhase) { _, phase in
            store.setForeground(phase == .active)
        }
    }
}

/// Non-dismissable cover while the server cannot be reached. Taps land
/// here, so the ledger behind it cannot be edited until a request
/// succeeds and the store clears `isOnline`.
private struct OnlineOfflineOverlay: View {
    var body: some View {
        ZStack {
            Color.black.opacity(0.35)
                .ignoresSafeArea()
            VStack(spacing: 16) {
                ProgressView()
                Text("Mất kết nối máy chủ — đang thử lại…")
                    .font(.subheadline)
                    .multilineTextAlignment(.center)
            }
            .padding(24)
            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 16))
            .padding()
        }
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("online.offline")
    }
}

private struct OnlineGateProgressView: View {
    let text: String
    let identifier: String

    var body: some View {
        VStack(spacing: 16) {
            ProgressView()
            Text(text)
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding()
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier(identifier)
    }
}

private struct OnlineFailedView: View {
    let message: String
    let retry: () -> Void

    var body: some View {
        VStack(spacing: 16) {
            Image(systemName: "exclamationmark.icloud")
                .font(.system(size: 44))
                .foregroundStyle(.secondary)
            Text("Không tải được dữ liệu")
                .font(.headline)
            Text(message)
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .accessibilityIdentifier("online.gate.error")
            Button("Thử lại", action: retry)
                .buttonStyle(.borderedProminent)
                .accessibilityIdentifier("online.gate.retry")
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding()
    }
}

/// Sign-in with the AMX account; when the WalletLink client id was never
/// entered, a field for it appears first (same store the Kết nối ví AMX
/// screen writes).
private struct OnlineSignInView: View {
    let store: OnlineStore

    @State private var clientID = ""
    @State private var configured = true
    private let configStore = WalletLinkConfigStore()

    var body: some View {
        VStack(spacing: 16) {
            Image(systemName: "person.crop.circle.badge.checkmark")
                .font(.system(size: 44))
                .foregroundStyle(.secondary)
            Text("Đăng nhập để dùng AM Finance")
                .font(.headline)
            Text("Dữ liệu được lưu trên máy chủ. Hãy đăng nhập tài khoản AMX để tải dữ liệu của bạn.")
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
            if !configured {
                TextField("Client ID (cli_…)", text: $clientID)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .textFieldStyle(.roundedBorder)
                    .accessibilityIdentifier("online.gate.clientID")
            }
            if let error = store.signInError {
                Text(error)
                    .font(.footnote)
                    .foregroundStyle(.red)
                    .multilineTextAlignment(.center)
                    .accessibilityIdentifier("online.gate.signInError")
            }
            Button("Đăng nhập") {
                var config = configStore.load()
                if !configured { config.clientID = clientID }
                configStore.save(config)
                configured = config.isConfigured
                Task { await store.signIn() }
            }
            .buttonStyle(.borderedProminent)
            .accessibilityIdentifier("online.gate.signIn")
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding()
        .onAppear {
            let config = configStore.load()
            clientID = config.clientID
            configured = config.isConfigured
        }
    }
}

private struct OnlineStoreEnvironmentKey: EnvironmentKey {
    static let defaultValue: OnlineStore? = nil
}

extension EnvironmentValues {
    /// The app-level online store, injected on the root. Nil in
    /// previews and in plain `-uiTestInMemoryStore` launches (no
    /// server). The Máy chủ page, data reset and replace-restore use
    /// it to import and reload.
    var onlineStore: OnlineStore? {
        get { self[OnlineStoreEnvironmentKey.self] }
        set { self[OnlineStoreEnvironmentKey.self] = newValue }
    }
}
