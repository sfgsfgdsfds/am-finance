import Foundation
import Observation
import FinanceCore

/// The surface every AI feature screen calls. `AIClient` already implements
/// both methods; tests substitute a fake so no network is involved.
protocol AIChatClientProtocol: Sendable {
    func complete(_ request: AIRequest) async throws -> AIResponse
    func stream(_ request: AIRequest) -> AsyncThrowingStream<String, Error>
}

extension AIClient: AIChatClientProtocol {}

/// The four data-scope chips the chat screen offers.
enum AIChatScopeKind: String, CaseIterable, Sendable {
    case thisMonth
    case threeMonths
    case thisYear
    case custom

    /// Vietnamese label on the chip.
    var displayName: String {
        switch self {
        case .thisMonth: return "Tháng này"
        case .threeMonths: return "3 tháng"
        case .thisYear: return "Năm nay"
        case .custom: return "Tuỳ chọn"
        }
    }
}

/// The period the assistant talks about. `customStart`/`customEnd` only
/// matter for `.custom` — the pickers edit them in place like
/// `ReportsPeriod` does. Pure value type; every computation takes `now`
/// and `calendar` explicitly.
struct AIChatScope: Equatable, Sendable {
    var kind: AIChatScopeKind = .thisMonth
    var customStart: Date
    var customEnd: Date

    init(
        kind: AIChatScopeKind = .thisMonth,
        customStart: Date? = nil,
        customEnd: Date? = nil,
        now: Date = .now,
        calendar: Calendar = AppCalendar.vietnam
    ) {
        self.kind = kind
        self.customStart = customStart
            ?? calendar.date(byAdding: .month, value: -1, to: now) ?? now
        self.customEnd = customEnd ?? now
    }

    /// The half-open interval [start, end) the scope covers.
    /// `.threeMonths` is the three calendar months ending with the current
    /// one (e.g. Sep–Nov); `.thisYear` is the whole calendar year.
    func interval(now: Date, calendar: Calendar) -> ReportDateInterval {
        switch kind {
        case .thisMonth:
            return ReportsPeriod.monthInterval(containing: now, calendar: calendar)
        case .threeMonths:
            let current = ReportsPeriod.monthInterval(containing: now, calendar: calendar)
            let start = calendar.date(byAdding: .month, value: -2, to: current.start)
                ?? current.start
            return ReportDateInterval(start: start, end: current.end)
        case .thisYear:
            return ReportsPeriod.yearInterval(containing: now, calendar: calendar)
        case .custom:
            return ReportsPeriod.customInterval(
                from: customStart, through: customEnd, calendar: calendar)
        }
    }

    /// The label that opens the context text — "Tháng 11/2026",
    /// "3 tháng gần đây", "Năm 2026", "01/10 – 15/11/2026".
    func periodLabel(now: Date, calendar: Calendar) -> String {
        let current = interval(now: now, calendar: calendar)
        switch kind {
        case .thisMonth:
            return AppDateFormat.monthTitle(current.start, calendar: calendar)
        case .threeMonths:
            return "3 tháng gần đây"
        case .thisYear:
            return "Năm \(calendar.component(.year, from: current.start))"
        case .custom:
            return Self.rangeLabel(
                start: current.start,
                end: current.end.addingTimeInterval(-1),
                calendar: calendar)
        }
    }

    /// "dd/MM – dd/MM/yyyy", dropping the start's year when it matches the
    /// end's — the same shape `ReportsPeriod.title` uses for custom ranges.
    private static func rangeLabel(
        start: Date, end: Date, calendar: Calendar
    ) -> String {
        let sameYear = calendar.component(.year, from: start)
            == calendar.component(.year, from: end)
        let endText = formatter("dd/MM/yyyy", calendar: calendar).string(from: end)
        let startText = formatter(
            sameYear ? "dd/MM" : "dd/MM/yyyy", calendar: calendar
        ).string(from: start)
        return "\(startText) – \(endText)"
    }

    private static func formatter(_ format: String, calendar: Calendar) -> DateFormatter {
        let formatter = DateFormatter()
        formatter.calendar = calendar
        formatter.timeZone = calendar.timeZone
        formatter.locale = calendar.locale
        formatter.dateFormat = format
        return formatter
    }
}

/// A conversation with the assistant: the alternating user/assistant turns
/// plus the rules that turn them into an `AIRequest`. The finance context
/// rides in the system prompt — exactly once — and the oldest turns are
/// dropped first when the character budget runs out.
struct AIChatConversation: Equatable, Sendable {

    /// One message in the transcript. `role` is `.user` or `.assistant` —
    /// the system prompt travels separately, so it is never trimmed away.
    struct Turn: Equatable, Sendable, Identifiable {
        var id: UUID = UUID()
        var role: AIRole
        var text: String

        init(id: UUID = UUID(), role: AIRole, text: String) {
            self.id = id
            self.role = role
            self.text = text
        }
    }

    /// Total characters of turn text a request may carry.
    static let defaultCharacterBudget = 12_000

    private(set) var turns: [Turn] = []
    var characterBudget: Int

    init(characterBudget: Int = AIChatConversation.defaultCharacterBudget) {
        self.characterBudget = max(0, characterBudget)
    }

