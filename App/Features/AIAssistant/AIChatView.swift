import SwiftUI
import SwiftData
import FinanceCore

/// Trò chuyện với trợ lý AI về tài chính của chủ nhân. Pushed inside an
/// existing NavigationStack — no stack of its own.
///
/// Top: data-scope chips and the privacy switches; below: preset prompt
/// chips, the streamed conversation (Markdown, selectable), an input bar
/// with a stop button while streaming, and inline errors with retry.
/// "Xem dữ liệu sẽ gửi" previews exactly what `AIFinanceContextBuilder`
/// would put on the wire.
@MainActor
struct AIChatView: View {
    @Environment(\.modelContext) private var modelContext

    private let store: AIProviderStore
    private let injectedClient: (any AIChatClientProtocol)?
    private let urlSession: URLSession

    /// nil until the configuration check has run — avoids flashing the
    /// empty state while the store is being read.
    @State private var isConfigured: Bool?
    @State private var session: AIChatSession?
    @State private var scope: AIChatScope
    @State private var includeTransactions = true
    @State private var includeNotes = false
    /// The context exactly as it would be sent — rebuilt on every scope or
    /// privacy change, shown verbatim by "Xem dữ liệu sẽ gửi".
    @State private var contextText = ""
    @State private var contextError: String?
    @State private var isLoadingContext = false
    @State private var lastSnapshot: AIFinanceSnapshot?
    @State private var input = ""
    @State private var showsDataPreview = false
    @State private var showsSettings = false
    @State private var loadTask: Task<Void, Never>?
    @FocusState private var inputFocused: Bool

    private static let presetPrompts = [
        "Phân tích chi tiêu kỳ này",
        "Tôi nên cắt giảm ở đâu?",
        "So sánh với kỳ trước",
        "Mảng nào lãi, mảng nào lỗ?",
        "Dự báo dòng tiền 30 ngày tới",
        "Kế hoạch trả nợ thẻ và khoản vay",
    ]

    init(
        client: (any AIChatClientProtocol)? = nil,
        store: AIProviderStore = AIProviderStore(),
        urlSession: URLSession = .shared
    ) {
        self.injectedClient = client
        self.store = store
        self.urlSession = urlSession
        _scope = State(initialValue: AIChatScope(calendar: AppCalendar.vietnam))
    }

    var body: some View {
        Group {
            if let configured = isConfigured {
                if configured {
                    chatContent
                } else {
                    EmptyStateView(
                        symbol: "cpu.fill",
                        title: "Chưa cấu hình AI",
                        message: "Thêm nhà cung cấp AI (OpenAI tương thích hoặc Anthropic) để trò chuyện về tài chính của bạn.",
                        actionTitle: "Mở cài đặt AI"
                    ) {
                        showsSettings = true
                    }
                }
            } else {
                ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .navigationTitle("Trợ lý AI")
        .navigationDestination(isPresented: $showsSettings) {
            AISettingsView(store: store, urlSession: urlSession)
        }
        .task { await configure() }
        .onChange(of: scope) { _, _ in reloadContext() }
        .onChange(of: includeTransactions) { _, _ in rebuildContextText() }
        .onChange(of: includeNotes) { _, _ in rebuildContextText() }
        .onDisappear { loadTask?.cancel() }
        .sheet(isPresented: $showsDataPreview) {
            AIChatDataPreviewSheet(text: contextText)
        }
    }

    // MARK: - Configuration & context

    private func configure() async {
        guard isConfigured == nil else { return }
        let client = injectedClient ?? (try? store.makeClient())
        guard let client else {
            isConfigured = false
            return
        }
        session = AIChatSession(client: client)
        isConfigured = true
        reloadContext()
    }

    private var privacyOptions: AIFinancePrivacyOptions {
        AIFinancePrivacyOptions(
            includeTransactions: includeTransactions,
            includeNotes: includeNotes,
            includeAccountNames: true)
    }

    /// Refetches the snapshot for the current scope, then rebuilds the
    /// outgoing text. Privacy toggles only rebuild — they never refetch.
    private func reloadContext() {
        loadTask?.cancel()
        isLoadingContext = true
        contextError = nil
        let loader = AIChatContextLoader(container: modelContext.container)
        let scope = self.scope
        loadTask = Task {
            do {
                let snapshot = try await loader.snapshot(scope: scope)
                guard !Task.isCancelled else { return }
                apply(snapshot: snapshot)
            } catch is CancellationError {
            } catch {
                contextError = error.localizedDescription
            }
            isLoadingContext = false
        }
    }

    private func apply(snapshot: AIFinanceSnapshot) {
        lastSnapshot = snapshot
        rebuildContextText()
    }

    private func rebuildContextText() {
        guard let snapshot = lastSnapshot else { return }
        contextText = AIFinanceContextBuilder.outgoingText(
            snapshot: snapshot, options: privacyOptions)
        session?.contextText = contextText
    }

    // MARK: - Layout

    private var chatContent: some View {
        VStack(spacing: 0) {
            controls
            Divider()
            messageArea
            if let error = session?.errorMessage {
                errorBar(error)
            }
            Divider()
            inputBar
        }
    }

    // MARK: Controls

    private var controls: some View {
        VStack(alignment: .leading, spacing: 10) {
            scopeChips
            if scope.kind == .custom {
                customPickers
            }
            privacyRow
            presetChips
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(Color(.secondarySystemGroupedBackground))
    }

    private var scopeChips: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                ForEach(AIChatScopeKind.allCases, id: \.self) { kind in
                    chip(kind.displayName, selected: scope.kind == kind) {
                        scope.kind = kind
                    }
                }
            }
        }
        .accessibilityLabel("Phạm vi dữ liệu")
    }

