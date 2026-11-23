import Foundation
import Observation
import SwiftData
import FinanceCore

/// One visible chat entry: a user message, an assistant answer, or a
/// short tool-activity line ("Đã tìm 12 giao dịch") marking that the
/// agent read the ledger locally.
struct AIAgentChatMessage: Equatable, Sendable, Identifiable {
    enum Kind: Equatable, Sendable {
        case user
        case assistant
        /// A local tool ran — the entry summarizes it for the UI.
        case toolActivity
    }

    var id: UUID = UUID()
    var kind: Kind
    var text: String

    init(id: UUID = UUID(), kind: Kind, text: String) {
        self.id = id
        self.kind = kind
        self.text = text
    }
}

/// One transcript entry — what actually rides in `AIRequest`s. Tool
/// calls and answers keep the model's raw JSON reply so it can reason
/// over its own calls; `isToolResult` marks the entries the trimmer
/// drops before real turns (the newest one is never dropped).
private struct AIAgentChatTranscriptEntry: Equatable, Sendable {
    var role: AIRole
    var text: String
    var isToolResult = false
}

/// The chat-style agent session: the user types one message and the
/// model reads the ledger BY ITSELF — the loop runs the allow-listed
/// read tools locally and feeds results back until the model answers.
/// Under the write grant it may also propose `actions` batches — but
/// every write still lands solely through the user-confirmed
/// `confirmProposal()`; the loop itself never mutates.
///
/// Per user turn (`send`):
/// 1. The access level is re-read from `accessProvider`; `.off` fails
///    the turn with `AIAgentError.permissionDenied` and zero requests.
/// 2. The model is called with `jsonMode: true`: the system prompt
///    carries today, the reply contract, the searchable day range (the
///    largest rolling window the tools allow, ending today), the
///    `A…`/`C…` action catalog when the grant allows proposals, and
///    the current-month overview — plus the trimmed transcript.
/// 3. `search` runs through `AIAgentLedgerTools.lookup`, `summary`
///    through the chat snapshot + builder (clamped to 366 days); each
///    result rides back as a user-role `[KẾT QUẢ TRA CỨU…]` message.
///    At most `maxToolSteps` executions per turn — the next tool
///    request gets one final call instructing the model to answer.
/// 4. An `actions` reply is resolved through the `R…`/`A…`/`C…` handle
///    maps and dry-run validated; a valid batch parks on
///    `pendingProposal` and ends the turn — nothing is written. An
///    invalid batch earns one corrective round like other contract
///    violations; a second violation surfaces the error.
/// 5. `stop()` cancels the in-flight task; a generation counter makes
///    any late output land nowhere.
@MainActor @Observable
final class AIAgentChatSession {

    /// Total characters of transcript text a request may carry — raised
    /// from the chat's 12_000 since tool results are bulky JSON.
    static let defaultCharacterBudget = 24_000
    /// At most this many tool executions per user turn.
    static let defaultMaxToolSteps = 4
    /// Corrective rounds granted for contract-violating replies.
    static let defaultMaxCorrections = 1

    /// Outgoing-payload caps the model cannot raise.
    static let maxNoteLength = 80
    static let maxAccountNameLength = 40
    static let maxCategoryNameLength = 60
    /// Each direction's catalog shows at most this many categories to
    /// the model.
    static let maxCategoriesPerDirection = 40

    /// The visible conversation — user text, tool-activity notes and
    /// assistant answers, in order.
    private(set) var messages: [AIAgentChatMessage] = []
    private(set) var isWorking = false
    /// The last turn's failure — an `AIAgentError`, an
    /// `AIAgentChatError`, an `AIAgentApplyError` or the provider's own
    /// error; `localizedDescription` is a Vietnamese message.
    private(set) var error: (any Error)?

    /// The validated write batch awaiting the user's decision —
    /// non-nil only between a successful dry-run and `confirmProposal`
    /// /`discardProposal`. Preview value types only; nothing is
    /// written while this sits here.
    private(set) var pendingProposal: AIAgentActionProposal?

    /// Whether transaction notes ride search results — truncated to
    /// `Self.maxNoteLength` like the rest of the search payload.
    var includeNotes: Bool
    /// Transcript character budget for trimming.
    var characterBudget: Int
    /// Character budget for the overview texts (system context and
    /// `summary` results).
    var contextCharBudget: Int
    var maxToolSteps: Int
    var maxCorrections: Int

    private let client: any AIChatClientProtocol
    private let tools: AIAgentLedgerTools
    private let context: ModelContext
    private let accessProvider: () -> AIAgentAccess
    private let defaults: UserDefaults
    private let now: () -> Date
    private let calendar: Calendar

    /// The model-bound transcript — a superset of `messages` that also
    /// carries the raw JSON replies and the tool results.
    private var transcript: [AIAgentChatTranscriptEntry] = []
    /// `R…` handle → the lookup match it names. Stable across turns —
    /// the same transaction never earns a second handle; write-action
    /// proposals resolve through this map.
    private(set) var matchHandles: [String: AIAgentLookupMatch] = [:]
    private var handleByTransactionID: [UUID: String] = [:]
    /// `R…` handle → the window of the lookup that minted it — the
    /// `lookupWindow` the confirmed apply re-resolves through.
    private var matchWindows: [String: DateInterval] = [:]
    private var nextHandleNumber = 1

    /// The pending batch's resolved form — set with `pendingProposal`,
    /// consumed by `confirmProposal`.
    private var pendingActions: [AIAgentLedgerAction] = []
    /// Union of the touched matches' lookup windows.
    private var pendingLookupWindow: DateInterval?
    /// The `R…` handles the pending batch touches — invalidated after
    /// a successful apply.
    private var pendingTouchedHandles: [String] = []
    /// The transaction ids the pending batch deletes — those handles
    /// become unknown after apply instead of merely stale.
    private var pendingDeletedIDs: Set<UUID> = []

