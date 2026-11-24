import SwiftUI
import SwiftData

/// "Xoá dữ liệu" — the two-level reset reached from Settings → Dữ liệu,
/// last row, destructive style so it is never hit by accident.
///
/// Safety flow for either level: the screen first pushes a backup
/// reminder (link + last export date), then a confirmation dialog
/// carrying the exact row counts, then an alert that only enables the
/// destructive button after "XOA" is typed — and when the app lock is on,
/// a system authentication must succeed before anything is deleted.
/// A successful reset posts `.dataResetCompleted`; the app rebuilds its
/// root view tree so no screen keeps a deleted object.
/// Pushed inside an existing NavigationStack — no stack of its own.
struct DataResetView: View {
    @Environment(\.modelContext) private var context

    /// Last successful JSON backup — the same `@AppStorage` key
    /// `BackupView` writes on export.
    @AppStorage("backupLastExportAt") private var lastExportTimestamp = 0.0

    private let service: DataResetService
    private let authenticator: any AppLockAuthenticating
    /// App-lock gate: a system authentication must pass before deleting.
    private let requiresAuthentication: Bool

    @State private var summaryTransactions = DataResetSummary()
    @State private var summaryEverything = DataResetSummary()
    /// Level waiting on the first confirmation step (dialog).
    @State private var dialogLevel: DataResetLevel?
    /// Level waiting on the typed "XOA" step (alert with a text field).
    @State private var typingLevel: DataResetLevel?
    @State private var confirmText = ""
    @State private var isWorking = false
    /// Success text — dismissing its alert rebuilds the root view.
    @State private var doneMessage: String?
    @State private var errorMessage: String?

    init(
        service: DataResetService = DataResetService(),
        authenticator: any AppLockAuthenticating = AppLockAuthenticator(),
        lockSettings: AppLockSettingsStore = AppLockSettingsStore()
    ) {
        self.service = service
        self.authenticator = authenticator
        // UI-test launches force the lock off app-wide; the same flag
        // must skip this gate or the smoke test would block on a
        // biometric prompt that never answers.
        self.requiresAuthentication = lockSettings.load().isEnabled
            && !AppLockSettingsStore.isUITestLaunch()
    }

