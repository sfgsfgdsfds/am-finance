import SwiftUI

/// Settings → Dữ liệu → "Máy chủ". The app is online-only: this page
/// reports the server the in-memory store was loaded from, and offers
/// a reload plus sign-out. It does not enable, pause or disconnect a
/// sync — there is no sync switch anymore.
///
/// Pushed inside an existing NavigationStack — no stack of its own.
struct ServerStatusView: View {
    @Environment(\.financeSync) private var coordinator
    @Environment(\.onlineStore) private var onlineStore

    @State private var accountText = "Đang kiểm tra…"
    @State private var isWorking = false
    @State private var confirmsSignOut = false
    @State private var errorMessage: String?
    #if DEBUG
    /// UI-test fake only — the server's high-water seq, so a test can
    /// see that a quick-add was pushed. Stays empty for a real server.
    @State private var serverHighWater = ""
    #endif

    var body: some View {
        Form {
            Section {
                LabeledContent("Máy chủ", value: serverURL)
                    .accessibilityIdentifier("server.url")
                LabeledContent("Tài khoản", value: accountText)
                    .accessibilityIdentifier("server.account")
                LabeledContent("Kết nối", value: connectionText)
                    .accessibilityIdentifier("server.connection")
                LabeledContent("Cập nhật lần cuối", value: lastUpdateText)
                    .accessibilityIdentifier("server.lastUpdate")
                #if DEBUG
                if FinanceSyncUITestSupport.isEnabled {
                    LabeledContent("Mốc máy chủ", value: serverHighWater)
                        .accessibilityIdentifier("server.highWater")
                }
                #endif
            } header: {
                Text("Trạng thái")
            } footer: {
                Text("Dữ liệu nằm trên máy chủ. Máy này chỉ giữ một bản trong bộ nhớ cho phiên làm việc.")
            }

            Section {
                Button {
                    Task { await reload() }
                } label: {
                    Label("Tải lại dữ liệu", systemImage: "arrow.clockwise")
                }
                .disabled(isWorking || onlineStore == nil)
                .accessibilityIdentifier("server.reload")

                Button("Đăng xuất", role: .destructive) {
                    confirmsSignOut = true
                }
                .disabled(isWorking || onlineStore == nil)
                .accessibilityIdentifier("server.signOut")
            } footer: {
                Text("Tải lại thay bộ nhớ trên máy bằng bản hiện tại của máy chủ. Đăng xuất xoá bộ nhớ trên máy và quay về màn hình đăng nhập — dữ liệu trên máy chủ được giữ nguyên.")
            }
        }
        .navigationTitle("Máy chủ")
        .task { await refreshAccount() }
        .onAppear(perform: refreshDebugHighWater)
        .onChange(of: coordinator?.lastSyncAt) { _, _ in
            refreshDebugHighWater()
        }
        .confirmationDialog(
            "Đăng xuất?",
            isPresented: $confirmsSignOut,
            titleVisibility: .visible
        ) {
            Button("Đăng xuất", role: .destructive) {
                Task { await signOut() }
            }
            Button("Huỷ", role: .cancel) {}
        } message: {
            Text("Bộ nhớ trên máy sẽ bị xoá và ứng dụng quay về màn hình đăng nhập. Dữ liệu trên máy chủ không bị xoá.")
        }
        .alert(
            "Không tải lại được",
            isPresented: Binding(
                get: { errorMessage != nil },
                set: { if !$0 { errorMessage = nil } }
            ),
            presenting: errorMessage
        ) { _ in
            Button("OK") { errorMessage = nil }
        } message: { message in
            Text(message)
        }
    }

    private var serverURL: String {
        guard let coordinator else { return "Chưa có máy chủ" }
        let value = coordinator.serverDisplay
        return value.isEmpty ? "Chưa có máy chủ" : value
    }

    private var connectionText: String {
        let online = onlineStore?.isOnline ?? coordinator?.isOnline ?? false
        if !online { return "Mất kết nối" }
        if coordinator == nil, onlineStore == nil { return "Chưa kết nối" }
        return "Đang kết nối"
    }

    private var lastUpdateText: String {
        guard let date = coordinator?.lastSyncAt else { return "Chưa cập nhật" }
        return AppDateFormat.dayHeader(date, now: .now)
            + " " + AppDateFormat.time(date)
    }

    /// Re-reads the in-app fake's high-water seq. No-op for a real
    /// server and in Release — the row itself is DEBUG-only.
    private func refreshDebugHighWater() {
        #if DEBUG
        guard FinanceSyncUITestSupport.isEnabled else { return }
        serverHighWater = String(FinanceSyncUITestServer.shared.highWaterSeq)
        #endif
    }

    private func refreshAccount() async {
        let status = await WalletLinkSession.shared.status
        if case .signedIn(let email, let subject) = status {
            accountText = email ?? subject ?? "Đã đăng nhập"
            return
        }
        if await coordinator?.checkSignedIn() == true {
            // The UI-test fake server counts as signed in without a
            // WalletLink session — there is no email to show.
            accountText = "Đã đăng nhập"
            return
        }
        accountText = "Chưa đăng nhập"
    }

    private func reload() async {
        guard let onlineStore else { return }
        isWorking = true
        defer { isWorking = false }
        let ok = await onlineStore.reload()
        await coordinator?.refreshState()
        if !ok {
            errorMessage = failureText(of: onlineStore)
        }
    }

    private func signOut() async {
        guard let onlineStore else { return }
        isWorking = true
        defer { isWorking = false }
        await onlineStore.signOut()
    }

    private func failureText(of store: OnlineStore) -> String {
        if case .failed(let text) = store.phase { return text }
        return "Không tải lại được dữ liệu từ máy chủ."
    }
}