    /// The `A…`/`C…` handle maps — session-stable like the `R…` map:
    /// existing ids keep their handle across refreshes, new ids append
    /// at the end, archived/deleted ids drop out (their handle then
    /// resolves to `unknownHandle`).
    private var accountHandles: [String: UUID] = [:]
    private var categoryHandles: [String: UUID] = [:]
    private var nextAccountHandle = 1
    private var nextCategoryHandle = 1
    /// Fresh per-refresh id → live-object tables — proposals and edit
    /// drafts resolve every referenced object through these.
    private var accountsByID: [UUID: Account] = [:]
    private var categoriesByID: [UUID: LedgerCategory] = [:]
    private var businessesByID: [UUID: Business] = [:]

    private var workTask: Task<Void, Never>?
    /// Bumped by `stop()` — output produced by the older generation is
    /// discarded instead of mutating the conversation.
    private var generation = 0

    init(
        client: any AIChatClientProtocol,
        tools: AIAgentLedgerTools = AIAgentLedgerTools(),
        context: ModelContext,
        accessProvider: @escaping () -> AIAgentAccess = { .off },
        includeNotes: Bool = true,
        defaults: UserDefaults = .standard,
        now: @escaping () -> Date = { .now },
        calendar: Calendar = AppCalendar.vietnam,
        characterBudget: Int = AIAgentChatSession.defaultCharacterBudget,
        contextCharBudget: Int = AIFinanceContextBuilder.defaultCharacterBudget,
        maxToolSteps: Int = AIAgentChatSession.defaultMaxToolSteps,
        maxCorrections: Int = AIAgentChatSession.defaultMaxCorrections
    ) {
        self.client = client
        self.tools = tools
        self.context = context
        self.accessProvider = accessProvider
        self.includeNotes = includeNotes
        self.defaults = defaults
        self.now = now
        self.calendar = calendar
        self.characterBudget = max(0, characterBudget)
        self.contextCharBudget = max(0, contextCharBudget)
        self.maxToolSteps = max(0, maxToolSteps)
        self.maxCorrections = max(0, maxCorrections)
    }

    /// The lookup match an `R…` handle names — the map the write-action
    /// PR will resolve proposals through. Nil for an unknown handle.
    func match(forHandle handle: String) -> AIAgentLookupMatch? {
        matchHandles[handle]
    }

    /// True after a failed turn — `retry` resumes the loop from the
    /// transcript's current state.
    var canRetry: Bool {
        !isWorking && error != nil && !transcript.isEmpty
    }

    /// Appends the question and starts the loop. Ignores blank text
    /// and any send while a turn is already running; a still-pending
    /// proposal is discarded the same way `discardProposal()` does.
    func send(_ rawText: String) {
        let text = rawText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, !isWorking else { return }
        error = nil
        discardProposal()
        messages.append(AIAgentChatMessage(kind: .user, text: text))
        transcript.append(.init(role: .user, text: text))
        start()
    }

    /// Resumes the loop after a failure — the question and whatever the
    /// loop produced are already in the transcript.
    func retry() {
        guard canRetry else { return }
        error = nil
        start()
    }

    /// Cancels the in-flight turn; output landing afterwards is
    /// discarded via the generation counter.
    func stop() {
        generation += 1
        workTask?.cancel()
    }

    // MARK: - Confirmed proposals (the only write path)

    /// Applies the pending proposal through `AIAgentLedgerTools.apply`
    /// — the ONLY call that writes, reachable solely from this
    /// explicit user action, never from model output or tool results.
    /// Success clears the proposal, reports what landed and
    /// invalidates the touched `R…` handles; failure drops the batch
    /// with its Vietnamese reason — a stale or ineligible batch never
    /// half-applies.
    func confirmProposal() {
        guard pendingProposal != nil, !pendingActions.isEmpty,
              !isWorking else { return }
        // The grant is re-read at confirm — a downgrade since the
        // dry-run fails the apply itself.
        let permission = AIAgentPermission(
            access: accessProvider(),
            window: Self.lookupWindow(endingAt: now(), calendar: calendar))
        do {
            let summary = try tools.apply(
                pendingActions, permission: permission,
                in: context, lookupWindow: pendingLookupWindow)
            let touched = pendingTouchedHandles
            let deletedIDs = pendingDeletedIDs
            clearPending()
            let applied = Self.appliedSummaryText(summary)
            messages.append(AIAgentChatMessage(
                kind: .assistant, text: applied))
            transcript.append(.init(
                role: .user,
                text: Self.appliedTranscriptText(
                    applied, touchedHandles: touched)))
            invalidateHandles(touched, deletedIDs: deletedIDs)
        } catch let failure {
            clearPending()
            error = failure
            transcript.append(.init(
                role: .user,
                text: AIAgentChatProtocol.applyFailedPrefix + " "
                    + failure.localizedDescription
                    + " Đợt đề xuất đã bị huỷ — hãy tra cứu lại và đề "
                    + "xuất lại nếu người dùng vẫn muốn."))
        }
    }

    /// Drops the pending proposal untouched and records the decline in
    /// the transcript so the model knows the user said no.
    func discardProposal() {
        guard pendingProposal != nil else { return }
        clearPending()
        transcript.append(.init(
            role: .user,
            text: AIAgentChatProtocol.declinedPrefix
                + " Người dùng đã từ chối đề xuất — không có gì được ghi."))
    }

    /// Resets every piece of pending state together — the proposal,
    /// its resolved actions and the handle bookkeeping.
    private func clearPending() {
        pendingProposal = nil
        pendingActions = []
        pendingLookupWindow = nil
        pendingTouchedHandles = []
        pendingDeletedIDs = []
    }

