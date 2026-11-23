import SwiftUI
import SwiftData
import PhotosUI
import UIKit
import FinanceCore

/// "AI nhập chi tiêu" — a self-contained sheet (own NavigationStack) that
/// turns a typed sentence and/or bill photos into transactions the owner
/// confirms with one tap. All flow logic lives in `AICaptureModel`; this
/// view renders its phases and keeps the model's catalog in sync with the
/// SwiftData queries.
struct AICaptureView: View {
    private let providerStore: AIProviderStore

    @Environment(\.modelContext) private var context
    @Environment(\.dismiss) private var dismiss
    /// The "Tự lưu khi độ tin cậy cao" setting — mirrored into the model.
    @AppStorage("aiCapture.autoSaveHighConfidence") private var autoSave = false

    @Query(sort: \Account.sortOrder) private var accounts: [Account]
    @Query(sort: \LedgerCategory.sortOrder) private var categories: [LedgerCategory]
    @Query(sort: \Business.sortOrder) private var businesses: [Business]

    @State private var model: AICaptureModel
    @State private var providerConfigured = true
    @State private var showsSettings = false
    @State private var showsCamera = false
    @State private var photoSelection: [PhotosPickerItem] = []
    @State private var keypadItemID: UUID?
    @State private var saveFailed = false

    init(
        providerStore: AIProviderStore = AIProviderStore(),
        model: AICaptureModel? = nil
    ) {
        self.providerStore = providerStore
        _model = State(initialValue: model ?? AICaptureModel(
            makeService: { try providerStore.makeClient() }))
    }