    var body: some View {
        Form {
            backupSection
            transactionsSection
            everythingSection
        }
        .navigationTitle("Xoá dữ liệu")
        .task { reloadCounts() }
        .confirmationDialog(
            "Xoá dữ liệu?",
            isPresented: Binding(
                get: { dialogLevel != nil },
                set: { if !$0 { dialogLevel = nil } }
            ),
            titleVisibility: .visible,
            presenting: dialogLevel
        ) { level in
            Button(
                level.confirmTitle(summary: summary(for: level)),
                role: .destructive
            ) {
                dialogLevel = nil
                confirmText = ""
                typingLevel = level
            }
            Button("Huỷ", role: .cancel) {}
        } message: { level in
            Text(level.dialogMessage(summary: summary(for: level)))
        }
        .alert(
            "Nhập XOA để xác nhận",
            isPresented: Binding(
                get: { typingLevel != nil },
                set: { if !$0 { typingLevel = nil } }
            ),
            presenting: typingLevel
        ) { level in
            TextField("XOA", text: $confirmText)
                .textInputAutocapitalization(.characters)
                .autocorrectionDisabled()
            Button("Xoá", role: .destructive) {
                typingLevel = nil
                Task { await perform(level) }
            }
            .disabled(!DataResetConfirmation.matches(confirmText))
            Button("Huỷ", role: .cancel) {}
        } message: { _ in
            Text("Gõ XOA để mở khoá nút xoá. Thao tác này không thể hoàn tác.")
        }
        .alert(
            "Đã xoá dữ liệu",
            isPresented: Binding(
                get: { doneMessage != nil },
                set: { if !$0 { doneMessage = nil } }
            ),
            presenting: doneMessage
        ) { _ in
            Button("OK") {
                doneMessage = nil
                NotificationCenter.default.post(
                    name: .dataResetCompleted, object: nil)
            }
        } message: { message in
            Text(message)
        }
        .alert(
            "Không xoá được",
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

    // MARK: - Sections

    private var backupSection: some View {
        Section {
            NavigationLink {
                BackupView()
            } label: {
                Label("Sao lưu & khôi phục", systemImage: "icloud.fill")
            }
            LabeledContent("Sao lưu gần nhất", value: lastBackupText)
        } header: {
            Text("Sao lưu trước")
        } footer: {
            Text("Hãy xuất một bản sao lưu JSON trước khi xoá — đó là cách duy nhất để lấy lại dữ liệu sau này.")
        }
    }

    private var transactionsSection: some View {
        Section {
            Button(role: .destructive) {
                dialogLevel = .transactions
            } label: {
                Label("Xoá toàn bộ giao dịch", systemImage: "trash.fill")
            }
            .disabled(isWorking)
        } header: {
            Text("Mức 1 — chỉ giao dịch")
        } footer: {
            Text("Sẽ xoá \(summaryTransactions.total) giao dịch. Giữ lại tài khoản (số dư về số dư đầu kỳ), danh mục, mảng kinh doanh, ngân sách, quy tắc lặp lại, phòng & hợp đồng, đợt đổi lãi suất và mọi cài đặt. Bộ nhớ nhập ngân hàng (con trỏ đồng bộ, mục đã xoá, lần nhập CSV gần nhất) cũng bị xoá để có thể nhập lại. Lịch sử hội thoại Agent cũng bị xoá.")
        }
    }

    private var everythingSection: some View {
        Section {
            Button(role: .destructive) {
                dialogLevel = .everything
            } label: {
                Label(
                    "Xoá tất cả, về trạng thái ban đầu",
                    systemImage: "trash.fill")
            }
            .disabled(isWorking)
        } header: {
            Text("Mức 2 — xoá hết")
        } footer: {
            Text("Sẽ xoá \(summaryEverything.total) mục (\(summaryEverything.breakdownText)), rồi tạo lại dữ liệu mẫu: danh mục mặc định, các mảng kinh doanh và tài khoản \"Tiền mặt\". Cũng xoá: liên kết & bộ nhớ đồng bộ ngân hàng, quy tắc tự phân loại, cột nhớ & lần nhập CSV, tuỳ chọn tính lãi từng khoản vay, lịch sử hội thoại Agent, tài khoản dùng gần nhất, ngày sao lưu gần nhất và các thông báo nhắc đang chờ. Giữ lại: đăng nhập wallet.amx.vn & Client ID, cài đặt nhắc nhở, cài đặt khoá ứng dụng.")
        }
    }

    // MARK: - Running a level

    private func summary(for level: DataResetLevel) -> DataResetSummary {
        switch level {
        case .transactions: return summaryTransactions
        case .everything: return summaryEverything
        }
    }

    private func reloadCounts() {
        summaryTransactions = (try? service.plannedSummary(
            for: .transactions, in: context)) ?? DataResetSummary()
        summaryEverything = (try? service.plannedSummary(
            for: .everything, in: context)) ?? DataResetSummary()
    }

    private var lastBackupText: String {
        guard lastExportTimestamp > 0 else { return "Chưa từng sao lưu" }
        let date = Date(timeIntervalSince1970: lastExportTimestamp)
        return AppDateFormat.dayHeader(date, now: .now)
            + " " + AppDateFormat.time(date)
    }

    private func perform(_ level: DataResetLevel) async {
        isWorking = true
        defer { isWorking = false }
        if requiresAuthentication {
            let ok = await authenticator.authenticate(
                reason: "Xác nhận xoá dữ liệu AM Finance")
            guard ok else {
                errorMessage = "Xác thực không thành công — chưa xoá gì."
                return
            }
        }
        do {
            let summary: DataResetSummary
            switch level {
            case .transactions:
                summary = try service.resetTransactions(in: context)
            case .everything:
                summary = try await service.resetEverything(in: context)
            }
            doneMessage = level.doneText(summary: summary)
        } catch {
            errorMessage = (error as? LocalizedError)?.errorDescription
                ?? "Không xoá được dữ liệu: \(error.localizedDescription)"
        }
    }
}

/// Wording for the two confirmation steps and the success notice.
private extension DataResetLevel {
    /// Destructive button inside the first-step dialog — carries the
    /// exact count so the number is re-confirmed at tap time.
    func confirmTitle(summary: DataResetSummary) -> String {
        switch self {
        case .transactions:
            return "Xoá \(summary.total) giao dịch"
        case .everything:
            return "Xoá \(summary.total) mục"
        }
    }

    func dialogMessage(summary: DataResetSummary) -> String {
        switch self {
        case .transactions:
            return "Toàn bộ \(summary.total) giao dịch sẽ bị xoá vĩnh viễn. Lịch sử hội thoại Agent cũng bị xoá. Tài khoản và mọi cài đặt được giữ lại."
        case .everything:
            return "Toàn bộ dữ liệu sẽ bị xoá vĩnh viễn: \(summary.breakdownText), lịch sử hội thoại Agent. Đăng nhập wallet.amx.vn, cài đặt nhắc nhở và khoá ứng dụng được giữ lại."
        }
    }

    func doneText(summary: DataResetSummary) -> String {
        switch self {
        case .transactions:
            return "Đã xoá \(summary.total) giao dịch. Tài khoản giữ nguyên — số dư về số dư đầu kỳ."
        case .everything:
            return "Đã xoá \(summary.total) mục (\(summary.breakdownText)) và khôi phục dữ liệu mẫu ban đầu."
        }
    }
}

#Preview {
    let container = try! AppModelContainer.make(inMemory: true)
    try! SeedData.seedIfNeeded(context: ModelContext(container))
    return NavigationStack {
        DataResetView()
    }
    .modelContainer(container)
}