    /// Post-apply handle cleanup: every touched match is stale.
    /// Deleted rows drop both maps — their `R…` becomes unknown —
    /// while edited or re-categorized rows keep the id → handle link
    /// so the next `search` returning that transaction refreshes the
    /// stored match under the SAME handle ("sửa tiếp dòng đó").
    private func invalidateHandles(
        _ handles: [String], deletedIDs: Set<UUID>
    ) {
        for handle in handles {
            guard let match = matchHandles.removeValue(forKey: handle)
            else { continue }
            matchWindows.removeValue(forKey: handle)
            if deletedIDs.contains(match.original.id) {
                handleByTransactionID.removeValue(
                    forKey: match.original.id)
            }
        }
    }

    /// "Đã áp dụng: phân loại 2, thêm 1, sửa 1, xoá 1" — zero counts
    /// are left out.
    private static func appliedSummaryText(
        _ summary: AIAgentApplySummary
    ) -> String {
        var parts: [String] = []
        if summary.categorized > 0 {
            parts.append("phân loại \(summary.categorized)")
        }
        if summary.added > 0 { parts.append("thêm \(summary.added)") }
        if summary.edited > 0 { parts.append("sửa \(summary.edited)") }
        if summary.deleted > 0 { parts.append("xoá \(summary.deleted)") }
        return "Đã áp dụng: " + parts.joined(separator: ", ")
    }

    /// The transcript entry the model sees after a confirmed apply:
    /// what landed plus which `R…` handles went stale and must be
    /// re-searched before another action on those rows.
    private static func appliedTranscriptText(
        _ applied: String, touchedHandles: [String]
    ) -> String {
        var text = AIAgentChatProtocol.appliedPrefix + " " + applied + "."
        let stale = touchedHandles.sorted { a, b in
            (Int(a.dropFirst()) ?? 0) < (Int(b.dropFirst()) ?? 0)
        }
        if !stale.isEmpty {
            text += " Handle "
                + stale.joined(separator: ", ")
                + " không còn khớp dữ liệu hiện tại — phải gọi \"search\" "
                + "lại để lấy trạng thái mới trước khi thao tác tiếp các "
                + "dòng đó (handle giữ nguyên cho cùng giao dịch)."
        }
        return text
    }

    /// The corrective message for a refused proposal batch — the
    /// Vietnamese reason plus the failing item's 1-based index when
    /// the apply error carries one.
    private static func proposalCorrectionText(
        for failure: any Error
    ) -> String {
        var text = AIAgentChatProtocol.correctionPrefix
            + " Đợt đề xuất không hợp lệ — chưa có gì được ghi."
        if let apply = failure as? AIAgentApplyError {
            if let index = apply.actionIndex {
                text += " Mục #\(index + 1): "
                    + apply.reason.localizedDescription
            } else {
                text += " " + apply.reason.localizedDescription
            }
        } else {
            text += " " + failure.localizedDescription
        }
        return text + " Hãy đề xuất lại ĐÚNG MỘT đối tượng JSON theo "
            + "hợp đồng, hoặc trả lời thường."
    }

    // MARK: - The loop

    private func start() {
        isWorking = true
        let ticket = generation
        workTask = Task {
            // One task runs at a time (send is gated on `isWorking`),
            // so cleanup is unconditional — the generation check inside
            // `run` guards the OUTPUT, not this block.
            defer { isWorking = false; workTask = nil }
            do {
                try await run(ticket: ticket)
            } catch is CancellationError {
                // Silenced — stop() owns the state now.
            } catch {
                if ticket == generation { self.error = error }
            }
        }
    }

