import SwiftUI
import SwiftData

/// Sheet to create or edit an AI provider profile (nil = create). Owns its
/// NavigationStack. The API key is written through a SecureField and only
/// ever lands in the Keychain — after saving the field shows "đã lưu".
struct AIProfileEditView: View {
    @Environment(\.dismiss) private var dismiss

    private let profile: AIProviderProfile?
    private let store: AIProviderStore
    private let urlSession: URLSession

    @State private var draft: AIProfileDraft
    @State private var checking = false
    @State private var checkResult: CheckOutcome?
    @State private var fetchingModels = false
    @State private var fetchedModels: [String]?
    @State private var saveError: String?

    /// Inline outcome under "Kiểm tra kết nối".
    struct CheckOutcome: Equatable {
        var text: String
        var isError: Bool
    }

    init(
        profile: AIProviderProfile? = nil,
        store: AIProviderStore,
        urlSession: URLSession = .shared
    ) {
        self.profile = profile
        self.store = store
        self.urlSession = urlSession
        let hasSavedKey = profile.flatMap { try? store.apiKey(for: $0.id) } != nil
        if let profile {
            _draft = State(initialValue: AIProfileDraft(
                profile: profile, hasSavedKey: hasSavedKey))
        } else {
            var fresh = AIProfileDraft()
            fresh.applyStyleDefaults()
            _draft = State(initialValue: fresh)
        }
    }

    private var isNew: Bool { profile == nil }