    var body: some View {
        NavigationStack {
            content
                .navigationTitle("AI nhập chi tiêu")
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) {
                        Button("Đóng") { dismiss() }
                    }
                    ToolbarItem(placement: .primaryAction) {
                        optionsMenu
                    }
                }
                .navigationDestination(isPresented: $showsSettings) {
                    AISettingsView(store: providerStore)
                }
                .sheet(isPresented: $showsCamera) {
                    AICaptureCameraPicker(
                        onPick: { image in
                            model.addImage(image)
                            showsCamera = false
                        },
                        onCancel: { showsCamera = false }
                    )
                    .ignoresSafeArea()
                }
                .alert("Không thể lưu", isPresented: $saveFailed) {
                    Button("Đóng", role: .cancel) {}
                } message: {
                    Text("Không lưu được các giao dịch — vui lòng thử lại.")
                }
                .onAppear(perform: syncEnvironment)
                .onChange(of: autoSave) { _, value in
                    model.autoSaveEnabled = value
                }
                .onChange(of: showsSettings) { _, shown in
                    if !shown { refreshProvider() }
                }
                .onChange(of: accounts) { _, _ in syncCatalog() }
                .onChange(of: categories) { _, _ in syncCatalog() }
                .onChange(of: businesses) { _, _ in syncCatalog() }
                .onChange(of: photoSelection) { _, selection in
                    loadPickedPhotos(selection)
                }
        }
    }

    // MARK: - Phase routing

    @ViewBuilder
    private var content: some View {
        if !providerConfigured {
            EmptyStateView(
                symbol: "sparkles",
                title: "Chưa cấu hình AI",
                message: "Tính năng này cần một nhà cung cấp AI. Thêm cấu hình để chụp hoá đơn và nhập chi tiêu bằng AI.",
                actionTitle: "Mở cài đặt AI"
            ) {
                showsSettings = true
            }
        } else {
            switch model.phase {
            case .idle, .failed:
                inputForm
            case .analyzing:
                analyzingView
            case .review:
                reviewContent
            case .saved:
                AICaptureSavedView(
                    model: model,
                    onDone: { dismiss() },
                    onUndo: { model.undoSaved(context: context) }
                )
            }
        }
    }

    private var optionsMenu: some View {
        Menu {
            Toggle("Tự lưu khi độ tin cậy cao", isOn: $autoSave)
            Divider()
            Button {
                showsSettings = true
            } label: {
                Label("Cài đặt AI", systemImage: "gearshape")
            }
        } label: {
            Image(systemName: "ellipsis.circle")
                .accessibilityLabel("Tuỳ chọn")
        }
    }

    // MARK: - Input

    private var inputForm: some View {
        Form {
            if case .failed(let message) = model.phase {
                Section {
                    Label(message, systemImage: "exclamationmark.triangle.fill")
                        .foregroundStyle(.orange)
                    Button {
                        model.startAnalysis(context: context)
                    } label: {
                        Label("Thử lại", systemImage: "arrow.clockwise")
                    }
                    .disabled(!model.canAnalyze)
                }
            }

            Section {
                TextField(
                    "Ví dụ: nhậu với Tuấn 1tr2 thẻ VPBank",
                    text: $model.prompt, axis: .vertical
                )
                .lineLimit(2...6)

                if !model.images.isEmpty {
                    thumbnails
                }

                if UIImagePickerController.isSourceTypeAvailable(.camera) {
                    Button {
                        showsCamera = true
                    } label: {
                        Label("Chụp ảnh", systemImage: "camera.fill")
                    }
                    .disabled(!canAddImage)
                }
                PhotosPicker(
                    selection: $photoSelection,
                    maxSelectionCount: max(1, remainingPhotoSlots),
                    matching: .images
                ) {
                    Label("Thư viện ảnh", systemImage: "photo.on.rectangle")
                }
                .disabled(!canAddImage)
            } header: {
                Text("Hoá đơn & mô tả")
            } footer: {
                Text("Ảnh chỉ được gửi tới nhà cung cấp AI đã cấu hình khi bấm \"Phân tích\", và không được lưu lại sau đó.")
            }

            Section {
                Button {
                    model.startAnalysis(context: context)
                } label: {
                    Label("Phân tích", systemImage: "sparkles")
                        .frame(maxWidth: .infinity)
                }
                .disabled(!model.canAnalyze)
            }
        }
        .scrollDismissesKeyboard(.interactively)
    }

    private var canAddImage: Bool {
        model.images.count < AICaptureModel.maxImages
    }

    private var remainingPhotoSlots: Int {
        AICaptureModel.maxImages - model.images.count
    }

    private var thumbnails: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 10) {
                ForEach(Array(model.images.enumerated()), id: \.offset) { index, image in
                    Image(uiImage: image)
                        .resizable()
                        .scaledToFill()
                        .frame(width: 64, height: 64)
                        .clipShape(RoundedRectangle(cornerRadius: 10))
                        .overlay(alignment: .topTrailing) {
                            Button {
                                model.images.remove(at: index)
                            } label: {
                                Image(systemName: "xmark.circle.fill")
                                    .symbolRenderingMode(.palette)
                                    .foregroundStyle(.white, Color(.darkGray))
                            }
                            .offset(x: 6, y: -6)
                            .accessibilityLabel("Xoá ảnh \(index + 1)")
                        }
                }
            }
            .padding(.vertical, 6)
        }
    }

    private func loadPickedPhotos(_ selection: [PhotosPickerItem]) {
        guard !selection.isEmpty else { return }
        photoSelection = []
        let slots = remainingPhotoSlots
        Task {
            for item in selection.prefix(slots) {
                if let data = try? await item.loadTransferable(type: Data.self),
                   let image = UIImage(data: data) {
                    model.addImage(image)
                }
            }
        }
    }

    // MARK: - Analyzing

    private var analyzingView: some View {
        VStack(spacing: 16) {
            Spacer()
            ProgressView()
                .controlSize(.large)
            Text("Đang phân tích…")
                .font(.headline)
            Text("AI đang đọc hoá đơn và nội dung bạn nhập.")
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
            Button("Huỷ") { model.cancelAnalysis() }
                .buttonStyle(.bordered)
            Spacer()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding()
        .background(Color(.systemGroupedBackground))
    }

    // MARK: - Review

    @ViewBuilder
    private var reviewContent: some View {
        if model.items.isEmpty {
            nothingExtractedView
        } else {
            reviewForm
        }
    }

    private var nothingExtractedView: some View {
        VStack(spacing: 8) {
            EmptyStateView(
                symbol: "doc.questionmark",
                title: "Không đọc được giao dịch",
                message: model.modelMessage
                    ?? "AI không trích xuất được giao dịch nào. Thử mô tả rõ hơn hoặc chụp ảnh nét hơn.",
                actionTitle: model.canAnalyze ? "Thử lại" : nil
            ) {
                model.startAnalysis(context: context)
            }
            Button("Nhập lại") { model.backToInput() }
                .buttonStyle(.bordered)
        }
    }

    private var reviewForm: some View {
        Form {
            if !model.rejections.isEmpty {
                Section {
                    ForEach(model.rejections, id: \.index) { rejection in
                        Label(
                            "Dòng \(rejection.index + 1): \(rejection.reason)",
                            systemImage: "exclamationmark.circle"
                        )
                        .font(.footnote)
                        .foregroundStyle(.orange)
                    }
                } header: {
                    Text("\(model.rejections.count) dòng không đọc được")
                }
            }

            ForEach($model.items) { $item in
                AICaptureItemCard(
                    item: $item,
                    catalog: model.catalog,
                    index: (model.items.firstIndex { $0.id == item.id } ?? 0) + 1,
                    keypadItemID: $keypadItemID,
                    onRemove: { model.removeItem(item) }
                )
            }

            Section {
                Button {
                    saveAll()
                } label: {
                    Label("Lưu tất cả", systemImage: "checkmark.circle.fill")
                        .frame(maxWidth: .infinity)
                }
                .disabled(!model.canSaveAll)
            } footer: {
                if !model.canSaveAll {
                    Text("Có giao dịch chưa đủ thông tin — hãy sửa hoặc xoá trước khi lưu.")
                } else if let message = model.modelMessage {
                    Text(message)
                }
            }
        }
        .scrollDismissesKeyboard(.interactively)
    }

    private func saveAll() {
        do {
            try model.saveAll(context: context)
        } catch {
            saveFailed = true
        }
    }

    // MARK: - Environment sync

    private func syncEnvironment() {
        refreshProvider()
        syncCatalog()
        model.autoSaveEnabled = autoSave
    }

    private func syncCatalog() {
        model.catalog = AICaptureCatalog(
            categories: categories, accounts: accounts, businesses: businesses)
    }

    private func refreshProvider() {
        providerConfigured = (try? providerStore.makeClient()) != nil
    }
}