    private func run(ticket: Int) async throws {
        let now = now()
        let access = accessProvider()
        guard access.canLookup else { throw AIAgentError.permissionDenied }
        let permission = AIAgentPermission(
            access: access,
            window: Self.lookupWindow(endingAt: now, calendar: calendar))

        // The system prompt is rebuilt per turn: date/time, the reply
        // contract, the grant bounds and the current-month overview.
        let contextText = await monthOverviewText(now: now)
        // The A…/C… catalog only exists while the grant allows
        // proposals — a read-only turn gets the read-only prompt.
        var actionCatalog: AIAgentActionCatalog?
        if access.canProposeActions {
            try refreshActionCatalog()
            actionCatalog = currentActionCatalog()
        }
        guard ticket == generation else { throw CancellationError() }
        let system = AIAgentChatProtocol.systemPrompt(
            now: now, window: permission.window,
            contextText: contextText, actionCatalog: actionCatalog,
            calendar: calendar)

        var toolSteps = 0
        var correctionsLeft = maxCorrections

        while true {
            let request = makeRequest(system: system)
            try Task.checkCancellation()
            let reply = try await client.complete(request)
            try Task.checkCancellation()
            guard ticket == generation else { throw CancellationError() }

            let parsed: AIAgentChatReply
            do {
                parsed = try AIAgentChatProtocol.parse(
                    reply.text, grantedWindow: permission.window,
                    calendar: calendar)
            } catch let failure {
                // The raw reply stays on record; one corrective message
                // gives the model a chance to fix its contract output.
                transcript.append(.init(role: .assistant, text: reply.text))
                guard correctionsLeft > 0 else { throw failure }
                correctionsLeft -= 1
                transcript.append(.init(
                    role: .user, text: Self.correctionText(for: failure)))
                continue
            }

            switch parsed {
            case .answer(let text):
                transcript.append(.init(role: .assistant, text: reply.text))
                messages.append(AIAgentChatMessage(
                    kind: .assistant, text: text))
                return

            case .search(let query):
                transcript.append(.init(role: .assistant, text: reply.text))
                guard toolSteps < maxToolSteps else {
                    return try await finishWithoutTools(
                        system: system, permission: permission,
                        ticket: ticket)
                }
                // The grant is re-read per tool call — a mid-turn
                // revocation stops the loop, not just this lookup.
                guard accessProvider().canLookup
                else { throw AIAgentError.permissionDenied }
                toolSteps += 1
                let result = try tools.lookup(
                    query, permission: permission, in: context)
                transcript.append(.init(
                    role: .user,
                    text: AIAgentChatProtocol.toolResultPrefix + "\n"
                        + searchPayload(result),
                    isToolResult: true))
                messages.append(AIAgentChatMessage(
                    kind: .toolActivity,
                    text: result.matches.isEmpty
                        ? "Không tìm thấy giao dịch nào"
                        : "Đã tìm \(result.matches.count) giao dịch"))

            case .summary(let interval):
                transcript.append(.init(role: .assistant, text: reply.text))
                guard toolSteps < maxToolSteps else {
                    return try await finishWithoutTools(
                        system: system, permission: permission,
                        ticket: ticket)
                }
                guard accessProvider().canLookup
                else { throw AIAgentError.permissionDenied }
                toolSteps += 1
                let summary = try await summaryText(interval, now: now)
                guard ticket == generation else { throw CancellationError() }
                transcript.append(.init(
                    role: .user,
                    text: AIAgentChatProtocol.toolResultPrefix + "\n"
                        + summary.text,
                    isToolResult: true))
                messages.append(AIAgentChatMessage(
                    kind: .toolActivity,
                    text: "Đã tổng hợp \(summary.label)"))

            case .actions(let text, let proposed):
                transcript.append(.init(role: .assistant, text: reply.text))
                // A mid-turn downgrade fails closed — the proposal is
                // answered with the read-only hint, never retried.
                guard accessProvider().canProposeActions else {
                    messages.append(AIAgentChatMessage(
                        kind: .assistant,
                        text: AIAgentChatProtocol.readOnlyActionsReply))
                    return
                }
                do {
                    // Fresh maps — resolution and validation see the
                    // same ledger state the upcoming confirm will.
                    try refreshActionCatalog()
                    let resolution = try resolveProposals(proposed)
                    try tools.validate(
                        resolution.actions, permission: permission,
                        in: context,
                        lookupWindow: resolution.lookupWindow)
                    pendingActions = resolution.actions
                    pendingLookupWindow = resolution.lookupWindow
                    pendingTouchedHandles = resolution.touchedHandles
                    pendingDeletedIDs = resolution.deletedIDs
                    pendingProposal = AIAgentActionProposal(
                        text: text, items: resolution.items)
                    messages.append(AIAgentChatMessage(
                        kind: .assistant, text: text))
                    return
                } catch let failure {
                    // One corrective round carrying the Vietnamese
                    // reason and the failing index — a second invalid
                    // batch surfaces the error. Never a partial batch.
                    guard correctionsLeft > 0 else { throw failure }
                    correctionsLeft -= 1
                    transcript.append(.init(
                        role: .user,
                        text: Self.proposalCorrectionText(for: failure)))
                    continue
                }
            }
        }
    }

    /// The tool-step budget is spent: one last call instructs the model
    /// to answer with the data it already has — a further tool request
    /// fails the turn instead of spending another request.
    private func finishWithoutTools(
        system: String, permission: AIAgentPermission, ticket: Int
    ) async throws {
        transcript.append(.init(role: .user, text: Self.noToolsLeftText))
        let request = makeRequest(system: system)
        try Task.checkCancellation()
        let reply = try await client.complete(request)
        try Task.checkCancellation()
        guard ticket == generation else { throw CancellationError() }
        guard let parsed = try? AIAgentChatProtocol.parse(
            reply.text, grantedWindow: permission.window,
            calendar: calendar),
              case .answer(let text) = parsed
        else { throw AIAgentChatError.toolBudgetExhausted }
        transcript.append(.init(role: .assistant, text: reply.text))
        messages.append(AIAgentChatMessage(kind: .assistant, text: text))
    }

    // MARK: - Local reads

    /// `[endOfToday − maxWindow, startOfTomorrow)` — the widest grant
    /// the tools accept, ending at the end of today in `calendar`.
    /// Derived from `AIAgentLedgerTools.maxWindow`, never hard-coded.
    static func lookupWindow(
        endingAt now: Date, calendar: Calendar
    ) -> DateInterval {
        let tomorrow = calendar.date(
            byAdding: .day, value: 1, to: calendar.startOfDay(for: now))
            ?? now.addingTimeInterval(86_400)
        return DateInterval(
            start: tomorrow.addingTimeInterval(-AIAgentLedgerTools.maxWindow),
            end: tomorrow)
    }

    /// The current-month overview for the system prompt — overview
    /// sections only (rows come from `search`). A snapshot failure
    /// degrades to no context rather than failing the turn.
    private func monthOverviewText(now: Date) async -> String {
        var loader = AIChatContextLoader(container: context.container)
        loader.calendar = calendar
        guard let snapshot = try? await loader.snapshot(
            scope: AIChatScope(kind: .thisMonth), now: now)
        else { return "" }
        return AIFinanceContextBuilder.outgoingText(
            snapshot: snapshot, options: Self.overviewPrivacyOptions,
            characterBudget: contextCharBudget, calendar: calendar)
    }

