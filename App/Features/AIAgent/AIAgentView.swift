import SwiftUI
import SwiftData

/// "Agent" — the one unified AI chat screen. The user types a message;
/// `AIAgentChatSession` runs the allow-listed read tools against the
/// ledger by itself and the model answers with what it found. There is
/// nothing to configure inside this screen: the access level and the
/// notes switch live once in Cài đặt → "Trí tuệ nhân tạo (AI)" →
/// "Quyền của Agent", and the provider comes from `AIProviderStore`.
///
/// The screen is pushed inside an existing NavigationStack — callers
/// presenting it as a sheet wrap it in one.
///
/// All session state lives in `AIAgentController`, ONE shared instance
/// per model container (`AIAgentControllers.shared(for:)`): every
/// entry point shows the same conversation, an in-flight turn keeps
/// running when the screen is popped or the tab switched, and the
/// finished reply is there on return. This view only renders the
/// controller and forwards the taps.
@MainActor
struct AIAgentView: View {
    /// The persisted grant — the AppStorage key `AMFinanceApp` clears on
    /// UI-test launches so every run starts at the real default, `.off`.
    /// Owned by `AIAgentController`; forwarded here so the settings
    /// screen and tests keep their existing references.
    nonisolated static let accessDefaultsKey =
        AIAgentController.accessDefaultsKey
    /// Whether transaction notes ride the agent's tool results —
    /// `AMFinanceApp` clears it on UI-test launches too.
    nonisolated static let includeNotesDefaultsKey =
        AIAgentController.includeNotesDefaultsKey

    /// Tappable opening questions for the empty conversation.
    private static let suggestions = [
        "Tháng này tôi tiêu nhiều nhất vào đâu?",
        "Liệt kê giao dịch chưa phân loại",
        "Tìm giao dịch có ghi chú đáo hạn",
        "So sánh chi tiêu tháng này với tháng trước",
        "Thu nhập tháng này là bao nhiêu?",
    ]

    /// Extra hints while the write grant is on — the agent may also add,
    /// edit, delete and re-categorize, always behind one confirmation.
    private static let actionSuggestions = [
        "Thêm: ăn phở 50k",
        "Phân loại giúp các giao dịch chưa phân loại",
    ]

    @Environment(\.modelContext) private var context

    /// Tests and previews may inject a controller; nil resolves to the
    /// shared per-container one — the point of the design: every entry
    /// point shows the SAME conversation.
    private let injectedController: AIAgentController?

    /// The persisted grant + notes switch as AppStorage — their changes
    /// re-render the screen (the controller reads the same defaults).
    @AppStorage(AIAgentView.accessDefaultsKey)
    private var accessRaw = AIAgentAccess.off.rawValue
    @AppStorage(AIAgentView.includeNotesDefaultsKey)
    private var includeNotes = true

    @State private var input = ""
    @FocusState private var inputFocused: Bool
    @State private var showsSettings = false

    init(controller: AIAgentController? = nil) {
        self.injectedController = controller
    }

    /// The shared controller — created once per model container and
    /// kept for the app's lifetime.
    private var controller: AIAgentController {
        injectedController
            ?? AIAgentControllers.shared(for: context.container)
    }

    private var session: AIAgentChatSession? { controller.session }

