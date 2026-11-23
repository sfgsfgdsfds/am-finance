import SwiftUI
import SwiftData
import FinanceCore

/// "Agent giao dịch" — the opt-in AI ledger agent, presented as a sheet
/// from the Giao dịch toolbar. Three deliberate stages, each gated on the
/// user's own action:
///
/// 1. "Tìm trong sổ" — sends ONLY the typed question plus the allowed
///    date bounds to the active provider (`AIAgentOrchestrator.search`);
///    the hits it shows are local lookup rows.
/// 2. "Gửi dữ liệu này cho AI" — the exact outgoing JSON is on screen,
///    reviewed, before `analyze(prepared:)` sends it verbatim. Notes,
///    account names and the category catalog are opt-in per request.
/// 3. "Áp dụng …" — a confirmation dialog resolves the validated
///    proposals into one atomic `applyCategoryEdits` call. Nothing is
///    ever auto-applied.
///
/// Every flow output is disposable: changing the access level, the date
/// window, the question, the privacy switches or the active provider
/// cancels the in-flight task and discards whatever it produced — the
/// orchestrator's own re-checks refuse a revoked or narrowed grant even
/// if the UI lagged.
@MainActor
struct AIAgentView: View {
    /// The persisted grant — the AppStorage key `AMFinanceApp` clears on
    /// UI-test launches so every run starts at the real default, `.off`.
    static let accessDefaultsKey = "aiAgent.access"

    @Environment(\.modelContext) private var context
    @Environment(\.dismiss) private var dismiss

    private let providerStore: AIProviderStore

    @AppStorage(AIAgentView.accessDefaultsKey)
    private var accessRaw = AIAgentAccess.off.rawValue

    /// "Now" is frozen when the sheet opens so the presets and the
    /// scanned window cannot drift under a running flow.
    @State private var sessionNow = Date.now
    @State private var windowSelection = AIAgentWindowSelection()
    @State private var question = ""

    /// The active provider, resolved from `AIProviderStore` on appear
    /// and re-resolved whenever the settings screen returns.
    /// `providerProfile` is the exact non-secret snapshot `client` was
    /// built from — compared whole (URL, model, style, headers, limits…),
    /// never by id alone, so a same-id edit counts as "provider changed".
    /// The API key is never part of it: keys live only in the Keychain.
    @State private var client: (any AIChatClientProtocol)?
    @State private var providerProfile: AIProviderProfile?
    @State private var providerName = ""
    @State private var providerChecked = false
    @State private var providerNotice: String?
    @State private var showsSettings = false

    /// Flow outputs — nil until their stage produced them; every input
    /// change clears them all through `resetFlow()`.
    @State private var searchResult: AIAgentSearchResult?
    @State private var prepared: AIAgentPreparedAnalysis?
    @State private var analysis: AIAgentAnalysis?
    @State private var appliedCount: Int?
    /// Privacy switches for the payload — OFF again for each request.
    @State private var includeNotes = false
    @State private var includeAccountNames = false
    @State private var flowError: FlowError?
    /// The stage currently running — gates every submit button against
    /// double taps and drives the progress labels.
    @State private var running: FlowStage?
    @State private var inFlight: Task<Void, Never>?
    /// Bumped on every reset — a stale task returning late finds its
    /// generation gone and discards its own output.
    @State private var flowGeneration = 0
    @State private var confirmApply = false

    private enum FlowStage {
        case search, analyze, apply
    }

    private struct FlowError {
        var stage: FlowStage
        var message: String
    }

    init(providerStore: AIProviderStore = AIProviderStore()) {
        self.providerStore = providerStore
    }