/// One editable extraction card — a Form section per item so the review
/// list keeps the system inset-grouped look. The delete button and the
/// confidence badge sit in the section header.
private struct AICaptureItemCard: View {
    @Binding var item: AICaptureItem
    let catalog: AICaptureCatalog
    let index: Int
    @Binding var keypadItemID: UUID?
    var onRemove: () -> Void

    var body: some View {
        Section {
            kindPicker
            amountRow
            if keypadItemID == item.id {
                AmountKeypad(amount: $item.amount)
                    .padding(.vertical, 4)
            }
            accountPicker(
                title: "Tài khoản", selection: $item.accountID, excluding: nil)
            if item.kind == .transfer {
                accountPicker(
                    title: "Đến tài khoản", selection: $item.toAccountID,
                    excluding: item.accountID)
            }
            if item.kind != .transfer {
                categoryPicker
                businessPicker
            }
            DatePicker(
                "Thời gian", selection: $item.date,
                displayedComponents: [.date, .hourAndMinute])
            TextField("Ghi chú", text: $item.note)
            hintRows
        } header: {
            HStack {
                Text("Giao dịch \(index)")
                Spacer()
                confidenceBadge
                Button(role: .destructive, action: onRemove) {
                    Image(systemName: "trash")
                }
                .accessibilityLabel("Xoá giao dịch \(index)")
            }
        }
    }

    private var kindPicker: some View {
        Picker("Loại giao dịch", selection: Binding(
            get: { item.kind },
            set: { item.setKind($0, catalog: catalog) }
        )) {
            ForEach(TransactionKind.allCases, id: \.self) { kind in
                Text(kind.displayName).tag(kind)
            }
        }
        .pickerStyle(.segmented)
    }