    var body: some View {
        Group {
            if !controller.providerChecked {
                ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if controller.client == nil {
                EmptyStateView(
                    symbol: "cpu.fill",
                    title: "Chưa cấu hình AI",
                    message: "Agent cần một nhà cung cấp AI đang dùng. Thêm cấu hình để hỏi đáp về sổ của bạn.",
                    actionTitle: "Mở cài đặt AI"
                ) {
                    showsSettings = true
                }
            } else if !access.canLookup {
                EmptyStateView(
                    symbol: "hand.raised.fill",
                    title: "Chưa cấp quyền cho Agent",
                    message: "Agent tự đọc sổ để trả lời câu hỏi của bạn, nhưng hiện chưa được cấp quyền đọc. Bật quyền trong cài đặt AI để bắt đầu.",
                    actionTitle: "Mở cài đặt AI"
                ) {
                    showsSettings = true
                }
            } else {
                chatContent
            }
        }
        .navigationTitle("Agent")
        .navigationDestination(isPresented: $showsSettings) {
            AISettingsView(store: controller.providerStore)
        }
        .toolbar {
            ToolbarItemGroup(placement: .topBarTrailing) {
                Button {
                    controller.newConversation()
                } label: {
                    Image(systemName: "plus.message")
                }
                .accessibilityLabel("Cuộc trò chuyện mới")
                .accessibilityIdentifier("agent.newChat")
                .disabled(session == nil)
                Button {
                    showsSettings = true
                } label: {
                    Image(systemName: "gearshape")
                }
                .accessibilityLabel("Cài đặt AI")
                .accessibilityIdentifier("agent.openSettings")
            }
        }
        .onAppear {
            controller.refreshProvider()
            controller.syncSettings()
            controller.noteScreenAppeared()
        }
        .onDisappear { controller.noteScreenDisappeared() }
        // The grant itself needs no sync — the session re-reads it per
        // turn; the notes switch is copied into the live session.
        .onChange(of: includeNotes) { _, _ in controller.syncSettings() }
    }

    /// The current grant for what the VIEW shows (mode strip, the
    /// no-permission state, the suggestion list) — read from the
    /// AppStorage so a flip re-renders; the session reads the same
    /// defaults live through `controller.access`.
    private var access: AIAgentAccess {
        AIAgentAccess(rawValue: accessRaw) ?? .off
    }

    /// Reads the persisted grant straight from the defaults
    /// `@AppStorage` wraps — forwarded to the controller's reader.
    nonisolated static func accessValue(
        in defaults: UserDefaults
    ) -> AIAgentAccess {
        AIAgentController.accessValue(in: defaults)
    }

    // MARK: - Chat layout

    private var chatContent: some View {
        VStack(spacing: 0) {
            modeStrip
            Divider()
            messageArea
            if let providerNotice = controller.providerNotice {
                noticeBar(providerNotice)
            }
            if let error = session?.error {
                errorBar(error.localizedDescription)
            }
            Divider()
            inputBar
        }
    }

    /// The current grant + provider, one quiet line — the mode is set in
    /// cài đặt, not here, so the strip is a label, never a control.
    private var modeStrip: some View {
        HStack(spacing: 6) {
            Image(systemName: access == .scopedReadAndProposeCategoryEdits
                  ? "square.and.pencil" : "book.closed")
            Text(controller.providerName.isEmpty
                 ? access.agentModeTitle
                 : "\(access.agentModeTitle) · \(controller.providerName)")
            Spacer()
        }
        .font(.caption2)
        .foregroundStyle(.secondary)
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("agent.mode")
    }

    private var messageArea: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(spacing: 10) {
                    if session?.messages.isEmpty != false {
                        hintCard
                    }
                    ForEach(session?.messages ?? []) { message in
                        chatRow(message)
                            .id(message.id)
                    }
                    if session?.isWorking == true {
                        workingRow.id("working")
                    }
                    if let proposal = session?.pendingProposal {
                        AIAgentProposalCard(
                            proposal: proposal,
                            onApply: { session?.confirmProposal() },
                            onDiscard: { session?.discardProposal() })
                            .id("proposal")
                    }
                    Color.clear.frame(height: 1).id("bottom")
                }
                .padding(12)
            }
            .scrollDismissesKeyboard(.interactively)
            .onChange(of: session?.messages.count) { _, _ in
                withAnimation { proxy.scrollTo("bottom") }
            }
            .onChange(of: session?.isWorking) { _, _ in
                proxy.scrollTo("bottom")
            }
            .onChange(of: session?.pendingProposal != nil) { _, _ in
                proxy.scrollTo("bottom")
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color(.systemGroupedBackground))
    }

    private var hintCard: some View {
        VStack(alignment: .leading, spacing: 10) {
            Label("Hỏi gì cũng được", systemImage: "sparkles")
                .font(.headline)
            Text("Agent tự đọc sổ trong quyền đã cấp để trả lời. Chạm một gợi ý hoặc nhập câu hỏi của bạn.")
                .font(.subheadline)
                .foregroundStyle(.secondary)
            ForEach(suggestionList, id: \.self) { suggestion in
                Button {
                    send(suggestion)
                } label: {
                    Text(suggestion)
                        .font(.subheadline.weight(.medium))
                        .multilineTextAlignment(.leading)
                        .padding(.horizontal, 12)
                        .padding(.vertical, 8)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .foregroundStyle(Color.accentColor)
                        .background(
                            Color.accentColor.opacity(0.1),
                            in: RoundedRectangle(cornerRadius: 10))
                }
                .buttonStyle(.plain)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(14)
        .background(
            Color(.secondarySystemGroupedBackground),
            in: RoundedRectangle(cornerRadius: 14))
    }

    /// The read hints plus the action examples while the write grant is
    /// on — under "Đọc và thao tác" the agent may propose writes.
    private var suggestionList: [String] {
        access.canProposeActions
            ? Self.suggestions + Self.actionSuggestions
            : Self.suggestions
    }

    @ViewBuilder
    private func chatRow(_ message: AIAgentChatMessage) -> some View {
        if message.kind == .toolActivity {
            // A local tool ran — small secondary line, not a bubble.
            Label(message.text, systemImage: "magnifyingglass")
                .font(.caption)
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.leading, 4)
        } else {
            HStack(alignment: .top, spacing: 0) {
                if message.kind == .user { Spacer(minLength: 48) }
                Group {
                    if message.kind == .assistant {
                        markdownText(message.text)
                    } else {
                        Text(message.text)
                    }
                }
                .font(.body)
                .textSelection(.enabled)
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
                .foregroundStyle(
                    message.kind == .user ? Color.white : Color.primary)
                .background(
                    message.kind == .user
                        ? Color.accentColor
                        : Color(.secondarySystemGroupedBackground),
                    in: RoundedRectangle(cornerRadius: 14))
                if message.kind == .assistant { Spacer(minLength: 48) }
            }
        }
    }

    private var workingRow: some View {
        HStack(alignment: .top, spacing: 0) {
            HStack(spacing: 8) {
                ProgressView().controlSize(.small)
                Text("Agent đang làm việc…")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
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

    private func noticeBar(_ message: String) -> some View {
        HStack(spacing: 8) {
            Image(systemName: "info.circle.fill")
                .foregroundStyle(.secondary)
            Text(message)
                .font(.footnote)
                .lineLimit(3)
            Spacer(minLength: 8)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .background(Color(.secondarySystemGroupedBackground))
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
                Button("Thử lại") { controller.retry() }
                    .font(.footnote.weight(.semibold))
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .background(Color(.secondarySystemGroupedBackground))
        .accessibilityIdentifier("agent.error")
    }

    // MARK: - Input bar

    private var inputBar: some View {
        HStack(alignment: .bottom, spacing: 10) {
            TextField("Nhắn cho Agent…", text: $input, axis: .vertical)
                .focused($inputFocused)
                .lineLimit(1...5)
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
                .background(
                    Color(.secondarySystemGroupedBackground),
                    in: RoundedRectangle(cornerRadius: 18))
                .onSubmit { send(input) }
                .accessibilityIdentifier("agent.input")
            if session?.isWorking == true {
                Button {
                    session?.stop()
                } label: {
                    Image(systemName: "stop.circle.fill")
                        .font(.system(size: 32))
                        .foregroundStyle(.red)
                }
                .accessibilityLabel("Dừng trả lời")
                .accessibilityIdentifier("agent.stop")
            } else {
                Button {
                    send(input)
                } label: {
                    Image(systemName: "arrow.up.circle.fill")
                        .font(.system(size: 32))
                        .foregroundStyle(Color.accentColor)
                }
                .disabled(
                    input.trimmingCharacters(in: .whitespacesAndNewlines)
                        .isEmpty)
                .accessibilityLabel("Gửi")
                .accessibilityIdentifier("agent.send")
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(Color(.systemBackground))
    }

    /// One question leaves the device — the controller re-checks the
    /// provider snapshot inside `send`, so a stale destination never
    /// silently receives a message.
    private func send(_ text: String) {
        guard controller.send(text) else { return }
        if text == input { input = "" }
        inputFocused = true
    }
}