    var body: some View {
        NavigationStack {
            Form {
                accessSection
                if access != .off {
                    if !providerChecked {
                        Section { ProgressView() }
                    } else if client == nil {
                        providerMissingSection
                    } else {
                        windowSection
                        questionSection
                        noticeRow
                        errorRow
                        resultsSection
                        payloadSection
                        analysisSection
                        applySection
                    }
                }
            }
            .scrollDismissesKeyboard(.interactively)
            .navigationTitle("Agent giao dịch")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Đóng") { dismiss() }
                }
            }
            .navigationDestination(isPresented: $showsSettings) {
                AISettingsView(store: providerStore)
            }
            .confirmationDialog(
                "Áp dụng \(analysis?.proposals.count ?? 0) thay đổi danh mục?",
                isPresented: $confirmApply,
                titleVisibility: .visible
            ) {
                Button("Áp dụng") { applyNow() }
                Button("Huỷ", role: .cancel) {}
            } message: {
                Text("Chỉ danh mục của các giao dịch đã liệt kê sẽ đổi — số tiền, ngày và tài khoản giữ nguyên.")
            }
            .onAppear(perform: refreshProvider)
            .onChange(of: showsSettings) { _, shown in
                if !shown { providerReturned() }
            }
            .onChange(of: accessRaw) { _, _ in resetFlow() }
            .onChange(of: windowSelection) { _, _ in resetFlow() }
            .onChange(of: question) { _, _ in resetFlow() }
            .onChange(of: includeNotes) { _, _ in rebuildPrepared() }
            .onChange(of: includeAccountNames) { _, _ in rebuildPrepared() }
            .onDisappear { inFlight?.cancel() }
        }
    }

    // MARK: - Inputs

    private var access: AIAgentAccess {
        AIAgentAccess(rawValue: accessRaw) ?? .off
    }

    /// The permission built from the CURRENT picker + window state —
    /// rebuilt at every stage entry so a weakened grant is re-checked
    /// by the orchestrator and the tools, not just by this view.
    private var currentPermission: AIAgentPermission? {
        guard access != .off, let window = resolvedWindow else { return nil }
        return AIAgentPermission(access: access, window: window)
    }

    private var resolvedWindow: DateInterval? {
        windowSelection.interval(now: sessionNow)
    }

    private var previewOptions: AIAgentPreviewOptions {
        AIAgentPreviewOptions(
            includeNotes: includeNotes,
            includeAccountNames: includeAccountNames)
    }

    private var trimmedQuestion: String {
        question.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private var canSearch: Bool {
        running == nil && client != nil && currentPermission != nil
            && !trimmedQuestion.isEmpty
    }

    private var accessSection: some View {
        Section {
            Picker("Quyền truy cập", selection: $accessRaw) {
                Text("Tắt").tag(AIAgentAccess.off.rawValue)
                Text("Chỉ đọc").tag(AIAgentAccess.scopedRead.rawValue)
                Text("Đọc và đề xuất đổi danh mục")
                    .tag(AIAgentAccess.scopedReadAndProposeCategoryEdits.rawValue)
            }
            .accessibilityIdentifier("agent.accessPicker")
        } header: {
            Text("Quyền của Agent")
        } footer: {
            Text("Agent chỉ đọc giao dịch trong khoảng ngày bạn chọn. Nó không thể xoá, thêm hay chuyển khoản, không đụng vào tài khoản ngân hàng và không bao giờ tự sửa — mọi đổi danh mục đều chờ bạn bấm \"Áp dụng\".")
        }
    }

    private var providerMissingSection: some View {
        Section {
            EmptyStateView(
                symbol: "cpu.fill",
                title: "Chưa cấu hình AI",
                message: "Agent giao dịch cần một nhà cung cấp AI đang dùng. Thêm cấu hình để tra cứu sổ bằng AI.",
                actionTitle: "Mở cài đặt AI"
            ) {
                showsSettings = true
            }
            .listRowSeparator(.hidden)
            .listRowBackground(Color.clear)
        }
    }

    private var windowSection: some View {
        Section {
            Picker("Khoảng ngày", selection: $windowSelection.kind) {
                ForEach(AIAgentWindowKind.allCases, id: \.self) { kind in
                    Text(kind.title).tag(kind)
                }
            }
            if windowSelection.kind == .custom {
                DatePicker(
                    "Từ ngày", selection: $windowSelection.customStart,
                    displayedComponents: .date)
                DatePicker(
                    "Đến ngày", selection: $windowSelection.customEnd,
                    displayedComponents: .date)
            }
            if let window = resolvedWindow {
                LabeledContent("Sẽ tra cứu", value: windowText(window))
            } else {
                Label(
                    windowSelection.errorText(now: sessionNow)
                        ?? "Khoảng ngày không hợp lệ.",
                    systemImage: "exclamationmark.triangle.fill")
                    .foregroundStyle(.orange)
            }
        } header: {
            Text("Khoảng ngày")
        } footer: {
            Text("Agent chỉ đọc được giao dịch trong khoảng này — tối đa 93 ngày theo giờ Việt Nam.")
        }
    }

    private var questionSection: some View {
        Section {
            TextField(
                "Ví dụ: liệt kê các khoản chi ăn uống",
                text: $question, axis: .vertical)
                .lineLimit(2...5)
                .accessibilityIdentifier("agent.question")
            Button("Tìm trong sổ") { runSearch() }
                .disabled(!canSearch)
            if running == .search {
                Label("Đang tìm trong sổ…", systemImage: "magnifyingglass")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
        } header: {
            Text("Yêu cầu")
        } footer: {
            Text("Chỉ câu hỏi và khoảng ngày ở trên được gửi cho \(providerName) — chưa có giao dịch nào rời máy.")
        }
    }

    // MARK: - Local hits

    @ViewBuilder
    private var resultsSection: some View {
        if let searchResult {
            let matches = searchResult.result.matches
            Section {
                if matches.isEmpty {
                    Text("Không tìm thấy giao dịch nào trong khoảng đã chọn.")
                        .foregroundStyle(.secondary)
                } else {
                    ForEach(matches, id: \.original.id) { match in
                        matchRow(match.preview)
                    }
                }
            } header: {
                Text("Kết quả trong sổ — \(matches.count) giao dịch")
            } footer: {
                if searchResult.result.truncated {
                    Text("Đã quét \(searchResult.result.scanned) giao dịch — kết quả có thể chưa đầy đủ, hãy thu hẹp câu hỏi hoặc khoảng ngày.")
                } else {
                    Text("Đã quét \(searchResult.result.scanned) giao dịch trong sổ trên máy — chưa gửi gì cho AI.")
                }
            }
        }
    }

    private func matchRow(_ preview: AIAgentTransactionPreview) -> some View {
        HStack(alignment: .firstTextBaseline) {
            VStack(alignment: .leading, spacing: 2) {
                Text(matchTitle(preview))
                    .lineLimit(1)
                Text(matchSubtitle(preview))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            Spacer(minLength: 8)
            AmountText(amount: preview.amount, kind: preview.kind)
                .font(.subheadline)
        }
    }

    private func matchTitle(_ preview: AIAgentTransactionPreview) -> String {
        if !preview.note.isEmpty { return preview.note }
        if let category = preview.categoryName { return category }
        return preview.kind.displayName
    }

    private func matchSubtitle(_ preview: AIAgentTransactionPreview) -> String {
        var parts = [AppDateFormat.shortDate(preview.date)]
        if let account = preview.accountName { parts.append(account) }
        if preview.unclassified { parts.append("Chưa phân loại") }
        return parts.joined(separator: " • ")
    }

    // MARK: - Reviewed payload

    @ViewBuilder
    private var payloadSection: some View {
        // The exact request exists only while it is still reviewable —
        // once an analysis lands, this section is replaced by the result.
        if let prepared, analysis == nil {
            Section {
                Toggle("Gửi kèm ghi chú", isOn: $includeNotes)
                Toggle("Gửi kèm tên tài khoản", isOn: $includeAccountNames)
                if prepared.grantsProposals {
                    LabeledContent(
                        "Danh mục kèm theo",
                        value: "\(prepared.categories.count)")
                }
                Text(payloadText(of: prepared))
                    .font(.system(.caption2, design: .monospaced))
                    .textSelection(.enabled)
                Button("Gửi dữ liệu này cho AI") { runAnalyze() }
                    .disabled(running != nil)
                if running == .analyze {
                    Label("Đang phân tích…", systemImage: "sparkles")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
            } header: {
                Text("Dữ liệu sẽ gửi cho \(providerName)")
            } footer: {
                Text("Đúng nội dung JSON trên sẽ được gửi — không thêm gì khác. Ghi chú và tên tài khoản luôn bắt đầu tắt cho mỗi lượt tìm mới.")
            }
        }
    }

    /// The exact outgoing body — the user message `analyze` sends
    /// verbatim, shown unmodified so the review is real.
    private func payloadText(of prepared: AIAgentPreparedAnalysis) -> String {
        prepared.request.messages.first?.text ?? ""
    }

    // MARK: - Analysis result

    @ViewBuilder
    private var analysisSection: some View {
        if let analysis {
            Section {
                if !analysis.answer.isEmpty {
                    VStack(alignment: .leading, spacing: 4) {
                        Text(analysis.answer)
                        Text("Nội dung do AI tạo — hãy đối chiếu với sổ trước khi tin.")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                }
                if let rejection = analysis.proposalRejection {
                    Label(
                        "Đề xuất của AI bị loại: \(rejection.localizedDescription)",
                        systemImage: "exclamationmark.triangle.fill")
                        .foregroundStyle(.orange)
                }
                ForEach(analysis.proposals, id: \.row.handle) { proposal in
                    proposalRow(proposal)
                }
                if let appliedCount {
                    Label(
                        "Đã áp dụng \(appliedCount) thay đổi danh mục.",
                        systemImage: "checkmark.circle.fill")
                        .foregroundStyle(.green)
                } else if analysis.proposals.isEmpty,
                          analysis.proposalRejection == nil {
                    Text("AI không đề xuất đổi danh mục nào.")
                        .foregroundStyle(.secondary)
                }
            } header: {
                Text("Kết quả AI")
            }
        }
    }

    private func proposalRow(_ proposal: AIAgentCategoryProposal) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack {
                Text(AppDateFormat.shortDate(proposal.row.date))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Spacer()
                AmountText(amount: proposal.row.amount, kind: proposal.row.kind)
                    .font(.subheadline)
            }
            Text("\(proposal.row.categoryName ?? "Chưa phân loại") → \(proposal.category.name)")
                .font(.subheadline.weight(.medium))
        }
    }

    @ViewBuilder
    private var applySection: some View {
        if let analysis, !analysis.proposals.isEmpty, appliedCount == nil {
            Section {
                Button("Áp dụng \(analysis.proposals.count) thay đổi") {
                    confirmApply = true
                }
                .disabled(running != nil)
            } footer: {
                Text("Áp dụng một lần, nguyên tử — một đề xuất lỗi sẽ huỷ toàn bộ. AI không thể tự sửa.")
            }
        }
    }

    // MARK: - Notices & errors

    @ViewBuilder
    private var noticeRow: some View {
        if let providerNotice {
            Section {
                Label(providerNotice, systemImage: "info.circle.fill")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
        }
    }

    @ViewBuilder
    private var errorRow: some View {
        if let flowError {
            Section {
                Label(flowError.message, systemImage: "exclamationmark.triangle.fill")
                    .foregroundStyle(.orange)
                Button("Thử lại") { retry(flowError.stage) }
                    .disabled(running != nil)
            }
        }
    }

    // MARK: - Flow

    /// Stage 1: only the question plus the granted days leave the device —
    /// hits come back through the bounded local lookup.
    private func runSearch() {
        guard canSearch, let permission = currentPermission,
              let client else { return }
        guard providerIsCurrent else { providerStale(); return }
        resetFlow()
        running = .search
        let generation = flowGeneration
        let question = trimmedQuestion
        let context = self.context
        inFlight = Task { @MainActor in
            defer {
                // A superseded task must not clear a newer request's
                // busy state or task handle — only the live generation
                // cleans up.
                if generation == flowGeneration {
                    running = nil
                    inFlight = nil
                }
            }
            do {
                let orchestrator = AIAgentOrchestrator(client: client)
                let result = try await orchestrator.search(
                    question: question, permission: permission, in: context)
                try Task.checkCancellation()
                guard generation == flowGeneration else { return }
                searchResult = result
                prepared = try orchestrator.prepareAnalysis(
                    result, options: previewOptions,
                    permission: permission, in: context)
            } catch is CancellationError {
                // Silenced — a newer input owns the screen.
            } catch {
                guard generation == flowGeneration else { return }
                flowError = FlowError(
                    stage: .search, message: error.localizedDescription)
            }
        }
    }

    /// Stage 2: sends the exact reviewed request — the grant, the
    /// window and the provider identity are all re-checked first, and
    /// the orchestrator re-checks them again before the wire.
    private func runAnalyze() {
        guard running == nil, let prepared,
              let permission = currentPermission, let client else { return }
        guard providerIsCurrent else { providerStale(); return }
        running = .analyze
        let generation = flowGeneration
        inFlight = Task { @MainActor in
            defer {
                if generation == flowGeneration {
                    running = nil
                    inFlight = nil
                }
            }
            do {
                let result = try await AIAgentOrchestrator(client: client)
                    .analyze(prepared, permission: permission)
                try Task.checkCancellation()
                guard generation == flowGeneration else { return }
                analysis = result
                // A fresh analysis supersedes every earlier error in
                // this generation — a stale apply/analyze failure must
                // not linger over the new result.
                flowError = nil
            } catch is CancellationError {
            } catch {
                guard generation == flowGeneration else { return }
                flowError = FlowError(
                    stage: .analyze, message: error.localizedDescription)
            }
        }
    }

    /// Stage 3: the one explicit write — validated proposals → one
    /// atomic apply inside the effective lookup window, re-checked
    /// against the current grant by the tools themselves.
    /// Runs ONLY from the confirmation dialog's "Áp dụng" action — never
    /// from a retry shortcut or any other caller.
    private func applyNow() {
        guard running == nil, let analysis, !analysis.proposals.isEmpty,
              appliedCount == nil,
              let permission = currentPermission else { return }
        guard providerIsCurrent else { providerStale(); return }
        running = .apply
        defer { running = nil }
        do {
            let edits = try analysis.categoryEdits(in: context)
            let result = try AIAgentLedgerTools().applyCategoryEdits(
                edits, permission: permission, in: context,
                lookupWindow: analysis.effectiveWindow)
            appliedCount = result.appliedCount
            flowError = nil
        } catch {
            flowError = FlowError(
                stage: .apply, message: error.localizedDescription)
        }
    }

    private func retry(_ stage: FlowStage) {
        switch stage {
        case .search: runSearch()
        case .analyze: runAnalyze()
        case .apply:
            // Re-applying goes through the same explicit confirmation of
            // the current non-empty proposal — never straight into the
            // write, and never once a count was already applied.
            if let analysis, !analysis.proposals.isEmpty,
               appliedCount == nil {
                confirmApply = true
            }
        }
    }

    /// Every input change lands here: cancel whatever is in flight and
    /// clear every derived artifact — nothing stale can be shown, sent
    /// or applied afterwards. The privacy switches reset too, so each
    /// new request starts with notes and account names OFF.
    private func resetFlow() {
        inFlight?.cancel()
        inFlight = nil
        running = nil
        flowGeneration += 1
        searchResult = nil
        prepared = nil
        analysis = nil
        appliedCount = nil
        flowError = nil
        confirmApply = false
        includeNotes = false
        includeAccountNames = false
        providerNotice = nil
    }

    /// The privacy switches changed: the payload must be re-minted (or
    /// dropped when the inputs it came from are gone) and anything
    /// downstream of it — analysis, apply — is stale. A change caused by
    /// `resetFlow` itself finds nothing left to rebuild and returns
    /// early — important so the just-started task is never cancelled by
    /// the switch reset that produced it.
    private func rebuildPrepared() {
        guard prepared != nil || analysis != nil || appliedCount != nil
        else { return }
        inFlight?.cancel()
        inFlight = nil
        running = nil
        flowGeneration += 1
        analysis = nil
        appliedCount = nil
        flowError = nil
        guard let searchResult, let permission = currentPermission,
              let client, providerIsCurrent else {
            prepared = nil
            return
        }
        do {
            prepared = try AIAgentOrchestrator(client: client)
                .prepareAnalysis(
                    searchResult, options: previewOptions,
                    permission: permission, in: context)
        } catch {
            prepared = nil
            flowError = FlowError(
                stage: .analyze, message: error.localizedDescription)
        }
    }

    // MARK: - Provider

    private func refreshProvider() {
        guard let profile = providerStore.activeProfile(),
              let made = try? providerStore.makeClient(profile: profile)
        else {
            client = nil
            providerProfile = nil
            providerName = ""
            providerChecked = true
            return
        }
        client = made
        providerProfile = profile
        let name = profile.name.trimmingCharacters(in: .whitespacesAndNewlines)
        providerName = name.isEmpty ? profile.trimmedModel : name
        providerChecked = true
    }

    /// True only while the store's ACTIVE profile still equals, field by
    /// field, the non-secret snapshot `client` was built from. Editing
    /// the saved profile in place — same id, new URL/model/style —
    /// makes this false, so no reviewed payload can silently leave for
    /// a destination different from the one the flow started on.
    private var providerIsCurrent: Bool {
        guard let providerProfile else { return false }
        return providerStore.activeProfile() == providerProfile
    }

    /// A stage caught the active profile no longer matching the client's
    /// snapshot (edited, switched or removed): rebind to whatever is
    /// active now, drop every artifact the old destination produced and
    /// leave a retry hint. Nothing profile-shaped is ever shown or
    /// logged — the notice is a fixed string.
    private func providerStale() {
        refreshProvider()
        resetFlow()
        providerNotice =
            "Cấu hình nhà cung cấp AI đã đổi — hãy tìm lại để gửi đúng nơi nhận."
    }

    /// Back from settings: any change to the active provider — a switch
    /// OR an in-place edit of the same profile — discards every artifact
    /// the previous configuration produced. Byte-identical profile keeps
    /// the flow.
    private func providerReturned() {
        let previous = providerProfile
        refreshProvider()
        guard providerProfile != previous else { return }
        resetFlow()
        if previous != nil {
            providerNotice =
                "Cấu hình nhà cung cấp AI đã đổi — kết quả trước đã được xoá."
        }
    }

    // MARK: - Formatting

    private static let dayFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.calendar = AppCalendar.vietnam
        formatter.timeZone = AppCalendar.vietnam.timeZone
        formatter.dateFormat = "dd/MM/yyyy"
        return formatter
    }()

    /// "01/11/2026 – 30/11/2026" — the covered days of a half-open window.
    private func windowText(_ window: DateInterval) -> String {
        let last = window.end.addingTimeInterval(-1)
        return Self.dayFormatter.string(from: window.start)
            + " – " + Self.dayFormatter.string(from: last)
    }
}