    /// The `summary` tool: clamps the requested interval to
    /// `summaryMaxSpan`, then runs the same snapshot + builder — same
    /// overview sections, no transaction lines.
    private func summaryText(
        _ interval: DateInterval, now: Date
    ) async throws -> (text: String, label: String) {
        let clamped = interval.duration > AIAgentChatProtocol.summaryMaxSpan
            ? DateInterval(
                start: interval.end.addingTimeInterval(
                    -AIAgentChatProtocol.summaryMaxSpan),
                end: interval.end)
            : interval
        let lastDay = calendar.date(byAdding: .day, value: -1, to: clamped.end)
            ?? clamped.start
        let scope = AIChatScope(
            kind: .custom, customStart: clamped.start, customEnd: lastDay,
            now: now, calendar: calendar)
        var loader = AIChatContextLoader(container: context.container)
        loader.calendar = calendar
        let snapshot = try await loader.snapshot(scope: scope, now: now)
        let text = AIFinanceContextBuilder.outgoingText(
            snapshot: snapshot, options: Self.overviewPrivacyOptions,
            characterBudget: contextCharBudget, calendar: calendar)
        return (text, snapshot.periodLabel)
    }

    /// Overview sections only — rows belong to the `search` tool.
    private static let overviewPrivacyOptions = AIFinancePrivacyOptions(
        includeTransactions: false, includeNotes: false,
        includeAccountNames: true)

    // MARK: - Action catalog

    /// Rebuilds the `A…`/`C…` handle maps and the live-object tables
    /// from the store. Existing ids keep their handles (a proposal the
    /// model just wrote still resolves), new ids append at the end and
    /// archived/deleted objects drop out — their handles then fail as
    /// `unknownHandle`, which is what the dry-run wants anyway.
    private func refreshActionCatalog() throws {
        let accounts = try context.fetch(FetchDescriptor<Account>())
        let categories = try context.fetch(FetchDescriptor<LedgerCategory>())
        let businesses = try context.fetch(FetchDescriptor<Business>())
        accountsByID = [:]
        categoriesByID = [:]
        businessesByID = [:]
        for account in accounts where !account.isArchived {
            accountsByID[account.id] = account
        }
        for category in categories where !category.isArchived {
            categoriesByID[category.id] = category
        }
        for business in businesses where !business.isArchived {
            businessesByID[business.id] = business
        }
        // Drop handles whose object left the live set, then mint new
        // handles for live objects that have none yet.
        accountHandles = accountHandles.filter {
            accountsByID[$0.value] != nil
        }
        categoryHandles = categoryHandles.filter {
            categoriesByID[$0.value] != nil
        }
        let unhandledAccounts = Set(accountsByID.keys)
            .subtracting(accountHandles.values)
        let unhandledCategories = Set(categoriesByID.keys)
            .subtracting(categoryHandles.values)
        for id in unhandledAccounts.sorted(by: { sortAccounts($0, $1) }) {
            accountHandles["A\(nextAccountHandle)"] = id
            nextAccountHandle += 1
        }
        for id in unhandledCategories.sorted(by: { sortCategories($0, $1) }) {
            categoryHandles["C\(nextCategoryHandle)"] = id
            nextCategoryHandle += 1
        }
    }

    /// Deterministic order for newly minted handles — name first so
    /// "A1"/"C1" feel stable, id as the tie-break.
    private func sortAccounts(_ a: UUID, _ b: UUID) -> Bool {
        let nameA = accountsByID[a]?.name ?? ""
        let nameB = accountsByID[b]?.name ?? ""
        return nameA == nameB ? a.uuidString < b.uuidString
            : nameA.localizedStandardCompare(nameB) == .orderedAscending
    }

    private func sortCategories(_ a: UUID, _ b: UUID) -> Bool {
        let nameA = categoriesByID[a]?.name ?? ""
        let nameB = categoriesByID[b]?.name ?? ""
        return nameA == nameB ? a.uuidString < b.uuidString
            : nameA.localizedStandardCompare(nameB) == .orderedAscending
    }

    /// The catalog the system prompt advertises — accounts in handle
    /// order, categories capped at `Self.maxCategoriesPerDirection` per
    /// direction.
    private func currentActionCatalog() -> AIAgentActionCatalog {
        let defaultID = defaultAccountID()
        let accounts = accountHandles
            .sorted { Self.handleNumber($0.key) < Self.handleNumber($1.key) }
            .compactMap { handle, id -> AIAgentActionCatalog.Account? in
                guard let account = accountsByID[id] else { return nil }
                return .init(
                    handle: handle, name: account.name,
                    kind: account.kind, isDefault: id == defaultID)
            }
        var categories: [AIAgentActionCatalog.Category] = []
        var perKind: [CategoryKind: Int] = [:]
        for (handle, id) in categoryHandles
            .sorted(by: { Self.handleNumber($0.key) < Self.handleNumber($1.key) })
        {
            guard let category = categoriesByID[id],
                  (perKind[category.kind] ?? 0)
                      < Self.maxCategoriesPerDirection
            else { continue }
            perKind[category.kind, default: 0] += 1
            categories.append(.init(
                handle: handle, name: category.name,
                kind: category.kind))
        }
        return AIAgentActionCatalog(
            accounts: accounts, categories: categories)
    }

    /// The numeric suffix of an `A…`/`C…`/`R…` handle — numeric order
    /// keeps "A2" before "A10".
    private static func handleNumber(_ handle: String) -> Int {
        Int(handle.dropFirst()) ?? 0
    }

    /// The last-used account the quick-add/capture flow records —
    /// the default an `add` without "account" resolves to.
    private func defaultAccountID() -> UUID? {
        defaults.string(forKey: DataResetService.lastUsedAccountDefaultsKey)
            .flatMap(UUID.init(uuidString:))
    }

    /// The default account object — last-used when it is still active,
    /// else the lowest active `A…` handle, else nil (the draft then
    /// fails validation, same as the editor does).
    private func defaultAccount() -> Account? {
        if let id = defaultAccountID(), let account = accountsByID[id] {
            return account
        }
        return accountHandles
            .sorted { Self.handleNumber($0.key) < Self.handleNumber($1.key) }
            .lazy.compactMap { self.accountsByID[$0.value] }.first
    }