    /// The system prompt for the finance chat: a careful Vietnamese analyst
    /// that may only reason over the supplied data, writes đồng with
    /// thousands separators, and says so when data is missing.
    static let analystSystemPrompt = """
    Bạn là trợ lý phân tích tài chính cá nhân của ứng dụng AM Finance, luôn trả lời \
    bằng tiếng Việt.
    Nguyên tắc bắt buộc:
    - Chỉ dùng dữ liệu trong phần "Bối cảnh tài chính" bên dưới — tuyệt đối không bịa \
    số liệu; khi dữ liệu không đủ để trả lời, nói rõ là thiếu dữ liệu thay vì đoán.
    - Ghi số tiền bằng đồng Việt Nam với dấu chấm phân tách hàng nghìn, ví dụ \
    1.250.000 ₫.
    - Số dư âm là tiền chủ nhân đang nợ (thẻ tín dụng, khoản vay). "Chuyển khoản" là \
    tiền đi giữa các tài khoản của chính chủ nhân — không phải thu cũng không phải chi.
    - Trả lời thận trọng, rõ ràng, dùng gạch đầu dòng khi có nhiều ý; với các quyết \
    định lớn hãy nhắc rằng đây là gợi ý tham khảo, không phải tư vấn tài chính chuyên \
    nghiệp.
    """

    mutating func appendUser(_ text: String) {
        turns.append(Turn(role: .user, text: text))
    }

    mutating func appendAssistant(_ text: String) {
        turns.append(Turn(role: .assistant, text: text))
    }

    /// The turns that fit `characterBudget`, oldest dropped first. The
    /// newest turn always survives — hard-truncated with "…" when it alone
    /// exceeds the budget — so the current question is never lost.
    func trimmedTurns() -> [Turn] {
        var kept: [Turn] = []
        var total = 0
        for turn in turns.reversed() {
            let length = turn.text.count
            if kept.isEmpty {
                // Newest turn is always kept, even when it must be cut down.
                if length > characterBudget {
                    var cut = turn
                    cut.text = String(turn.text.prefix(max(0, characterBudget - 1))) + "…"
                    kept.append(cut)
                } else {
                    kept.append(turn)
                    total += length
                }
                continue
            }
            if total + length > characterBudget { break }
            kept.append(turn)
            total += length
        }
        return kept.reversed()
    }

    /// The request to send: the analyst system prompt plus the finance
    /// context (a single copy — inside `system`, never repeated in the
    /// turns) and the trimmed conversation.
    func request(system: String, contextText: String) -> AIRequest {
        var fullSystem = system.trimmingCharacters(in: .whitespacesAndNewlines)
        let context = contextText.trimmingCharacters(in: .whitespacesAndNewlines)
        if !context.isEmpty {
            fullSystem += "\n\n" + context
        }
        return AIRequest(
            system: fullSystem,
            messages: trimmedTurns().map {
                AIMessage(role: $0.role, text: $0.text)
            }
        )
    }
}

/// Glue between the chat screen and the client: owns the conversation,
/// runs the streamed request, accumulates deltas into the visible answer
/// and handles stop / retry. `@MainActor` — every property is safe to bind.
@MainActor @Observable
final class AIChatSession {
    private(set) var conversation: AIChatConversation
    /// The answer as it arrives — cleared once it becomes a turn.
    private(set) var streamingText = ""
    private(set) var isStreaming = false
    /// Vietnamese failure text of the last stream, if any.
    private(set) var errorMessage: String?

    private let client: any AIChatClientProtocol
    /// The fixed analyst prompt.
    let systemPrompt: String
    /// The finance context — the view swaps it whenever the loader
    /// rebuilds for a new scope or new privacy switches.
    var contextText: String
    private var streamTask: Task<Void, Never>?

    init(
        client: any AIChatClientProtocol,
        systemPrompt: String = AIChatConversation.analystSystemPrompt,
        contextText: String = "",
        characterBudget: Int = AIChatConversation.defaultCharacterBudget
    ) {
        self.client = client
        self.systemPrompt = systemPrompt
        self.contextText = contextText
        self.conversation = AIChatConversation(characterBudget: characterBudget)
    }

    /// True when the last question failed before any answer — "Thử lại"
    /// re-sends it without duplicating the user turn.
    var canRetry: Bool {
        !isStreaming && errorMessage != nil
            && conversation.turns.last?.role == .user
    }

    /// Appends the question and starts streaming the answer. Ignores blank
    /// text and any send while a stream is already running.
    func send(_ rawText: String) {
        let text = rawText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, !isStreaming else { return }
        conversation.appendUser(text)
        start()
    }

    /// Re-runs the stream for the last user turn after a failure.
    func retry() {
        guard canRetry else { return }
        start()
    }

    /// Cancels the in-flight stream; whatever already arrived is kept as
    /// the assistant's answer.
    func stop() {
        streamTask?.cancel()
    }

    private func start() {
        isStreaming = true
        errorMessage = nil
        streamingText = ""
        let request = conversation.request(
            system: systemPrompt, contextText: contextText)
        let client = self.client
        streamTask = Task {
            do {
                for try await delta in client.stream(request) {
                    try Task.checkCancellation()
                    streamingText += delta
                }
                finishStreaming()
            } catch is CancellationError {
                finishStreaming()
            } catch {
                // A failed question stays the last turn so `retry` can
                // re-send it; the partial answer is dropped.
                streamingText = ""
                isStreaming = false
                streamTask = nil
                errorMessage = error.localizedDescription
            }
        }
    }

    private func finishStreaming() {
        let answer = streamingText
        streamingText = ""
        isStreaming = false
        streamTask = nil
        if !answer.isEmpty {
            conversation.appendAssistant(answer)
        }
    }
}
