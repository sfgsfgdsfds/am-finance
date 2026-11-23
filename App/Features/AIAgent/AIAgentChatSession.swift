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
/// Read-only: no write path exists here at all.
///
/// Per user turn (`send`):
/// 1. The access level is re-read from `accessProvider`; `.off` fails
///    the turn with `AIAgentError.permissionDenied` and zero requests.
/// 2. The model is called with `jsonMode: true`: the system prompt
///    carries today, the reply contract, the searchable day range (the
///    largest rolling window the tools allow, ending today) and the
///    current-month overview — plus the trimmed transcript.
/// 3. `search` runs through `AIAgentLedgerTools.lookup`, `summary`
///    through the chat snapshot + builder (clamped to 366 days); each
///    result rides back as a user-role `[KẾT QUẢ TRA CỨU…]` message.
///    At most `maxToolSteps` executions per turn — the next tool
///    request gets one final call instructing the model to answer.
/// 4. A contract-violating reply (bad args, malformed known type) earns
///    one corrective message; a second violation surfaces the error.
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

    /// The visible conversation — user text, tool-activity notes and
    /// assistant answers, in order.
    private(set) var messages: [AIAgentChatMessage] = []
    private(set) var isWorking = false
    /// The last turn's failure — an `AIAgentError`, an
    /// `AIAgentChatError` or the provider's own error;
    /// `localizedDescription` is a Vietnamese message.
    private(set) var error: (any Error)?

    /// Whether transaction notes ride search results — truncated to
    /// `AIAgentOrchestrator.maxNoteLength` like the preview payload.
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
    private let now: () -> Date
    private let calendar: Calendar

    /// The model-bound transcript — a superset of `messages` that also
    /// carries the raw JSON replies and the tool results.
    private var transcript: [AIAgentChatTranscriptEntry] = []
    /// `R…` handle → the lookup match it names. Stable across turns —
    /// the same transaction never earns a second handle; a later PR
    /// resolves write-action proposals through this map.
    private(set) var matchHandles: [String: AIAgentLookupMatch] = [:]
    private var handleByTransactionID: [UUID: String] = [:]
    private var nextHandleNumber = 1

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

    /// Appends the question and starts the read-only loop. Ignores
    /// blank text and any send while a turn is already running.
    func send(_ rawText: String) {
        let text = rawText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, !isWorking else { return }
        error = nil
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
        guard ticket == generation else { throw CancellationError() }
        let system = AIAgentChatProtocol.systemPrompt(
            now: now, window: permission.window,
            contextText: contextText, calendar: calendar)

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

    // MARK: - Outgoing payloads

    /// The exact JSON a `search` result sends back — ephemeral `R…`
    /// handles, signed đồng, `yyyy-MM-dd` days, truncated names and
    /// (opt-in) notes; no SwiftData ids or external ids.
    private func searchPayload(_ result: AIAgentLookupResult) -> String {
        let rows: [[String: Any]] = result.matches.map { match in
            let preview = match.preview
            var row: [String: Any] = [
                "id": handle(for: match),
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
                    $0, limit: AIAgentOrchestrator.maxCategoryNameLength)
                    as Any
            } ?? NSNull()
            if let account = preview.accountName {
                row["account"] = Self.truncated(
                    account, limit: AIAgentOrchestrator.maxAccountNameLength)
            }
            if let toAccount = preview.toAccountName {
                row["toAccount"] = Self.truncated(
                    toAccount, limit: AIAgentOrchestrator.maxAccountNameLength)
            }
            if includeNotes, !preview.note.isEmpty {
                row["note"] = Self.truncated(
                    preview.note, limit: AIAgentOrchestrator.maxNoteLength)
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

    /// Mints or reuses the session-stable `R…` handle for a match — the
    /// same transaction keeps its handle across turns and searches.
    private func handle(for match: AIAgentLookupMatch) -> String {
        let id = match.original.id
        if let existing = handleByTransactionID[id] { return existing }
        let handle = "R\(nextHandleNumber)"
        nextHandleNumber += 1
        handleByTransactionID[id] = handle
        matchHandles[handle] = match
        return handle
    }

    /// Cuts a string to `limit` characters with an ellipsis — the same
    /// shape the orchestrator's payload uses.
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