    var body: some View {
        NavigationStack {
            Form {
                providerSection
                connectionSection
                tuningSection
                checkSection
            }
            .navigationTitle(isNew ? "Cấu hình AI mới" : "Sửa cấu hình AI")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Huỷ") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button(isNew ? "Thêm" : "Lưu", action: save)
                        .disabled(!draft.isValid)
                }
            }
            .alert(
                "Không lưu được",
                isPresented: .init(
                    get: { saveError != nil },
                    set: { if !$0 { saveError = nil } }
                )
            ) {
                Button("Đóng", role: .cancel) {}
            } message: {
                Text(saveError ?? "")
            }
        }
    }

    // MARK: - Sections

    private var providerSection: some View {
        Section("Nhà cung cấp") {
            TextField("Tên hiển thị", text: $draft.name)
            Picker("Kiểu API", selection: $draft.style) {
                ForEach(AIAPIStyle.allCases, id: \.self) { style in
                    Text(style.displayName).tag(style)
                }
            }
            .onChange(of: draft.style) { _, _ in draft.applyStyleDefaults() }
            TextField("Địa chỉ máy chủ", text: $draft.baseURL)
                .font(.callout.monospaced())
                .keyboardType(.URL)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
            if let error = draft.baseURLError {
                Label(error.localizedDescription,
                      systemImage: "exclamationmark.triangle.fill")
                    .font(.footnote)
                    .foregroundStyle(.orange)
            } else if let normalized = draft.normalizedBaseURLString {
                Text("Sẽ gọi: \(normalized)")
                    .font(.footnote.monospaced())
                    .foregroundStyle(.secondary)
            }
        }
    }

    private var connectionSection: some View {
        Section {
            SecureField("Khoá API", text: $draft.apiKey)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
            if draft.hasSavedKey {
                Label("Đã lưu khoá — nhập khoá mới để thay thế.",
                      systemImage: "key.fill")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            } else {
                Text("Chưa có khoá — lưu trong Keychain của máy.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
            modelRow
            TextField("Model nhận ảnh (không bắt buộc)", text: $draft.visionModel)
                .font(.callout.monospaced())
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
            TextField(
                "Header bổ sung — mỗi dòng \"Tên: giá trị\"",
                text: $draft.extraHeaders, axis: .vertical
            )
            .font(.callout.monospaced())
            .lineLimit(2...4)
            .textInputAutocapitalization(.never)
            .autocorrectionDisabled()
            if !draft.extraHeadersValid {
                Label(
                    AIError.invalidExtraHeaders.localizedDescription,
                    systemImage: "exclamationmark.triangle.fill")
                    .font(.footnote)
                    .foregroundStyle(.orange)
            }
        } header: {
            Text("Kết nối")
        } footer: {
            Text("Model nhận ảnh được dùng khi yêu cầu có hình ảnh; để trống sẽ dùng model chính.")
        }
    }

    @ViewBuilder
    private var modelRow: some View {
        if let fetchedModels, !fetchedModels.isEmpty {
            Picker("Model", selection: $draft.model) {
                ForEach(fetchedModels, id: \.self) { id in
                    Text(id).tag(id)
                }
                if !fetchedModels.contains(draft.model), !draft.model.isEmpty {
                    Text(draft.model).tag(draft.model)
                }
            }
        } else {
            TextField("Model", text: $draft.model)
                .font(.callout.monospaced())
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
        }
        if draft.style == .openAICompatible {
            Button {
                Task { await fetchModels() }
            } label: {
                if fetchingModels {
                    HStack {
                        ProgressView()
                        Text("Đang tải danh sách model…")
                            .font(.callout)
                    }
                } else {
                    Label("Tải danh sách model", systemImage: "arrow.clockwise")
                }
            }
            .disabled(fetchingModels || draft.baseURLError != nil)
        }
    }

    private var tuningSection: some View {
        Section {
            VStack(alignment: .leading, spacing: 4) {
                HStack {
                    Text("Nhiệt độ (temperature)")
                    Spacer()
                    Text(draft.temperature.formatted(.number.precision(.fractionLength(2))))
                        .monospacedDigit()
                        .foregroundStyle(.secondary)
                }
                Slider(value: $draft.temperature, in: 0...1, step: 0.05)
            }
            Stepper(
                "Token tối đa: \(draft.maxTokens)",
                value: $draft.maxTokens, in: 16...200_000, step: 256)
            Stepper(
                "Chờ tối đa: \(Int(draft.timeout)) giây",
                value: $draft.timeout, in: 5...600, step: 5)
            Toggle("Chế độ JSON (response_format)", isOn: $draft.supportsJSONMode)
                .disabled(draft.style == .anthropic)
        } header: {
            Text("Tuỳ chỉnh")
        } footer: {
            if draft.style == .anthropic {
                Text("Anthropic không có JSON mode — prompt đã yêu cầu JSON và ứng dụng tự bóc JSON đầu tiên từ câu trả lời.")
            }
        }
    }

    private var checkSection: some View {
        Section {
            Button {
                Task { await check() }
            } label: {
                if checking {
                    HStack {
                        ProgressView()
                        Text("Đang kiểm tra…").font(.callout)
                    }
                } else {
                    Label("Kiểm tra kết nối",
                          systemImage: "antenna.radiowaves.left.and.right")
                }
            }
            .disabled(checking || !draft.isValid || !hasKey)
            if let checkResult {
                Label(
                    checkResult.text,
                    systemImage: checkResult.isError
                        ? "exclamationmark.triangle.fill" : "checkmark.circle.fill"
                )
                .font(.footnote)
                .foregroundStyle(checkResult.isError ? Color.red : Color.green)
            }
        } header: {
            Text("Kiểm tra")
        } footer: {
            Text("Gửi một prompt nhỏ tới model để thử kết nối, khoá API và tên model.")
        }
    }

    // MARK: - Helpers

    private var hasKey: Bool {
        !draft.apiKey.isEmpty || draft.hasSavedKey
    }

    /// Builds a client for the current draft using the typed key, or the
    /// already-saved one when the field is empty.
    private func makeClient() throws -> AIClient {
        let candidate = draft.makeProfile(id: profile?.id ?? UUID())
        let key: String
        if !draft.apiKey.isEmpty {
            key = draft.apiKey
        } else if let saved = try store.apiKey(for: candidate.id) {
            key = saved
        } else {
            throw AIError.notConfigured
        }
        return AIClient(profile: candidate, apiKey: key, urlSession: urlSession)
    }

    private func check() async {
        checking = true
        defer { checking = false }
        do {
            let result = try await makeClient().testConnection()
            let latency = String(format: "%.1f", result.latency)
            checkResult = CheckOutcome(
                text: "Kết nối tốt (\(latency)s) — trả lời: \(result.reply)",
                isError: false)
        } catch {
            checkResult = CheckOutcome(
                text: error.localizedDescription, isError: true)
        }
    }

    private func fetchModels() async {
        fetchingModels = true
        defer { fetchingModels = false }
        do {
            let ids = try await makeClient().listModels()
            fetchedModels = ids
            checkResult = nil
        } catch let error as AIError where error == .modelListingUnsupported {
            fetchedModels = nil
            checkResult = CheckOutcome(
                text: error.localizedDescription, isError: false)
        } catch {
            fetchedModels = nil
            checkResult = CheckOutcome(
                text: error.localizedDescription, isError: true)
        }
    }

    private func save() {
        guard draft.isValid else { return }
        let saved = draft.makeProfile(
            id: profile?.id ?? UUID(), createdAt: profile?.createdAt ?? .now)
        store.save(saved)
        if !draft.apiKey.isEmpty {
            do {
                try store.setAPIKey(draft.apiKey, for: saved.id)
            } catch {
                saveError = error.localizedDescription
                return
            }
        }
        dismiss()
    }
}

#Preview("Tạo mới") {
    let container = try! AppModelContainer.make(inMemory: true)
    try! SeedData.seedIfNeeded(context: ModelContext(container))
    let store = AIProviderStore(
        defaults: UserDefaults(suiteName: "AIEditPreview.\(UUID().uuidString)")!,
        keyStore: AIInMemoryAPIKeyStore())
    return AIProfileEditView(store: store)
        .modelContainer(container)
}

#Preview("Sửa") {
    let container = try! AppModelContainer.make(inMemory: true)
    try! SeedData.seedIfNeeded(context: ModelContext(container))
    let store = AIProviderStore(
        defaults: UserDefaults(suiteName: "AIEditPreview2.\(UUID().uuidString)")!,
        keyStore: AIInMemoryAPIKeyStore())
    let profile = AIProviderProfile(
        name: "OpenAI của tôi", style: .openAICompatible,
        baseURL: "https://api.openai.com/v1", model: "gpt-4o-mini")
    store.save(profile)
    try! store.setAPIKey("sk-preview", for: profile.id)
    return AIProfileEditView(profile: profile, store: store)
        .modelContainer(container)
}
