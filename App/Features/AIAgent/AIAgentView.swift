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
/// Disposable state rules mirror the old staged sheet: the active
/// provider is captured as a whole non-secret profile snapshot — an
/// in-place edit of the same profile counts as "provider changed" —
/// and a provider, access-level or notes-switch change stops the
/// running session and starts a fresh one, so nothing a stale
/// configuration produced can be sent on.
@MainActor
struct AIAgentView: View {
    /// The persisted grant — the AppStorage key `AMFinanceApp` clears on
    /// UI-test launches so every run starts at the real default, `.off`.
    nonisolated static let accessDefaultsKey = "aiAgent.access"
    /// Whether transaction notes ride the agent's tool results —
    /// `AMFinanceApp` clears it on UI-test launches too.
    nonisolated static let includeNotesDefaultsKey = "aiAgent.includeNotes"

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

    private let providerStore: AIProviderStore
    private let injectedClient: (any AIChatClientProtocol)?

    @AppStorage(AIAgentView.accessDefaultsKey)
    private var accessRaw = AIAgentAccess.off.rawValue
    @AppStorage(AIAgentView.includeNotesDefaultsKey)
    private var includeNotes = true

    /// The active provider, resolved on appear and re-resolved whenever
    /// the screen becomes visible again — `providerProfile` is the exact
    /// non-secret snapshot `client` was built from, compared whole so a
    /// same-id edit counts as "provider changed". The API key is never
    /// part of it: keys live only in the Keychain.
    @State private var client: (any AIChatClientProtocol)?
    @State private var providerProfile: AIProviderProfile?
    @State private var providerName = ""
    /// nil→checked flip avoids flashing an empty state while the store
    /// is being read.
    @State private var providerChecked = false
    @State private var providerNotice: String?
    @State private var showsSettings = false

    @State private var session: AIAgentChatSession?
    @State private var input = ""
    @FocusState private var inputFocused: Bool

    init(
        providerStore: AIProviderStore = AIProviderStore(),
        client: (any AIChatClientProtocol)? = nil
    ) {
        self.providerStore = providerStore
        #if DEBUG
        // `-uiTestAgentScript` (honoured only beside the in-memory
        // UI-test store) replaces the provider: the screen counts as
        // configured and the deterministic script answers.
        let scripted: (any AIChatClientProtocol)? =
            AIAgentUITestScript.isEnabled
                ? AIAgentUITestScript.Client() : nil
        self.injectedClient = client ?? scripted
        #else
        self.injectedClient = client
        #endif
    }

    var body: some View {
        Group {
            if !providerChecked {
                ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if client == nil {
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
            AISettingsView(store: providerStore)
        }
        .toolbar {
            ToolbarItemGroup(placement: .topBarTrailing) {
                Button {
                    newConversation()
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
        .onAppear(perform: refreshProvider)
        .onChange(of: accessRaw) { _, _ in rebuildSession() }
        .onChange(of: includeNotes) { _, _ in rebuildSession() }
    }

    /// The current grant — read LIVE from persisted defaults every
    /// time, so the session's per-turn re-check sees a mid-turn
    /// revocation. `nonisolated` keeps the `accessProvider` closure a
    /// plain non-Sendable `() -> AIAgentAccess` in any isolation.
    private nonisolated var access: AIAgentAccess {
        Self.accessValue(in: .standard)
    }

    /// Reads the persisted grant straight from the defaults
    /// `@AppStorage` wraps — `accessRaw`'s storage backend.
    nonisolated static func accessValue(
        in defaults: UserDefaults
    ) -> AIAgentAccess {
        AIAgentAccess(
            rawValue: defaults.string(forKey: accessDefaultsKey)
                ?? AIAgentAccess.off.rawValue) ?? .off
    }

    // MARK: - Chat layout

    private var chatContent: some View {
        VStack(spacing: 0) {
            modeStrip
            Divider()
            messageArea
            if let providerNotice {
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
            Text(providerName.isEmpty
                 ? access.agentModeTitle
                 : "\(access.agentModeTitle) · \(providerName)")
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
                Button("Thử lại") { session?.retry() }
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

    /// One question leaves the device — the provider snapshot is
    /// re-checked first so a message never silently goes to a different
    /// destination than the one the session started on.
    private func send(_ text: String) {
        ensureSession()
        guard let session,
              !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        else { return }
        guard providerIsCurrent else { providerStale(); return }
        providerNotice = nil
        session.send(text)
        if text == input { input = "" }
        inputFocused = true
    }

    /// "Cuộc trò chuyện mới" — a fresh session on the current provider
    /// and grant. Nothing is persisted, so this drops everything.
    private func newConversation() {
        rebuildSession()
        providerNotice = nil
    }

    // MARK: - Session & provider

    /// Stops any in-flight turn and mints a fresh session when the
    /// current inputs allow one (provider + a usable grant). Called on
    /// every access / notes-switch / provider change — a revoked grant
    /// kills the session outright.
    private func rebuildSession() {
        session?.stop()
        session = nil
        ensureSession()
    }

    /// Builds the session if one is due and none exists — the read
    /// tools' grant is re-read live from the AppStorage so a mid-turn
    /// revocation still stops the loop.
    private func ensureSession() {
        guard session == nil, let client, access.canLookup else { return }
        session = AIAgentChatSession(
            client: client,
            context: context,
            accessProvider: { self.access },
            includeNotes: includeNotes)
    }

    /// Resolves the active provider profile into `client` + snapshot;
    /// a whole-profile change (switch OR in-place edit) rebuilds the
    /// session from nothing — what a different destination produced
    /// must not linger. First resolution only seeds the session.
    private func refreshProvider() {
        let previous = providerProfile
        if let injectedClient {
            client = injectedClient
            providerProfile = providerStore.activeProfile()
            providerName = providerProfile?.name ?? ""
            providerChecked = true
        } else if let profile = providerStore.activeProfile(),
                  let made = try? providerStore.makeClient(profile: profile) {
            client = made
            providerProfile = profile
            let name = profile.name.trimmingCharacters(in: .whitespacesAndNewlines)
            providerName = name.isEmpty ? profile.trimmedModel : name
            providerChecked = true
        } else {
            client = nil
            providerProfile = nil
            providerName = ""
            providerChecked = true
        }
        if providerProfile != previous {
            rebuildSession()
        } else {
            ensureSession()
        }
    }

    /// True only while the store's ACTIVE profile still equals, field by
    /// field, the non-secret snapshot `client` was built from.
    private var providerIsCurrent: Bool {
        if injectedClient != nil { return true }
        guard let providerProfile else { return false }
        return providerStore.activeProfile() == providerProfile
    }

    /// A send caught the active profile no longer matching the client's
    /// snapshot: rebind to whatever is active now (which rebuilds the
    /// session fresh) and leave a retry hint. Nothing profile-shaped is
    /// ever shown or logged — the notice is a fixed string.
    private func providerStale() {
        refreshProvider()
        providerNotice =
            "Cấu hình nhà cung cấp AI đã đổi — hãy gửi lại để đúng nơi nhận."
    }
}