    // MARK: - Proposal resolution

    /// The resolved form of one `actions` reply: the ledger actions to
    /// dry-run and apply, the display items `pendingProposal` shows,
    /// the `R…` handles the batch touches, the ids it deletes and the
    /// union of the lookups' windows the matches came from.
    private struct ResolvedProposals {
        var actions: [AIAgentLedgerAction]
        var items: [AIAgentProposalItem]
        var touchedHandles: [String]
        var deletedIDs: Set<UUID>
        var lookupWindow: DateInterval?
    }

    /// Maps every proposed item onto live objects and builds the
    /// matching display line. Throws `AIAgentApplyError.action(index,
    /// .unknownHandle)` for a handle the session never minted (or one
    /// that went stale) — the batch is refused whole, never partially.
    private func resolveProposals(
        _ proposed: [AIAgentProposedAction]
    ) throws -> ResolvedProposals {
        var resolved = ResolvedProposals(
            actions: [], items: [], touchedHandles: [],
            deletedIDs: [], lookupWindow: nil)
        for (index, proposal) in proposed.enumerated() {
            switch proposal {
            case .setCategory(let row, let category):
                let match = try requireMatch(row, at: index)
                let category = try requireCategory(category, at: index)
                resolved.actions.append(
                    .setCategory(match: match, category: category))
                resolved.items.append(setCategoryItem(
                    row: row, match: match, category: category))
                touch(row, into: &resolved)
            case .add(let kind, let fields):
                let draft = try addDraft(
                    kind: kind, fields: fields, at: index)
                resolved.actions.append(.add(draft: draft))
                resolved.items.append(addItem(draft))
            case .edit(let row, let fields):
                let match = try requireMatch(row, at: index)
                let draft = try editDraft(
                    from: match, fields: fields, at: index)
                resolved.actions.append(
                    .edit(match: match, draft: draft))
                resolved.items.append(editItem(
                    row: row, match: match, draft: draft))
                touch(row, into: &resolved)
            case .delete(let row):
                let match = try requireMatch(row, at: index)
                resolved.actions.append(.delete(match: match))
                resolved.items.append(deleteItem(row: row, match: match))
                resolved.deletedIDs.insert(match.original.id)
                touch(row, into: &resolved)
            }
        }
        return resolved
    }

    /// Records a touched `R…` handle and unions its lookup window into
    /// the batch's effective window.
    private func touch(_ row: String, into batch: inout ResolvedProposals) {
        batch.touchedHandles.append(row)
        if let window = matchWindows[row] {
            batch.lookupWindow = batch.lookupWindow.map {
                DateInterval(
                    start: min($0.start, window.start),
                    end: max($0.end, window.end))
            } ?? window
        }
    }

    private func requireMatch(
        _ handle: String, at index: Int
    ) throws -> AIAgentLookupMatch {
        guard let match = matchHandles[handle]
        else { throw AIAgentApplyError.action(index, .unknownHandle) }
        return match
    }

    /// A required `C…` handle → live category.
    private func requireCategory(
        _ handle: String, at index: Int
    ) throws -> LedgerCategory {
        guard let id = categoryHandles[handle],
              let category = categoriesByID[id]
        else { throw AIAgentApplyError.action(index, .unknownHandle) }
        return category
    }

    /// An optional `A…` handle → live account; nil resolves to nil.
    private func account(for handle: String?, at index: Int) throws -> Account? {
        guard let handle else { return nil }
        guard let id = accountHandles[handle],
              let account = accountsByID[id]
        else { throw AIAgentApplyError.action(index, .unknownHandle) }
        return account
    }

    /// The `add` draft: the contract requires `kind`+`amount`; `date`
    /// defaults to now, `account` to the last-used account. Field-kind
    /// mismatches were refused at parse; a wrong-kind category still
    /// lands on the draft so `validate` reports `invalidDraft`.
    private func addDraft(
        kind: TransactionKind,
        fields: AIAgentProposedFields,
        at index: Int
    ) throws -> TransactionDraft {
        var draft = TransactionDraft(kind: kind)
        draft.amount = fields.amount ?? 0
        draft.date = mergedDate(
            day: fields.day, time: fields.time, base: now())
        draft.note = fields.note ?? ""
        draft.account = try account(for: fields.account, at: index)
            ?? defaultAccount()
        if kind == .transfer {
            draft.toAccount = try account(for: fields.toAccount, at: index)
        } else if fields.category != nil {
            draft.category = try requireCategory(
                fields.category!, at: index)
        }
        return draft
    }

    /// The `edit` draft: seeded from the match's snapshot — the exact
    /// row state the user previewed — then only the supplied fields
    /// change. Kind can never change; `toAccount`/`business` stay the
    /// live row's (the contract cannot name them).
    private func editDraft(
        from match: AIAgentLookupMatch,
        fields: AIAgentProposedFields,
        at index: Int
    ) throws -> TransactionDraft {
        let snapshot = match.original
        var draft = TransactionDraft(kind: snapshot.kind)
        draft.amount = fields.amount ?? snapshot.amount
        draft.date = mergedDate(
            day: fields.day, time: fields.time, base: snapshot.date)
        draft.note = fields.note ?? snapshot.note
        draft.account = try account(for: fields.account, at: index)
            ?? snapshot.accountID.flatMap { accountsByID[$0] }
        if snapshot.kind == .transfer {
            draft.toAccount = snapshot.toAccountID
                .flatMap { accountsByID[$0] }
        } else {
            draft.category = try fields.category.map {
                try requireCategory($0, at: index)
            } ?? snapshot.categoryID.flatMap { categoriesByID[$0] }
            draft.business = snapshot.businessID
                .flatMap { businessesByID[$0] }
        }
        return draft
    }