    private var customPickers: some View {
        HStack(spacing: 12) {
            DatePicker(
                "Từ", selection: $scope.customStart,
                in: ...scope.customEnd, displayedComponents: .date)
            DatePicker(
                "Đến", selection: $scope.customEnd,
                in: scope.customStart..., displayedComponents: .date)
        }
        .datePickerStyle(.compact)
        .font(.caption)
    }

    private var privacyRow: some View {
        VStack(alignment: .leading, spacing: 6) {
            Toggle(isOn: $includeTransactions) {
                Text("Gửi kèm danh sách giao dịch").font(.caption)
            }
            Toggle(isOn: $includeNotes) {
                Text("Gửi kèm ghi chú giao dịch").font(.caption)
            }
            .disabled(!includeTransactions)
            Button {
                showsDataPreview = true
            } label: {
                Label("Xem dữ liệu sẽ gửi", systemImage: "doc.text.magnifyingglass")
                    .font(.caption.weight(.medium))
            }
            .disabled(contextText.isEmpty)
            statusLine
        }
        .toggleStyle(.switch)
        .controlSize(.mini)
    }

    @ViewBuilder
    private var statusLine: some View {
        if isLoadingContext {
            Label("Đang đọc dữ liệu…", systemImage: "arrow.triangle.2.circlepath")
                .font(.caption2)
                .foregroundStyle(.secondary)
        } else if let contextError {
            Label("Không đọc được dữ liệu: \(contextError)", systemImage: "exclamationmark.triangle")
                .font(.caption2)
                .foregroundStyle(.orange)
        } else if !contextText.isEmpty {
            Text("\(contextText.count) ký tự sẽ gửi kèm mỗi câu hỏi")
                .font(.caption2)
                .foregroundStyle(.secondary)
        }
    }

