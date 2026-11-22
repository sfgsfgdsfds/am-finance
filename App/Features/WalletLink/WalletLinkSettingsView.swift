import SwiftUI
import SwiftData

/// Màn hình kết nối ví AMX — đăng nhập OIDC qua auth.amx.vn, kiểm tra kết
/// nối tới wallet.amx.vn và chỉnh cấu hình server. Pushed inside an existing
/// NavigationStack (from Settings); it must not wrap itself in one.
struct WalletLinkSettingsView: View {
    private let session: WalletLinkSession
    private let configStore: WalletLinkConfigStore

    @State private var config = WalletLinkConfig.default
    @State private var status = WalletLinkStatus.signedOut
    @State private var isWorking = false
    @State private var checkedAccounts: [WalletAPIBankAccount]?
    @State private var notice: Notice?

    /// Inline banner under "Trạng thái" — error in red, info in green.
    struct Notice: Equatable {
        var text: String
        var isError: Bool
    }

    init(
        session: WalletLinkSession = .shared,
        configStore: WalletLinkConfigStore = WalletLinkConfigStore()
    ) {
        self.session = session
        self.configStore = configStore
    }

    var body: some View {
        Form {
            statusSection
            clientIDSection
            actionsSection
            if let checkedAccounts { accountsSection(checkedAccounts) }
            advancedSection
        }
        .navigationTitle("Kết nối ví AMX")
        .task {
            config = configStore.load()
            status = await session.status
        }
        .onChange(of: config) { _, newValue in
            configStore.save(newValue)
        }
    }

    // MARK: - Sections

    private var statusSection: some View {
        Section("Trạng thái") {
            LabeledContent("Kết nối", value: statusText)
            if let notice {
                Label(
                    notice.text,
                    systemImage: notice.isError
                        ? "exclamationmark.triangle.fill" : "checkmark.circle.fill"
                )
                .font(.footnote)
                .foregroundStyle(notice.isError ? Color.red : Color.green)
            }
        }
    }

    private var clientIDSection: some View {
        Section {
            TextField("Client ID (cli_…)", text: $config.clientID)
                .font(.callout.monospaced())
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
        } header: {
            Text("Ứng dụng")
        } footer: {
            Text("Client ID do máy chủ cấp khi đăng ký ứng dụng.")
        }
    }

    private var actionsSection: some View {
        Section {
            if isSignedIn {
                Button {
                    Task { await signIn() }
                } label: {
                    Label("Đăng nhập lại", systemImage: "person.badge.key.fill")
                }
                .disabled(isWorking || !config.isConfigured)

                Button("Đăng xuất", role: .destructive) {
                    Task { await signOut() }
                }
                .disabled(isWorking)
            } else {
                Button {
                    Task { await signIn() }
                } label: {
                    Label("Đăng nhập AMX", systemImage: "person.badge.key.fill")
                }
                .disabled(isWorking || !config.isConfigured)
            }

            Button {
                Task { await checkConnection() }
            } label: {
                Label("Kiểm tra kết nối", systemImage: "antenna.radiowaves.left.and.right")
            }
            .disabled(isWorking || !isSignedIn)

            if isWorking {
                HStack {
                    ProgressView()
                    Text("Đang xử lý…")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
            }
        }
    }

    private func accountsSection(_ accounts: [WalletAPIBankAccount]) -> some View {
        Section("Tài khoản ngân hàng") {
            ForEach(accounts, id: \.id) { account in
                HStack(spacing: 12) {
                    IconBadge(
                        symbol: "building.columns.fill", colorHex: "0A84FF", size: 36)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(account.holderName)
                        Text("\(account.bank) · \(account.accountNumberMasked)")
                            .font(.callout)
                            .foregroundStyle(.secondary)
                        if let activity = account.lastListenerActivityAt {
                            Text(
                                "Hoạt động: \(AppDateFormat.shortDate(activity)) \(AppDateFormat.time(activity))"
                            )
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        }
                    }
                    Spacer()
                    if account.status != "active" {
                        Text(account.status)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
            }
        }
    }

    private var advancedSection: some View {
        Section {
            TextField("Máy chủ đăng nhập", text: $config.authBaseURL)
                .font(.callout.monospaced())
                .keyboardType(.URL)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
            TextField("Máy chủ ví", text: $config.walletBaseURL)
                .font(.callout.monospaced())
                .keyboardType(.URL)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
        } header: {
            Text("Nâng cao")
        } footer: {
            Text("Chỉ đổi khi máy chủ chạy ở địa chỉ khác. Mặc định: auth.amx.vn và wallet.amx.vn.")
        }
    }

    // MARK: - Helpers

    private var isSignedIn: Bool {
        if case .signedIn = status { return true }
        return false
    }

    private var statusText: String {
        guard config.isConfigured else { return "Chưa thiết lập — cần Client ID" }
        return status.label
    }

    private func signIn() async {
        isWorking = true
        defer { isWorking = false }
        do {
            _ = try config.resolved()
            try await session.signIn()
            status = await session.status
            notice = Notice(text: "Đăng nhập thành công.", isError: false)
        } catch {
            status = await session.status
            notice = Notice(text: error.localizedDescription, isError: true)
        }
    }

    private func signOut() async {
        isWorking = true
        defer { isWorking = false }
        await session.signOut()
        status = await session.status
        checkedAccounts = nil
        notice = Notice(text: "Đã đăng xuất.", isError: false)
    }

    private func checkConnection() async {
        isWorking = true
        defer { isWorking = false }
        do {
            let resolved = try config.resolved()
            let client = WalletAPIClient(
                baseURL: resolved.walletBaseURL,
                tokenProvider: session
            )
            let accounts = try await client.accounts()
            checkedAccounts = accounts
            status = await session.status
            notice = Notice(
                text: "Kết nối tốt — \(accounts.count) tài khoản ngân hàng.",
                isError: false
            )
        } catch {
            checkedAccounts = nil
            status = await session.status
            notice = Notice(text: error.localizedDescription, isError: true)
        }
    }
}

#Preview {
    let container = try! AppModelContainer.make(inMemory: true)
    try! SeedData.seedIfNeeded(context: ModelContext(container))
    let session = WalletLinkSession(
        configProvider: { .default },
        tokenStore: WalletLinkInMemoryTokenStore(),
        urlSession: .shared
    )
    return NavigationStack {
        WalletLinkSettingsView(session: session)
    }
    .modelContainer(container)
}