    /// Combines an optional day and wall-clock on top of `base` —
    /// `date` alone keeps the base's time, `time` alone keeps the
    /// base's day; both missing returns `base` as-is.
    private func mergedDate(
        day: Date?, time: AIAgentDayTime?, base: Date
    ) -> Date {
        // dateComponents(_:from:) leaves .calendar unset — .date would
        // be nil — so compose a fresh one pinned to the Vietnam calendar.
        let dayParts = calendar.dateComponents(
            [.year, .month, .day], from: day ?? base)
        var components = DateComponents()
        components.calendar = calendar
        components.timeZone = calendar.timeZone
        components.year = dayParts.year
        components.month = dayParts.month
        components.day = dayParts.day
        if let time {
            components.hour = time.hour
            components.minute = time.minute
            components.second = 0
        } else {
            let timeParts = calendar.dateComponents(
                [.hour, .minute, .second], from: base)
            components.hour = timeParts.hour
            components.minute = timeParts.minute
            components.second = timeParts.second
        }
        return components.date ?? base
    }

    // MARK: - Proposal display items

    /// `setCategory` previews one transition: old category → new.
    private func setCategoryItem(
        row: String, match: AIAgentLookupMatch, category: LedgerCategory
    ) -> AIAgentProposalItem {
        AIAgentProposalItem(
            kind: .setCategory, row: row,
            changes: [
                .init(field: "Danh mục",
                      old: match.preview.categoryName ?? "Chưa phân loại",
                      new: category.name),
            ])
    }

    /// `add` previews every field the draft will write — new values
    /// only, since nothing exists yet.
    private func addItem(_ draft: TransactionDraft)
        -> AIAgentProposalItem
    {
        var changes: [AIAgentProposalItem.FieldChange] = [
            .init(field: "Loại", new: Self.kindTitle(draft.kind)),
            .init(field: "Số tiền",
                  new: Self.displayAmount(draft.amount)),
            .init(field: "Ngày",
                  new: displayDateTime(draft.date)),
            .init(field: "Tài khoản",
                  new: draft.account?.name ?? "—"),
        ]
        if draft.kind == .transfer {
            changes.append(.init(
                field: "Tài khoản đích",
                new: draft.toAccount?.name ?? "—"))
        } else {
            changes.append(.init(
                field: "Danh mục",
                new: draft.category?.name ?? "Chưa phân loại"))
        }
        if !draft.note.isEmpty {
            changes.append(.init(field: "Ghi chú", new: draft.note))
        }
        return AIAgentProposalItem(kind: .add, changes: changes)
    }

    /// `edit` previews only the fields the draft actually changes —
    /// `old → new` per line so the confirm list stays short.
    private func editItem(
        row: String, match: AIAgentLookupMatch, draft: TransactionDraft
    ) -> AIAgentProposalItem {
        let snapshot = match.original
        var changes: [AIAgentProposalItem.FieldChange] = []
        if draft.amount != snapshot.amount {
            changes.append(.init(
                field: "Số tiền",
                old: Self.displayAmount(snapshot.amount),
                new: Self.displayAmount(draft.amount)))
        }
        if draft.date != snapshot.date {
            changes.append(.init(
                field: "Ngày",
                old: displayDateTime(snapshot.date),
                new: displayDateTime(draft.date)))
        }
        if draft.account?.id != snapshot.accountID {
            changes.append(.init(
                field: "Tài khoản",
                old: match.preview.accountName ?? "—",
                new: draft.account?.name ?? "—"))
        }
        if draft.category?.id != snapshot.categoryID {
            changes.append(.init(
                field: "Danh mục",
                old: match.preview.categoryName ?? "Chưa phân loại",
                new: draft.category?.name ?? "Chưa phân loại"))
        }
        if draft.note != snapshot.note {
            changes.append(.init(
                field: "Ghi chú",
                old: snapshot.note.isEmpty ? "—" : snapshot.note,
                new: draft.note.isEmpty ? "—" : draft.note))
        }
        return AIAgentProposalItem(kind: .edit, row: row, changes: changes)
    }

    /// `delete` previews the row as it stands — the fields the user
    /// loses: date, amount, note, account.
    private func deleteItem(
        row: String, match: AIAgentLookupMatch
    ) -> AIAgentProposalItem {
        let preview = match.preview
        var changes: [AIAgentProposalItem.FieldChange] = [
            .init(field: "Ngày", old: displayDateTime(preview.date)),
            .init(field: "Số tiền",
                  old: Self.displayAmount(preview.amount)),
            .init(field: "Tài khoản",
                  old: preview.accountName ?? "—"),
        ]
        if !preview.note.isEmpty {
            changes.append(.init(field: "Ghi chú", old: preview.note))
        }
        return AIAgentProposalItem(kind: .delete, row: row, changes: changes)
    }

    /// "50.000 ₫" — unsigned magnitude; the kind column already says
    /// expense/income/transfer.
    private static func displayAmount(_ amount: Int64) -> String {
        VND.format(amount)
    }

    /// "22/11 14:05" — the app's short date + HH:mm, Vietnam calendar.
    private func displayDateTime(_ date: Date) -> String {
        AppDateFormat.shortDate(date, calendar: calendar)
            + " "
            + AppDateFormat.time(date, calendar: calendar)
    }

    /// Short Vietnamese kind name for the preview list.
    private static func kindTitle(_ kind: TransactionKind) -> String {
        switch kind {
        case .expense: return "Chi tiêu"
        case .income: return "Thu nhập"
        case .transfer: return "Chuyển khoản"
        }
    }

    // MARK: - Outgoing payloads