    private var presetChips: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                ForEach(Self.presetPrompts, id: \.self) { preset in
                    chip(preset, selected: false) {
                        send(preset)
                    }
                }
            }
        }
        .accessibilityLabel("Câu hỏi gợi ý")
    }

    private func chip(
        _ title: String, selected: Bool, action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            Text(title)
                .font(.caption.weight(.medium))
                .lineLimit(1)
                .padding(.horizontal, 10)
                .padding(.vertical, 6)
                .foregroundStyle(selected ? Color.white : Color.accentColor)
                .background(
                    (selected ? Color.accentColor : Color.accentColor.opacity(0.12)),
                    in: Capsule())
        }
        .buttonStyle(.plain)
    }

    // MARK: Messages

    private var messageArea: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(spacing: 10) {
                    if let session, session.conversation.turns.isEmpty,
                       !session.isStreaming {
                        hintCard
                    }
                    ForEach(session?.conversation.turns ?? []) { turn in
                        messageBubble(turn)
                            .id(turn.id)
                    }
                    if let session, session.isStreaming || !session.streamingText.isEmpty {
                        streamingBubble(session.streamingText)
                            .id("streaming")
                    }
                    Color.clear.frame(height: 1).id("bottom")
                }
                .padding(12)
            }
            .scrollDismissesKeyboard(.interactively)
            .onChange(of: session?.conversation.turns.count) { _, _ in
                withAnimation { proxy.scrollTo("bottom") }
            }
            .onChange(of: session?.streamingText) { _, _ in
                proxy.scrollTo("bottom")
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color(.systemGroupedBackground))
    }

    private var hintCard: some View {
        VStack(alignment: .leading, spacing: 8) {
            Label("Hỏi gì cũng được", systemImage: "sparkles")
                .font(.headline)
            Text("Trợ lý chỉ đọc dữ liệu trong phạm vi bạn chọn ở trên. Chạm một gợi ý hoặc nhập câu hỏi — ví dụ \"Tháng này tôi tiêu gì nhiều nhất?\"")
                .font(.subheadline)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(14)
        .background(Color(.secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 14))
    }

    private func messageBubble(_ turn: AIChatConversation.Turn) -> some View {
        HStack(alignment: .top, spacing: 0) {
            if turn.role == .user { Spacer(minLength: 48) }
            Group {
                if turn.role == .assistant {
                    markdownText(turn.text)
                } else {
                    Text(turn.text)
                }
            }
            .font(.body)
            .textSelection(.enabled)
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .foregroundStyle(turn.role == .user ? Color.white : Color.primary)
            .background(
                turn.role == .user
                    ? Color.accentColor
                    : Color(.secondarySystemGroupedBackground),
                in: RoundedRectangle(cornerRadius: 14))
            if turn.role == .assistant { Spacer(minLength: 48) }
        }
    }

    private func streamingBubble(_ text: String) -> some View {
        HStack(alignment: .top, spacing: 0) {
            HStack(spacing: 0) {
                markdownText(text)
                if text.isEmpty {
                    ProgressView().controlSize(.small)
                }
            }
            .font(.body)
            .textSelection(.enabled)
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .background(
                Color(.secondarySystemGroupedBackground),
                in: RoundedRectangle(cornerRadius: 14))
            Spacer(minLength: 48)
        }
    }

    /// Renders markdown (bold, italics, inline code) preserving line
    /// breaks; falls back to verbatim text when parsing fails.
    private func markdownText(_ text: String) -> Text {
        if let attributed = try? AttributedString(
            markdown: text,
            options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace)) {
            return Text(attributed)
        }
        return Text(verbatim: text)
    }

    private func errorBar(_ message: String) -> some View {
        HStack(spacing: 8) {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(.orange)
            Text(message)
                .font(.footnote)
                .lineLimit(3)
            Spacer(minLength: 8)
            if session?.canRetry == true {
                Button("Thử lại") { session?.retry() }
                    .font(.footnote.weight(.semibold))
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .background(Color(.secondarySystemGroupedBackground))
    }

    // MARK: Input bar

    private var inputBar: some View {
        HStack(alignment: .bottom, spacing: 10) {
            TextField("Hỏi về tài chính của bạn…", text: $input, axis: .vertical)
                .focused($inputFocused)
                .lineLimit(1...5)
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
                .background(
                    Color(.secondarySystemGroupedBackground),
                    in: RoundedRectangle(cornerRadius: 18))
                .onSubmit { send(input) }
            if session?.isStreaming == true {
                Button {
                    session?.stop()
                } label: {
                    Image(systemName: "stop.circle.fill")
                        .font(.system(size: 32))
                        .foregroundStyle(.red)
                }
                .accessibilityLabel("Dừng trả lời")
            } else {
                Button {
                    send(input)
                } label: {
                    Image(systemName: "arrow.up.circle.fill")
                        .font(.system(size: 32))
                        .foregroundStyle(Color.accentColor)
                }
                .disabled(input.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                .accessibilityLabel("Gửi")
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(Color(.systemBackground))
    }

    private func send(_ text: String) {
        session?.send(text)
        input = ""
        inputFocused = true
    }
}

/// The "Xem dữ liệu sẽ gửi" sheet: the exact context text, selectable.
/// Owns its NavigationStack since it is presented.
@MainActor
private struct AIChatDataPreviewSheet: View {
    let text: String

    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            ScrollView {
                Text(text.isEmpty ? "Chưa có dữ liệu." : text)
                    .font(.system(.footnote, design: .monospaced))
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(16)
            }
            .navigationTitle("Dữ liệu sẽ gửi")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Đóng") { dismiss() }
                }
            }
        }
    }
}

/// Canned streaming client for the preview — no network.
private struct AIChatPreviewClient: AIChatClientProtocol {
    func complete(_ request: AIRequest) async throws -> AIResponse {
        AIResponse(text: "Chỉ xem trước.", model: "preview")
    }

    func stream(_ request: AIRequest) -> AsyncThrowingStream<String, Error> {
        AsyncThrowingStream { continuation in
            let words = "Tháng này bạn chi **32,5 tr** — nhiều nhất ở *Ăn uống* (8 tr) rồi *Nhà cửa* (6 tr). Dữ liệu xem trước, không phải số thật."
            let pieces = words.components(separatedBy: " ")
            Task {
                for piece in pieces {
                    try? await Task.sleep(nanoseconds: 60_000_000)
                    continuation.yield(piece + " ")
                }
                continuation.finish()
            }
        }
    }
}

#Preview {
    let container = try! AppModelContainer.make(inMemory: true)
    let context = ModelContext(container)
    try! SeedData.seedIfNeeded(context: context)
    let cash = try! context.fetch(FetchDescriptor<Account>()).first!
    let categories = try! context.fetch(FetchDescriptor<LedgerCategory>())
    let food = categories.first { $0.name == "Ăn uống" }!
    let salary = categories.first { $0.name == "Lương & thù lao" }!
    for index in 0..<6 {
        let day = AppCalendar.vietnam.date(
            byAdding: .day, value: -index, to: .now) ?? .now
        context.insert(LedgerTransaction(
            kind: .expense, amount: 120_000 + Int64(index) * 15_000,
            date: day, note: "Ăn trưa \(index + 1)",
            account: cash, category: food))
    }
    context.insert(LedgerTransaction(
        kind: .income, amount: 20_000_000,
        note: "Lương tháng", account: cash, category: salary))
    return NavigationStack {
        AIChatView(client: AIChatPreviewClient())
    }
    .modelContainer(container)
}