    private var amountRow: some View {
        Button {
            withAnimation(.snappy(duration: 0.2)) {
                keypadItemID = keypadItemID == item.id ? nil : item.id
            }
        } label: {
            HStack {
                Text("Số tiền")
                Spacer()
                AmountText(amount: item.amount, kind: item.kind)
                    .font(.title3.weight(.semibold))
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityHint(keypadItemID == item.id
            ? "Chạm để ẩn bàn phím" : "Chạm để hiện bàn phím")
    }

    private func accountPicker(
        title: String,
        selection: Binding<UUID?>,
        excluding excludedID: UUID?
    ) -> some View {
        Picker(selection: selection) {
            Text("Chưa chọn").tag(UUID?.none)
            ForEach(
                catalog.usableAccounts.filter { $0.id != excludedID },
                id: \.id
            ) { account in
                Label {
                    HStack {
                        Text(account.name)
                        Spacer(minLength: 8)
                        AmountText(amount: account.balance, compact: true)
                            .font(.subheadline)
                    }
                } icon: {
                    IconBadge(
                        symbol: account.icon, colorHex: account.colorHex,
                        size: 28)
                }
                .tag(account.id as UUID?)
            }
        } label: {
            Text(title)
        }
        .pickerStyle(.navigationLink)
    }

    private var categoryPicker: some View {
        let wanted = TransactionDraft.categoryKind(for: item.kind)
        let options = catalog.usableCategories.filter { $0.kind == wanted }
        return Picker(selection: $item.categoryID) {
            Text("Không có").tag(UUID?.none)
            ForEach(options, id: \.id) { category in
                Label {
                    Text(category.name)
                } icon: {
                    IconBadge(
                        symbol: category.icon, colorHex: category.colorHex,
                        size: 28)
                }
                .tag(category.id as UUID?)
            }
        } label: {
            Text("Danh mục")
        }
        .pickerStyle(.navigationLink)
    }

    private var businessPicker: some View {
        Picker(selection: $item.businessID) {
            Text("Cá nhân").tag(UUID?.none)
            ForEach(catalog.usableBusinesses, id: \.id) { business in
                Label {
                    Text(business.name)
                } icon: {
                    IconBadge(
                        symbol: business.icon, colorHex: business.colorHex,
                        size: 28)
                }
                .tag(business.id as UUID?)
            }
        } label: {
            Text("Kinh doanh")
        }
        .pickerStyle(.navigationLink)
    }

    /// Extraction warnings and low-confidence hints in orange; blocking
    /// validation issues in red.
    @ViewBuilder
    private var hintRows: some View {
        let issues = item.validationIssues(in: catalog)
        ForEach(issues, id: \.self) { issue in
            Label(issueMessage(issue), systemImage: "exclamationmark.circle.fill")
                .font(.footnote)
                .foregroundStyle(.red)
        }
        ForEach(Array(item.warnings.enumerated()), id: \.offset) { _, warning in
            Label(warning, systemImage: "exclamationmark.triangle")
                .font(.footnote)
                .foregroundStyle(.orange)
        }
        if issues.isEmpty && item.confidence < AICaptureModel.autoSaveConfidence {
            Label(
                "Độ tin cậy \(Int((item.confidence * 100).rounded()))% — hãy kiểm tra lại các trường.",
                systemImage: "questionmark.circle"
            )
            .font(.footnote)
            .foregroundStyle(.orange)
        }
    }

    private func issueMessage(_ issue: TransactionDraftError) -> String {
        switch issue {
        case .missingAmount: return "Chưa có số tiền."
        case .missingAccount: return "Chưa chọn tài khoản."
        case .missingDestination: return "Chuyển khoản cần tài khoản đích."
        case .sameSourceAndDestination: return "Tài khoản đích trùng tài khoản nguồn."
        case .categoryKindMismatch: return "Danh mục không hợp loại giao dịch."
        }
    }

    private var confidenceBadge: some View {
        let percent = Int((item.confidence * 100).rounded())
        let color: Color = item.confidence >= 0.9 ? .green
            : item.confidence >= 0.6 ? .orange : .red
        return Text("\(percent)%")
            .font(.caption.weight(.semibold))
            .padding(.horizontal, 8)
            .padding(.vertical, 3)
            .background(color.opacity(0.15), in: Capsule())
            .foregroundStyle(color)
    }
}

/// Full-sheet confirmation after a save — lists what was inserted and
/// offers undo while the auto-save window is open. Dismisses itself once
/// the undo deadline passes (or shortly after a manual save).
private struct AICaptureSavedView: View {
    let model: AICaptureModel
    var onDone: () -> Void
    var onUndo: () -> Void

    var body: some View {
        VStack(spacing: 14) {
            Spacer()
            Image(systemName: "checkmark.circle.fill")
                .font(.system(size: 56))
                .foregroundStyle(.green)
            Text("Đã lưu \(model.savedTransactions.count) giao dịch")
                .font(.headline)
            if model.savedAutomatically {
                Text("Đã tự lưu vì mọi giao dịch đều đạt độ tin cậy cao.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
            }
            if !model.savedTransactions.isEmpty {
                List(model.savedTransactions, id: \.id) { transaction in
                    AICaptureSavedRow(transaction: transaction)
                }
                .listStyle(.plain)
                .frame(maxHeight: 240)
            }
            if model.undoDeadline != nil {
                Button(action: onUndo) {
                    Label("Hoàn tác", systemImage: "arrow.uturn.backward")
                }
                .buttonStyle(.bordered)
            }
            Button("Xong", action: onDone)
                .buttonStyle(.borderedProminent)
            Spacer()
        }
        .padding()
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color(.systemGroupedBackground))
        .task { await autoDismiss() }
    }

    /// Manual saves flash the confirmation briefly; auto-saves stay until
    /// the undo window closes. If the owner undoes meanwhile this view is
    /// gone and the task is cancelled.
    private func autoDismiss() async {
        let deadline = model.undoDeadline ?? Date.now.addingTimeInterval(1.6)
        let delay = max(0.1, deadline.timeIntervalSinceNow)
        try? await Task.sleep(for: .seconds(delay))
        guard !Task.isCancelled, model.phase == .saved else { return }
        onDone()
    }
}

/// One inserted row on the saved screen: signed amount, note, account(s).
private struct AICaptureSavedRow: View {
    let transaction: LedgerTransaction

    var body: some View {
        HStack(spacing: 10) {
            IconBadge(
                symbol: symbol, colorHex: "34C759", size: 28)
            VStack(alignment: .leading, spacing: 2) {
                Text(transaction.note.isEmpty
                     ? transaction.kind.displayName : transaction.note)
                    .font(.subheadline)
                    .lineLimit(1)
                Text(accountsLabel)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            Spacer(minLength: 8)
            AmountText(amount: transaction.amount, kind: transaction.kind)
                .font(.subheadline)
        }
    }

    private var symbol: String {
        switch transaction.kind {
        case .income: return "arrow.down.circle.fill"
        case .expense: return "arrow.up.circle.fill"
        case .transfer: return "arrow.left.arrow.right.circle.fill"
        }
    }

    private var accountsLabel: String {
        let from = transaction.account?.name ?? "—"
        if transaction.kind == .transfer {
            return "\(from) → \(transaction.toAccount?.name ?? "—")"
        }
        return from
    }
}

#Preview {
    let container = try! AppModelContainer.make(inMemory: true)
    let context = ModelContext(container)
    try! SeedData.seedIfNeeded(context: context)

    let suiteName = "AICapturePreview.\(UUID().uuidString)"
    let store = AIProviderStore(
        defaults: UserDefaults(suiteName: suiteName)!,
        keyStore: AIInMemoryAPIKeyStore())
    let profile = AIProviderProfile(
        name: "Demo", baseURL: "https://api.demo/v1", model: "demo-1")
    store.save(profile)
    try? store.setAPIKey("preview-key", for: profile.id)

    struct PreviewService: AICaptureServicing {
        func complete(_ request: AIRequest) async throws -> AIResponse {
            try? await Task.sleep(for: .seconds(1))
            return AIResponse(
                text: """
                {"items":[
                  {"kind":"expense","amount":1200000,"note":"Nhậu với Tuấn",
                   "category":"Ăn nhậu","account":"Tiền mặt","confidence":0.93},
                  {"kind":"expense","amount":85000,"note":"Ăn trưa",
                   "category":"Ăn uống","account":"Tiền mặt","confidence":0.7}
                ]}
                """,
                model: "demo-1", inputTokens: nil, outputTokens: nil)
        }
    }
    let model = AICaptureModel(makeService: { PreviewService() })
    return AICaptureView(providerStore: store, model: model)
        .modelContainer(container)
}
