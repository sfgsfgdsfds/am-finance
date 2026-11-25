import FinanceCore
import SwiftUI

/// Settings → Dữ liệu → "Đồng bộ với web": status (sign-in, server,
/// last sync, last report, quarantine), the first-sync choice with its
/// destructive confirmations, and the run/pause/disconnect controls.
/// Pushed inside an existing NavigationStack — no stack of its own.
/// A nil coordinator (`.live` failed or tests) shows a plain notice.
struct FinanceSyncSettingsView: View {
    @Environment(\.financeSync) private var coordinator
    @State private var signedIn = false
    @State private var probe: FinanceSyncProbe?
    @State private var isProbing = false
    @State private var probeError: String?
    /// The chosen first-sync direction awaiting its destructive confirm.
    @State private var pendingConfirm: FinanceSyncEnableMode?
    @State private var showsDisconnectConfirm = false

    var body: some View {
        Form {
            if let coordinator {
                statusSection(coordinator)
                if coordinator.configured {
                    actionsSection(coordinator)
                } else {
                    setupSection(coordinator)
                }
                if !coordinator.quarantined.isEmpty {
                    quarantineSection(coordinator)
                }
            } else {
                Section {
                    Text("Đồng bộ không khả dụng trên thiết bị này.")
                        .foregroundStyle(.secondary)
                }
            }
        }
        .navigationTitle("Đồng bộ với web")
        .task {
            await reloadSignIn()
            await coordinator?.refreshState()
        }
        .onAppear {
            Task { await reloadSignIn() }
        }
        .alert(
            "Thay thế dữ liệu?",
            isPresented: Binding(
                get: { pendingConfirm != nil },
                set: { if !$0 { pendingConfirm = nil } }
            ),
            presenting: pendingConfirm
        ) { mode in
            Button(
                mode == .upload
                    ? "Thay thế trên web" : "Thay thế trên iPhone",
                role: .destructive
            ) {
                pendingConfirm = nil
                Task { await coordinator?.enable(mode: mode) }
            }
            Button("Huỷ", role: .cancel) { pendingConfirm = nil }
        } message: { mode in
            Text(confirmMessage(mode))
        }
        .alert("Ngắt kết nối đồng bộ?", isPresented: $showsDisconnectConfirm) {
            Button("Ngắt kết nối", role: .destructive) {
                Task { await coordinator?.disconnect() }
            }
            Button("Huỷ", role: .cancel) {}
        } message: {
            Text("Dữ liệu trên iPhone và trên web đều giữ nguyên. Bộ nhớ đồng bộ trên máy sẽ bị xoá — bật lại sau này phải chọn lại hướng đồng bộ đầu tiên.")
        }
    }

    // MARK: - Status

    private func statusSection(_ coordinator: FinanceSyncCoordinator)
        -> some View
    {
        Section("Trạng thái") {
            LabeledContent(
                "Đăng nhập",
                value: signedIn ? "Đã đăng nhập" : "Chưa đăng nhập"
            )
            .accessibilityIdentifier("financeSync.signInState")
            if !signedIn {
                Text("Đồng bộ với web dùng tài khoản AM Experience — đăng nhập trước khi bật.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                NavigationLink {
                    WalletLinkSettingsView()
                } label: {
                    Label(
                        "Mở đăng nhập AMX",
                        systemImage: "person.badge.key.fill"
                    )
                }
            }
            LabeledContent("Máy chủ", value: coordinator.serverDisplay)
                .accessibilityIdentifier("financeSync.server")
            LabeledContent("Đồng bộ", value: syncStateText(coordinator))
                .accessibilityIdentifier("financeSync.enabled")
            LabeledContent(
                "Đồng bộ gần nhất",
                value: coordinator.lastSyncAt.map {
                    "\(AppDateFormat.dayHeader($0, now: .now)) \(AppDateFormat.time($0))"
                } ?? "Chưa đồng bộ"
            )
            .accessibilityIdentifier("financeSync.lastSyncAt")
            if let report = coordinator.lastReport {
                Text(reportText(report))
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .accessibilityIdentifier("financeSync.report")
            }
            if let error = coordinator.lastError {
                Label(error, systemImage: "exclamationmark.triangle.fill")
                    .font(.footnote)
                    .foregroundStyle(.red)
                    .accessibilityIdentifier("financeSync.error")
            }
        }
    }

