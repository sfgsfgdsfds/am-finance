import SwiftUI
import SwiftData
import FinanceCore

/// Wrapper making a server bank account `Identifiable` for sheet and
/// dialog plumbing.
struct WalletSyncLinkRequest: Identifiable {
    let server: WalletAPIBankAccount
    var id: String { server.id }
}

/// Links bank accounts on wallet.amx.vn to ledger accounts: create a new
/// "VPBank *1234" account or attach an existing one, choose how far back to
/// import, unlink (keeping imported rows) and sync on demand. Pushed inside
/// an existing NavigationStack — it must not create its own.
struct WalletSyncAccountsView: View {
    @Environment(\.modelContext) private var context
    @Query(sort: \Account.sortOrder) private var appAccounts: [Account]
    @Query private var pendingReview: [LedgerTransaction]

    private let session: WalletLinkSession
    private let defaults: UserDefaults
    private let injectedAPI: (any WalletSyncAPI)?
    private let stateStore: WalletSyncStateStore
    private let ruleStore: WalletSyncRuleStore

    @State private var status: WalletLinkStatus = .signedOut
    @State private var serverAccounts: [WalletAPIBankAccount]?
    @State private var isLoading = false
    @State private var loadError: String?
    @State private var linking: WalletSyncLinkRequest?
    @State private var unlinking: WalletSyncLinkRequest?
    @State private var coordinator: WalletSyncCoordinator?
    @State private var importedCount = 0

    init(
        session: WalletLinkSession = .shared,
        defaults: UserDefaults = .standard,
        api: (any WalletSyncAPI)? = nil
    ) {
        self.session = session
        self.defaults = defaults
        self.injectedAPI = api
        self.stateStore = WalletSyncStateStore(defaults: defaults)
        self.ruleStore = WalletSyncRuleStore(defaults: defaults)
        _pendingReview = Query(
            filter: #Predicate { $0.needsReview == true },
            sort: \.date, order: .reverse)
    }

    var body: some View {
        Form {
            connectionSection
            if signedIn {
                accountsSection
                syncSection
                toolsSection
            }
        }
        .navigationTitle("Đồng bộ ngân hàng")
        .task { await reload() }
        .sheet(item: $linking) { request in
            WalletSyncLinkSheet(
                serverAccount: request.server,
                candidates: linkCandidates,
                onCreate: { linkNewAccount(request.server, importFrom: $0) },
                onLink: { linkExisting($0, to: request.server, importFrom: $1) }
            )
        }
        .confirmationDialog(
            "Huỷ liên kết tài khoản?",
            isPresented: Binding(
                get: { unlinking != nil },
                set: { if !$0 { unlinking = nil } }
            ),
            presenting: unlinking
        ) { request in
            Button("Huỷ liên kết", role: .destructive) {
                unlink(request.server)
            }
            Button("Huỷ", role: .cancel) {}
        } message: { _ in
            Text("Các giao dịch đã nhập sẽ được giữ lại.")
        }
    }

    // MARK: - Sections

    private var connectionSection: some View {
        Section("Kết nối") {
            LabeledContent("Trạng thái", value: status.label)
            if !signedIn {
                NavigationLink {
                    WalletLinkSettingsView(session: session)
                } label: {
                    Label("Đăng nhập AMX", systemImage: "person.badge.key.fill")
                }
            }
        }
    }