    /// The exact JSON a `search` result sends back — ephemeral `R…`
    /// handles, signed đồng, `yyyy-MM-dd` days, truncated names and
    /// (opt-in) notes; no SwiftData ids or external ids.
    private func searchPayload(_ result: AIAgentLookupResult) -> String {
        let rows: [[String: Any]] = result.matches.map { match in
            let preview = match.preview
            var row: [String: Any] = [
                "id": handle(for: match, window: result.window),
                "date": AIAgentToolPlanner.dayString(
                    preview.date, calendar: calendar),
                "amount": preview.kind == .income
                    ? preview.amount : -preview.amount,
                "kind": preview.kind.rawValue,
                "source": preview.source.rawValue,
                "needsReview": preview.needsReview,
            ]
            row["category"] = preview.categoryName.map {
                Self.truncated(
                    $0, limit: Self.maxCategoryNameLength)
                    as Any
            } ?? NSNull()
            if let account = preview.accountName {
                row["account"] = Self.truncated(
                    account, limit: Self.maxAccountNameLength)
            }
            if let toAccount = preview.toAccountName {
                row["toAccount"] = Self.truncated(
                    toAccount, limit: Self.maxAccountNameLength)
            }
            if includeNotes, !preview.note.isEmpty {
                row["note"] = Self.truncated(
                    preview.note, limit: Self.maxNoteLength)
            }
            return row
        }
        let payload: [String: Any] = [
            "window": [
                "from": AIAgentToolPlanner.dayString(
                    result.window.start, calendar: calendar),
                "to": AIAgentToolPlanner.dayString(
                    result.window.end.addingTimeInterval(-1),
                    calendar: calendar),
            ],
            "scanned": result.scanned,
            "returned": rows.count,
            "truncated": result.truncated,
            "rows": rows,
        ]
        guard let data = try? JSONSerialization.data(
            withJSONObject: payload, options: [.sortedKeys])
        else { return "{}" }
        return String(decoding: data, as: UTF8.self)
    }

    /// Mints or reuses the session-stable `R…` handle for a match —
    /// the same transaction keeps its handle across turns, searches
    /// and applies. A re-search refreshes the stored match under the
    /// existing handle (the snapshot a proposal validates against
    /// always reflects the newest lookup) and remembers the window
    /// the match came from, which `confirmProposal` re-resolves
    /// through.
    private func handle(
        for match: AIAgentLookupMatch, window: DateInterval
    ) -> String {
        let id = match.original.id
        if let existing = handleByTransactionID[id] {
            matchHandles[existing] = match
            matchWindows[existing] = window
            return existing
        }
        let handle = "R\(nextHandleNumber)"
        nextHandleNumber += 1
        handleByTransactionID[id] = handle
        matchHandles[handle] = match
        matchWindows[handle] = window
        return handle
    }

    /// Cuts a string to `limit` characters with an ellipsis.
    private static func truncated(_ text: String, limit: Int) -> String {
        guard text.count > limit else { return text }
        return String(text.prefix(max(0, limit - 1))) + "…"
    }

    /// The corrective message sent after a contract-violating reply.
    private static func correctionText(for error: any Error) -> String {
        AIAgentChatProtocol.correctionPrefix
            + " Lượt trả lời trước không đúng định dạng "
            + "(\(error.localizedDescription)) Hãy trả lời lại ĐÚNG MỘT "
            + "đối tượng JSON theo đúng hợp đồng đã nêu."
    }

    /// The final call's instruction once the tool-step budget is spent.
    private static let noToolsLeftText =
        AIAgentChatProtocol.noToolsLeftPrefix
        + " Không được gọi công cụ nữa — hãy trả lời ngay bằng "
        + "{\"type\":\"answer\",\"text\":\"…\"} dựa trên dữ liệu đã có."

    // MARK: - Trimming

    /// The request to send: the fixed system prompt plus the trimmed
    /// transcript — `jsonMode` always on.
    private func makeRequest(system: String) -> AIRequest {
        AIRequest(
            system: system,
            messages: trimmedTranscript().map {
                AIMessage(role: $0.role, text: $0.text)
            },
            jsonMode: true)
    }

    /// The transcript entries that fit `characterBudget`: the oldest
    /// tool results go first (the newest one is never dropped), then
    /// the oldest remaining turns — the newest entry always survives,
    /// hard-truncated if the protected entries alone bust the budget.
    private func trimmedTranscript() -> [AIAgentChatTranscriptEntry] {
        var kept = transcript
        var total = kept.reduce(0) { $0 + $1.text.count }

        while total > characterBudget,
              let latest = kept.lastIndex(where: { $0.isToolResult }),
              let oldest = kept.firstIndex(where: { $0.isToolResult }),
              oldest != latest {
            total -= kept[oldest].text.count
            kept.remove(at: oldest)
        }
        while total > characterBudget, kept.count > 1 {
            let latest = kept.lastIndex(where: { $0.isToolResult })
            guard let victim = kept.indices.first(where: {
                $0 != kept.count - 1 && $0 != latest
            }) else { break }
            total -= kept[victim].text.count
            kept.remove(at: victim)
        }
        var excess = total - characterBudget
        if excess > 0, let idx = kept.lastIndex(where: { $0.isToolResult }),
           kept[idx].text.count > excess {
            kept[idx].text = String(
                kept[idx].text.prefix(
                    kept[idx].text.count - excess - 1)) + "…"
            total -= excess
        }
        excess = total - characterBudget
        if excess > 0, !kept.isEmpty,
           kept[kept.count - 1].text.count > excess {
            let last = kept.count - 1
            kept[last].text = String(
                kept[last].text.prefix(
                    kept[last].text.count - excess - 1)) + "…"
        }
        return kept
    }
}