    // MARK: - First sync

    private func setupSection(_ coordinator: FinanceSyncCoordinator)
        -> some View
    {
        Section {
            Button {
                Task { await runProbe() }
            } label: {
                Label(
                    "Bật đồng bộ",
                    systemImage: "arrow.triangle.2.circlepath.icloud"
                )
            }
            .accessibilityIdentifier("financeSync.enable")
            .disabled(
                !signedIn || isProbing
                    || coordinator.isBootstrapping || coordinator.isSyncing
            )
            if isProbing {
                HStack(spacing: 8) {
                    ProgressView()
                    Text("Đang kiểm tra máy chủ…")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
                .accessibilityIdentifier("financeSync.probing")
            }
            if let probeError {
                Label(
                    probeError,
                    systemImage: "exclamationmark.triangle.fill"
                )
                .font(.footnote)
                .foregroundStyle(.red)
            }
            if let probe {
                Text(
                    "Trên web: \(probe.serverEmpty ? "chưa có dữ liệu" : "đã có dữ liệu") · Trên iPhone: \(probe.localTotal) bản ghi"
                )
                .font(.footnote)
                .foregroundStyle(.secondary)
                .accessibilityIdentifier("financeSync.probeSummary")
                Button {
                    pendingConfirm = .upload
                } label: {
                    Label(
                        "Đưa dữ liệu iPhone lên web",
                        systemImage: "square.and.arrow.up"
                    )
                }
                .accessibilityIdentifier("financeSync.choice.upload")
                .disabled(coordinator.isBootstrapping)
                Button {
                    pendingConfirm = .download
                } label: {
                    Label(
                        "Tải dữ liệu từ web về iPhone",
                        systemImage: "square.and.arrow.down"
                    )
                }
                .accessibilityIdentifier("financeSync.choice.download")
                .disabled(coordinator.isBootstrapping)
            }
            if coordinator.isBootstrapping {
                HStack(spacing: 8) {
                    ProgressView()
                    Text("Đang thiết lập đồng bộ…")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
                .accessibilityIdentifier("financeSync.bootstrapping")
            }
        } header: {
            Text("Thiết lập")
        } footer: {
            Text(setupFooter(probe))
        }
    }

    // MARK: - Run controls

    private func actionsSection(_ coordinator: FinanceSyncCoordinator)
        -> some View
    {
        Section {
            if coordinator.enabled {
                Button {
                    Task { await coordinator.syncNow(fullScan: true) }
                } label: {
                    Label("Đồng bộ ngay", systemImage: "arrow.clockwise")
                }
                .accessibilityIdentifier("financeSync.syncNow")
                .disabled(
                    coordinator.isSyncing || coordinator.isBootstrapping
                        || !signedIn
                )
                Button {
                    Task { await coordinator.pause() }
                } label: {
                    Label("Tạm dừng đồng bộ", systemImage: "pause.fill")
                }
                .accessibilityIdentifier("financeSync.pause")
            } else {
                Button {
                    Task { await coordinator.resume() }
                } label: {
                    Label("Tiếp tục đồng bộ", systemImage: "play.fill")
                }
                .accessibilityIdentifier("financeSync.resume")
            }
            Button(role: .destructive) {
                showsDisconnectConfirm = true
            } label: {
                Label("Ngắt kết nối", systemImage: "xmark.icloud")
            }
            .accessibilityIdentifier("financeSync.disconnect")
            if coordinator.isSyncing {
                HStack(spacing: 8) {
                    ProgressView()
                    Text("Đang đồng bộ…")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
                .accessibilityIdentifier("financeSync.syncing")
            }
            if coordinator.isBootstrapping {
                HStack(spacing: 8) {
                    ProgressView()
                    Text("Đang thiết lập…")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
            }
        } footer: {
            Text("Dữ liệu đồng bộ hai chiều — sửa trên iPhone hay trên web đều về cùng một bản. Khi một bản ghi bị sửa ở cả hai phía, thay đổi trên iPhone được giữ và đẩy lên web.")
        }
    }

    // MARK: - Quarantine

    private func quarantineSection(_ coordinator: FinanceSyncCoordinator)
        -> some View
    {
        Section("Bản ghi bị từ chối (\(coordinator.quarantined.count))") {
            ForEach(coordinator.quarantined, id: \.recordID) { entry in
                VStack(alignment: .leading, spacing: 2) {
                    Text(
                        "\(entityName(entry.entity)) · \(entry.recordID.uuidString.prefix(8))"
                    )
                    .font(.callout.weight(.medium))
                    Text(entry.message)
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
                .accessibilityIdentifier(
                    "financeSync.quarantine.\(entry.recordID)")
            }
        }
    }

    // MARK: - Helpers

    private func reloadSignIn() async {
        signedIn = await coordinator?.checkSignedIn() ?? false
    }

    private func runProbe() async {
        guard let coordinator else { return }
        isProbing = true
        probeError = nil
        defer { isProbing = false }
        do {
            probe = try await coordinator.probe()
        } catch {
            probeError = FinanceSyncCoordinator.errorText(error)
        }
    }

    private func confirmMessage(_ mode: FinanceSyncEnableMode) -> String {
        switch mode {
        case .upload:
            return "Toàn bộ \(probe?.localTotal ?? 0) bản ghi trên iPhone sẽ được đưa lên web và THAY THẾ mọi dữ liệu đang có ở đó. Không thể hoàn tác."
        case .download:
            return "Toàn bộ dữ liệu trên web sẽ được tải về và THAY THẾ mọi dữ liệu đang có trên iPhone này. Không thể hoàn tác."
        }
    }

    private func setupFooter(_ probe: FinanceSyncProbe?) -> String {
        guard let probe else {
            return "Dữ liệu được đồng bộ hai chiều giữa iPhone và web qua tài khoản AM Experience của bạn."
        }
        switch probe.recommendedMode {
        case .upload:
            return "Đề xuất: đưa dữ liệu iPhone lên — web đang trống. Mỗi lựa chọn đều THAY TOÀN BỘ dữ liệu ở phía còn lại."
        case .download:
            return "Đề xuất: tải dữ liệu từ web về — iPhone chỉ có dữ liệu mẫu. Mỗi lựa chọn đều THAY TOÀN BỘ dữ liệu ở phía còn lại."
        case nil:
            return "Cả hai phía đều có dữ liệu — lựa chọn sẽ THAY TOÀN BỘ dữ liệu ở phía còn lại."
        }
    }

    private func syncStateText(_ coordinator: FinanceSyncCoordinator)
        -> String
    {
        if coordinator.enabled { return "Đang bật" }
        return coordinator.configured ? "Đang tạm dừng" : "Chưa bật"
    }

    private func reportText(_ report: FinanceSyncReport) -> String {
        "Đã nhận \(report.applied + report.deletedLocally) · Đã gửi \(report.pushedUpserts + report.pushedDeletes) · Giữ bản trên máy \(report.conflictsKeptLocal) · Bị từ chối \(report.quarantined)"
    }

    /// `SyncEntity` raw value → the Vietnamese label used elsewhere.
    private func entityName(_ entity: String) -> String {
        switch entity {
        case SyncEntity.account.rawValue: return "Tài khoản"
        case SyncEntity.category.rawValue: return "Danh mục"
        case SyncEntity.business.rawValue: return "Mảng kinh doanh"
        case SyncEntity.transaction.rawValue: return "Giao dịch"
        case SyncEntity.loanRateChange.rawValue: return "Đợt đổi lãi suất"
        case SyncEntity.budget.rawValue: return "Ngân sách"
        case SyncEntity.recurringRule.rawValue: return "Quy tắc lặp lại"
        case SyncEntity.rentalUnit.rawValue: return "Phòng cho thuê"
        case SyncEntity.rentalLease.rawValue: return "Hợp đồng thuê"
        default: return entity
        }
    }
}