    private var accountsSection: some View {
        Section("Tài khoản ngân hàng") {
            if isLoading && serverAccounts == nil {
                HStack(spacing: 8) {
                    ProgressView()
                    Text("Đang tải…")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
            } else if let loadError {
                Label(loadError, systemImage: "exclamationmark.triangle.fill")
                    .font(.footnote)
                    .foregroundStyle(.red)
                Button("Thử lại") {
                    Task { await loadServerAccounts() }
                }
            } else if let list = serverAccounts {
                if list.isEmpty {
                    Text("Không có tài khoản nào trên máy chủ.")
                        .foregroundStyle(.secondary)
                } else {
                    ForEach(list, id: \.id) { server in
                        serverRow(server)
                    }
                }
            }
        }
    }

    private func serverRow(_ server: WalletAPIBankAccount) -> some View {
        let linked = linkedAccount(for: server)
        let badgeHex = (linked?.colorHex).flatMap { $0.isEmpty ? nil : $0 } ?? "0A84FF"
        return HStack(spacing: 12) {
            IconBadge(symbol: "building.columns.fill", colorHex: badgeHex, size: 36)
            VStack(alignment: .leading, spacing: 2) {
                Text(WalletSyncNaming.accountName(
                    bank: server.bank, maskedNumber: server.accountNumberMasked))
                if let holderName = server.holderName {
                    Text(holderName)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                if let linked {
                    Label("Đã liên kết: \(linked.name)", systemImage: "link")
                        .font(.caption)
                        .foregroundStyle(.green)
                }
            }
            Spacer(minLength: 8)
            if linked != nil {
                Button("Huỷ liên kết") {
                    unlinking = WalletSyncLinkRequest(server: server)
                }
                .font(.subheadline)
            } else {
                Button("Liên kết") {
                    linking = WalletSyncLinkRequest(server: server)
                }
                .font(.subheadline)
            }
        }
    }

    private var syncSection: some View {
        Section {
            LabeledContent("Đã nhập", value: "\(importedCount) giao dịch")
            if let last = stateStore.lastSyncAt {
                LabeledContent(
                    "Đồng bộ lần cuối",
                    value: "\(AppDateFormat.shortDate(last)) \(AppDateFormat.time(last))")
            }
            Button {
                Task { await syncNow() }
            } label: {
                HStack {
                    Label("Đồng bộ ngay", systemImage: "arrow.triangle.2.circlepath")
                    if coordinator?.isSyncing == true {
                        Spacer()
                        ProgressView()
                    }
                }
            }
            .disabled(coordinator?.isSyncing == true || linkedAccounts.isEmpty)
            Button {
                Task { await syncNow(fullRescan: true) }
            } label: {
                Label("Đồng bộ lại toàn bộ", systemImage: "arrow.counterclockwise")
            }
            .disabled(coordinator?.isSyncing == true || linkedAccounts.isEmpty)
            if let message = coordinator?.errorMessage {
                Label(message, systemImage: "exclamationmark.triangle.fill")
                    .font(.footnote)
                    .foregroundStyle(.red)
            } else if let summary = coordinator?.lastSummary {
                Text("Đợt trước: +\(summary.totalInserted) giao dịch mới, \(summary.totalSkipped) bỏ qua.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
        } header: {
            Text("Đồng bộ")
        } footer: {
            Text("Chỉ các giao dịch mới trên máy chủ được nhập; giao dịch đã có không bị thay đổi. \"Đồng bộ lại toàn bộ\" rà soát lại từ đầu để bắt các giao dịch xuất hiện trễ.")
        }
    }

    private var toolsSection: some View {
        Section("Quản lý") {
            NavigationLink {
                WalletSyncInboxView()
            } label: {
                HStack {
                    Label("Hộp thư chờ phân loại", systemImage: "tray.full.fill")
                    Spacer()
                    if !pendingReview.isEmpty {
                        Text("\(pendingReview.count)")
                            .font(.callout)
                            .monospacedDigit()
                            .foregroundStyle(.secondary)
                    }
                }
            }
            NavigationLink {
                WalletSyncRulesView()
            } label: {
                Label("Quy tắc tự động", systemImage: "checklist")
            }
        }
    }

    // MARK: - Data

    private var signedIn: Bool {
        if case .signedIn = status { return true }
        return false
    }

    private var linkedAccounts: [Account] {
        appAccounts.filter {
            $0.externalSource == WalletSyncEngine.externalSource
        }
    }

    private func linkedAccount(for server: WalletAPIBankAccount) -> Account? {
        appAccounts.first {
            $0.externalSource == WalletSyncEngine.externalSource
                && $0.externalAccountID == server.id
        }
    }

    /// Non-archived bank accounts not already linked to a wallet account.
    private var linkCandidates: [Account] {
        appAccounts.filter {
            $0.kind == .bank && !$0.isArchived && $0.externalSource == nil
        }
    }

    private func makeAPI() throws -> any WalletSyncAPI {
        if let injectedAPI { return injectedAPI }
        let resolved = try WalletLinkConfigStore(defaults: defaults)
            .load().resolved()
        return WalletAPIClient(
            baseURL: resolved.walletBaseURL, tokenProvider: session)
    }

    private func ensureCoordinator() -> WalletSyncCoordinator {
        if let coordinator { return coordinator }
        let made = WalletSyncCoordinator.live(
            context: context, session: session,
            defaults: defaults, api: injectedAPI)
        coordinator = made
        return made
    }

    private func reload() async {
        status = await session.status
        if signedIn {
            await loadServerAccounts()
        }
        _ = ensureCoordinator()
        refreshCounts()
    }

    private func loadServerAccounts() async {
        isLoading = true
        defer { isLoading = false }
        do {
            serverAccounts = try await makeAPI().accounts()
            loadError = nil
        } catch {
            loadError = error.localizedDescription
        }
    }

    private func syncNow(fullRescan: Bool = false) async {
        await ensureCoordinator().syncNow(fullRescan: fullRescan)
        refreshCounts()
    }

    private func refreshCounts() {
        importedCount = WalletSyncEngine.importedCount(context: context)
        coordinator?.refreshPendingCount()
    }

    // MARK: - Link / unlink

    private func linkNewAccount(
        _ server: WalletAPIBankAccount, importFrom: WalletSyncImportFrom
    ) {
        let account = Account(
            name: WalletSyncNaming.accountName(
                bank: server.bank, maskedNumber: server.accountNumberMasked),
            kind: .bank,
            icon: "building.columns.fill",
            colorHex: "0A84FF",
            sortOrder: (appAccounts.map(\.sortOrder).max() ?? -1) + 1
        )
        account.externalSource = WalletSyncEngine.externalSource
        account.externalAccountID = server.id
        context.insert(account)
        try? context.save()
        stateStore.setState(
            WalletSyncAccountState(
                importFrom: importFrom.startDate(now: .now)),
            for: server.id)
        Task { await syncNow() }
    }

    private func linkExisting(
        _ account: Account,
        to server: WalletAPIBankAccount,
        importFrom: WalletSyncImportFrom
    ) {
        account.externalSource = WalletSyncEngine.externalSource
        account.externalAccountID = server.id
        try? context.save()
        stateStore.setState(
            WalletSyncAccountState(
                importFrom: importFrom.startDate(now: .now)),
            for: server.id)
        Task { await syncNow() }
    }

    /// Removes the link but keeps every imported transaction — they carry
    /// their own external markers.
    private func unlink(_ server: WalletAPIBankAccount) {
        guard let account = linkedAccount(for: server) else { return }
        account.externalSource = nil
        account.externalAccountID = nil
        try? context.save()
        stateStore.removeState(for: server.id)
        refreshCounts()
    }
}

/// Sheet for the link flow: pick an import-from cutoff, then create a new
/// bank account or pick an existing one. Owns its NavigationStack.
struct WalletSyncLinkSheet: View {
    let serverAccount: WalletAPIBankAccount
    /// Existing bank accounts eligible for linking.
    let candidates: [Account]
    let onCreate: (WalletSyncImportFrom) -> Void
    let onLink: (Account, WalletSyncImportFrom) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var importFrom: WalletSyncImportFrom = .last30Days

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    HStack(spacing: 12) {
                        IconBadge(
                            symbol: "building.columns.fill",
                            colorHex: "0A84FF", size: 36)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(WalletSyncNaming.accountName(
                                bank: serverAccount.bank,
                                maskedNumber: serverAccount.accountNumberMasked))
                            if let holderName = serverAccount.holderName {
                                Text(holderName)
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                        }
                    }
                }

                Section {
                    Picker("Nhập giao dịch từ", selection: $importFrom) {
                        ForEach(WalletSyncImportFrom.allCases, id: \.self) { option in
                            Text(option.displayName).tag(option)
                        }
                    }
                } footer: {
                    Text("Giao dịch trước mốc này sẽ không được nhập.")
                }

                Section {
                    Button {
                        onCreate(importFrom)
                        dismiss()
                    } label: {
                        Label("Tạo tài khoản mới", systemImage: "plus.circle.fill")
                    }
                } footer: {
                    Text("Sẽ tạo tài khoản ngân hàng \"\(WalletSyncNaming.accountName(bank: serverAccount.bank, maskedNumber: serverAccount.accountNumberMasked))\".")
                }

                if !candidates.isEmpty {
                    Section("Hoặc liên kết tài khoản có sẵn") {
                        ForEach(candidates, id: \.id) { account in
                            HStack(spacing: 12) {
                                IconBadge(
                                    symbol: account.icon,
                                    colorHex: account.colorHex, size: 32)
                                Text(account.name)
                                Spacer()
                                AmountText(amount: account.balance, compact: true)
                                    .font(.subheadline)
                                    .foregroundStyle(.secondary)
                            }
                            .contentShape(Rectangle())
                            .onTapGesture {
                                onLink(account, importFrom)
                                dismiss()
                            }
                        }
                    }
                }
            }
            .navigationTitle("Liên kết tài khoản")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Huỷ") { dismiss() }
                }
            }
        }
    }
}

