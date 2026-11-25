import SwiftUI

/// Shows `content` (the root tabs) only while the online store is
/// `ready`; before that it shows the sign-in, loading or error + retry
/// screen. Everything that mutates the ledger on activation hangs off
/// `content`, so it cannot run against an empty in-memory store.
struct OnlineGate<Content: View>: View {
    let store: OnlineStore
    @ViewBuilder var content: () -> Content

    var body: some View {
        Group {
            switch store.phase {
            case .ready:
                content()
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