#Preview("Chưa đăng nhập") {
    let container = try! AppModelContainer.make(inMemory: true)
    try! SeedData.seedIfNeeded(context: ModelContext(container))
    let session = WalletLinkSession(
        configProvider: { .default },
        tokenStore: WalletLinkInMemoryTokenStore(),
        urlSession: .shared
    )
    return NavigationStack {
        WalletSyncAccountsView(session: session)
    }
    .modelContainer(container)
}

#Preview("Đã đăng nhập") {
    let container = try! AppModelContainer.make(inMemory: true)
    let context = ModelContext(container)
    try! SeedData.seedIfNeeded(context: context)
    let session = WalletLinkSession(
        configProvider: { .default },
        tokenStore: WalletLinkInMemoryTokenStore(stored: WalletLinkTokens(
            accessToken: "preview",
            refreshToken: "r",
            accessTokenExpiry: .now.addingTimeInterval(3600),
            email: "cu@amx.vn",
            subject: "u1"
        )),
        urlSession: .shared
    )
    let api = WalletSyncPreviewAPI()
    api.accountsResult = [
        WalletAPIBankAccount(
            id: "11111111-1111-4111-8111-111111111111", bank: "VPBank",
            accountNumberMasked: "*1234",
            holderName: "NGUYEN VAN A", status: "active",
            lastListenerActivityAt: .now, lastTransactionAt: nil,
            transactionsCount: 128),
        WalletAPIBankAccount(
            id: "22222222-2222-4222-8222-222222222222", bank: "VPBank",
            accountNumberMasked: "*5678",
            holderName: "NGUYEN VAN A", status: "active",
            lastListenerActivityAt: .now, lastTransactionAt: nil,
            transactionsCount: 42),
    ]
    return NavigationStack {
        WalletSyncAccountsView(session: session, api: api)
    }
    .modelContainer(container)
}
