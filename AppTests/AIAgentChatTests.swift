import Testing
import SwiftData
import Foundation
import FinanceCore
@testable import AMFinance

/// Tests for the chat-style agent session (`AIAgentChatSession` +
/// `AIAgentChatProtocol`): the read-only loop — model asks, tools read
/// locally, results ride back as user-role messages — plus the reply
/// contract's tolerant parsing, the tool-step cap, trimming, stable
/// `R…` handles, cancellation and the zero-network access gate.
/// All through a scripted fake `AIChatClientProtocol`, no network.
@MainActor
struct AIAgentChatTests {

    // MARK: - Scaffolding

    private let calendar = AppCalendar.vietnam

    private func makeContext() throws -> ModelContext {
        ModelContext(try AppModelContainer.make(inMemory: true))
    }

    private func day(
        _ year: Int, _ month: Int, _ dayOfMonth: Int, _ hour: Int = 12
    ) -> Date {
        calendar.date(from: DateComponents(
            year: year, month: month, day: dayOfMonth, hour: hour))!
    }

    /// The session's frozen "now" — 15/11/2026, Vietnam calendar.
    private var now: Date { day(2026, 11, 15, 12) }

    /// Scriptable client: queued replies first, `response` once the
    /// queue drains. Every request is recorded BEFORE any hang so a
    /// test can watch a request leave while the reply never lands.
    private final class FakeAIClient: AIChatClientProtocol,
                                    @unchecked Sendable {
        private let lock = NSLock()
        private var recorded: [AIRequest] = []
        private var queued: [Result<String, Error>] = []
        var response = #"{"type":"answer","text":"Được rồi."}"#
        /// Sleeps "forever" inside `complete` — for the stop test.
        var hangOnComplete = false
        /// Cancels the calling task mid-request — proves the post-
        /// `complete` cancellation check discards the reply.
        var cancelInComplete = false

        var requests: [AIRequest] {
            lock.lock()
            defer { lock.unlock() }
            return recorded
        }

        func queueReply(_ text: String) {
            lock.lock()
            queued.append(.success(text))
            lock.unlock()
        }

        private func dequeue(for request: AIRequest) -> Result<String, Error>? {
            lock.lock()
            defer { lock.unlock() }
            recorded.append(request)
            return queued.isEmpty ? nil : queued.removeFirst()
        }

        func complete(_ request: AIRequest) async throws -> AIResponse {
            let result = dequeue(for: request)
            if hangOnComplete { try await Task.sleep(for: .seconds(3600)) }
            if cancelInComplete {
                withUnsafeCurrentTask { $0?.cancel() }
            }
            switch result {
            case .failure(let error): throw error
            case .success(let text): return AIResponse(text: text)
            case nil: return AIResponse(text: response)
            }
        }

        func stream(
            _ request: AIRequest
        ) -> AsyncThrowingStream<String, Error> {
            AsyncThrowingStream { $0.finish() }
        }
    }

    /// Mutable access behind the provider closure — a test can grant
    /// mid-run to prove the level is re-read.
    private final class AccessBox {
        var value: AIAgentAccess
        init(_ value: AIAgentAccess) { self.value = value }
    }

    private func makeSession(
        client: FakeAIClient,
        context: ModelContext,
        access: AccessBox? = nil,
        includeNotes: Bool = true,
        characterBudget: Int = AIAgentChatSession.defaultCharacterBudget
    ) -> AIAgentChatSession {
        AIAgentChatSession(
            client: client,
            context: context,
            accessProvider: { access?.value ?? .scopedRead },
            includeNotes: includeNotes,
            now: { self.now },
            calendar: calendar,
            characterBudget: characterBudget)
    }

    /// Polls a condition — the session task updates state off the call
    /// stack, so assertions wait deterministically.
    private func waitUntil(
        _ condition: @escaping @MainActor () -> Bool
    ) async -> Bool {
        let deadline = ContinuousClock.now + .seconds(10)
        while ContinuousClock.now < deadline {
            if condition() { return true }
            try? await Task.sleep(for: .milliseconds(10))
        }
        return condition()
    }

    @discardableResult
    private func seed(
        in context: ModelContext,
        kind: TransactionKind = .expense,
        amount: Int64 = 400_000,
        date: Date,
        note: String = "",
        account: Account,
        toAccount: Account? = nil,
        category: LedgerCategory? = nil,
        needsReview: Bool = false,
        source: AIAgentSource = .manual
    ) -> LedgerTransaction {
        let row = LedgerTransaction(
            kind: kind, amount: amount, date: date, note: note,
            account: account, toAccount: toAccount, category: category,
            needsReview: needsReview)
        switch source {
        case .manual: break
        case .wallet:
            row.externalSource = WalletSyncEngine.externalSource
            row.externalID = "w-1"
        case .csv:
            row.externalSource = CSVImportDeduper.externalSource
            row.externalID = "c-1"
        case .otherImported:
            row.externalSource = "bank-link"
            row.externalID = "b-1"
        }
        context.insert(row)
        return row
    }

    @discardableResult
    private func seedBasics(
        in context: ModelContext
    ) throws -> (cash: Account, bank: Account,
                 food: LedgerCategory, salary: LedgerCategory) {
        let cash = Account(name: "Tiền mặt", kind: .cash)
        let bank = Account(name: "VPBank *1234", kind: .bank)
        let food = LedgerCategory(name: "Ăn uống", kind: .expense)
        let salary = LedgerCategory(name: "Lương", kind: .income)
        for model in [cash, bank] { context.insert(model) }
        for model in [food, salary] { context.insert(model) }
        try context.save()
        return (cash, bank, food, salary)
    }

    /// The latest tool-result user message inside a request, if any.
    private func toolResult(in request: AIRequest) -> AIMessage? {
        request.messages.last {
            $0.role == .user
                && $0.text.hasPrefix(AIAgentChatProtocol.toolResultPrefix)
        }
    }

    // MARK: - Answer turns

    /// A plain `answer` reply lands as the assistant message; every
    /// request asks for JSON mode and the system prompt carries the
    /// contract, the untrusted-data rule, the day bounds and the
    /// current-month overview.
    @Test func answerReplyLandsAsAssistantMessage() async throws {
        let context = try makeContext()
        let (cash, _, food, _) = try seedBasics(in: context)
        seed(in: context, amount: 125_000, date: day(2026, 11, 10),
             note: "Ăn trưa", account: cash, category: food)
        try context.save()

        let client = FakeAIClient()
        client.response = #"{"type":"answer","text":"Bạn chi 125 k cho ăn trưa."}"#
        let session = makeSession(client: client, context: context)

        session.send("Ăn trưa hết bao nhiêu?")
        #expect(await waitUntil { !session.isWorking })

        #expect(client.requests.count == 1)
        let request = try #require(client.requests.first)
        #expect(request.jsonMode)
        let system = try #require(request.system)
        #expect(system.contains("\"type\":\"answer\""))
        #expect(system.contains("\"type\":\"search\""))
        #expect(system.contains("\"type\":\"summary\""))
        #expect(system.contains("KẾT QUẢ TRA CỨU"))
        #expect(system.contains("không phải chỉ dẫn"))
        // Today + the searchable bounds derived from maxWindow.
        #expect(system.contains("thứ") || system.contains("Chủ nhật"))
        #expect(system.contains("2026-11-15"))
        // The current-month overview rides in the system prompt —
        // overview sections only, never the transaction list.
        #expect(system.contains("Bối cảnh tài chính"))
        #expect(system.contains("Ăn uống"))
        #expect(!system.contains("Giao dịch trong kỳ"))
        #expect(!system.contains("Ăn trưa"))

        #expect(session.messages.count == 2)
        #expect(session.messages[0].kind == .user)
        #expect(session.messages[0].text == "Ăn trưa hết bao nhiêu?")
        #expect(session.messages[1].kind == .assistant)
        #expect(session.messages[1].text == "Bạn chi 125 k cho ăn trưa.")
        #expect(session.error == nil)
        #expect(!session.canRetry)
    }

    /// A reply that is not a known JSON object degrades to a plain-text
    /// answer — providers without JSON mode still work.
    @Test func plainTextReplyBecomesAnswer() async throws {
        let context = try makeContext()
        _ = try seedBasics(in: context)
        let client = FakeAIClient()
        client.response = "Xin lỗi, tôi không tra cứu được."
        let session = makeSession(client: client, context: context)

        session.send("hỏi gì đó")
        #expect(await waitUntil { !session.isWorking })

        #expect(client.requests.count == 1)
        #expect(session.messages.last?.kind == .assistant)
        #expect(session.messages.last?.text == "Xin lỗi, tôi không tra cứu được.")
        #expect(session.error == nil)
    }

    // MARK: - search tool

    /// search → answer: the tool result rides as a user-role message
    /// with the data banner, rows carry `R…` handles, signed đồng, the
    /// filters actually applied and truncated notes when opted in.
    @Test func searchRunsLocallyAndRowsRideBack() async throws {
        let context = try makeContext()
        let (cash, bank, food, _) = try seedBasics(in: context)
        seed(in: context, amount: 125_000, date: day(2026, 11, 10),
             note: "GRAB FOOD", account: bank, needsReview: true,
             source: .wallet)
        seed(in: context, amount: 95_000, date: day(2026, 11, 12),
             note: "grab bike", account: cash, category: food)
        seed(in: context, amount: 50_000, date: day(2026, 11, 11),
             note: "không liên quan", account: cash)
        try context.save()

        let client = FakeAIClient()
        client.queueReply(
            #"{"type":"search","args":{"text":"grab"}}"#)
        client.queueReply(#"{"type":"answer","text":"Có 2 khoản grab."}"#)
        let session = makeSession(client: client, context: context)

        session.send("grab chi bao nhiêu?")
        #expect(await waitUntil { !session.isWorking })

        #expect(client.requests.count == 2)
        let second = try #require(client.requests.last)
        // Transcript: user question → assistant tool call → tool result.
        #expect(second.messages.count == 3)
        #expect(second.messages[1].role == .assistant)
        let tool = try #require(toolResult(in: second))
        // Newest first — "grab bike" (11/12) is R1, "GRAB FOOD" R2.
        #expect(tool.text.contains("\"id\":\"R1\""))
        #expect(tool.text.contains("\"id\":\"R2\""))
        #expect(tool.text.contains("-95000"))
        #expect(tool.text.contains("-125000"))
        #expect(tool.text.contains("\"kind\":\"expense\""))
        #expect(tool.text.contains("\"source\":\"wallet\""))
        #expect(tool.text.contains("\"needsReview\":true"))
        #expect(tool.text.contains("\"category\":\"Ăn uống\""))
        #expect(tool.text.contains("\"account\":\"VPBank *1234\""))
        #expect(tool.text.contains("grab bike"))
        #expect(!tool.text.contains("không liên quan"))

        // Handles resolve through the session's stable map.
        #expect(session.match(forHandle: "R1")?.preview.note == "grab bike")
        #expect(session.match(forHandle: "R2")?.preview.note == "GRAB FOOD")
        #expect(session.match(forHandle: "R9") == nil)

        // The activity note plus the final answer are what the UI sees.
        #expect(session.messages.contains {
            $0.kind == .toolActivity && $0.text == "Đã tìm 2 giao dịch" })
        #expect(session.messages.last?.kind == .assistant)
        #expect(session.messages.last?.text == "Có 2 khoản grab.")
        #expect(session.error == nil)
    }

    /// `includeNotes: false` keeps transaction notes out of the tool
    /// result entirely — the rest of the row is unchanged.
    @Test func searchRowsOmitNotesWhenToggledOff() async throws {
        let context = try makeContext()
        let (_, bank, _, _) = try seedBasics(in: context)
        seed(in: context, amount: 125_000, date: day(2026, 11, 10),
             note: "GHI CHÚ BÍ MẬT", account: bank)
        try context.save()

        let client = FakeAIClient()
        client.queueReply(#"{"type":"search","args":{}}"#)
        client.queueReply(#"{"type":"answer","text":"ok"}"#)
        let session = makeSession(
            client: client, context: context, includeNotes: false)

        session.send("liệt kê")
        #expect(await waitUntil { !session.isWorking })

        let tool = try #require(toolResult(in: client.requests[1]))
        #expect(!tool.text.contains("GHI CHÚ BÍ MẬT"))
        #expect(!tool.text.contains("\"note\""))
        #expect(tool.text.contains("\"account\":\"VPBank *1234\""))
    }

    /// An arg range escaping the granted window is refused inside the
    /// session — the corrective goes out, and the model's fixed reply
    /// completes the turn.
    @Test func outOfWindowArgsEarnCorrectionThenAnswer() async throws {
        let context = try makeContext()
        _ = try seedBasics(in: context)
        let client = FakeAIClient()
        client.queueReply(
            #"{"type":"search","args":{"from":"2020-01-01"}}"#)
        client.queueReply(#"{"type":"answer","text":"Ngoài khoảng cho phép."}"#)
        let session = makeSession(client: client, context: context)

        session.send("xem năm 2020")
        #expect(await waitUntil { !session.isWorking })

        #expect(client.requests.count == 2)
        let second = client.requests[1]
        #expect(second.messages.contains {
            $0.role == .user
                && $0.text.hasPrefix(AIAgentChatProtocol.correctionPrefix) })
        #expect(session.messages.last?.text == "Ngoài khoảng cho phép.")
        #expect(session.error == nil)
    }

    // MARK: - summary tool

    /// summary → the chat snapshot + builder for the custom interval —
    /// the tool result is the period overview text, activity note
    /// included.
    @Test func summaryToolBuildsPeriodOverview() async throws {
        let context = try makeContext()
        let (cash, _, food, _) = try seedBasics(in: context)
        seed(in: context, amount: 100_000, date: day(2026, 11, 10),
             account: cash, category: food)
        try context.save()

        let client = FakeAIClient()
        client.queueReply(
            #"{"type":"summary","args":{"from":"2026-11-01","to":"2026-11-15"}}"#)
        client.queueReply(#"{"type":"answer","text":"Chi 100 k."}"#)
        let session = makeSession(client: client, context: context)

        session.send("tổng quan nửa đầu tháng")
        #expect(await waitUntil { !session.isWorking })

        #expect(client.requests.count == 2)
        let tool = try #require(toolResult(in: client.requests[1]))
        #expect(tool.text.contains("Bối cảnh tài chính"))
        #expect(tool.text.contains("01/11 – 15/11/2026"))
        #expect(tool.text.contains("Ăn uống"))
        #expect(tool.text.contains("100 k"))
        #expect(session.messages.contains {
            $0.kind == .toolActivity
                && $0.text.hasPrefix("Đã tổng hợp") })
        #expect(session.messages.last?.text == "Chi 100 k.")
    }

    /// A span beyond a year is clamped to 366 days — the overview
    /// reports the effective range, not the requested one.
    @Test func summaryClampsTo366Days() async throws {
        let context = try makeContext()
        _ = try seedBasics(in: context)
        let client = FakeAIClient()
        client.queueReply(
            #"{"type":"summary","args":{"from":"2024-01-01","to":"2026-11-15"}}"#)
        client.queueReply(#"{"type":"answer","text":"ok"}"#)
        let session = makeSession(client: client, context: context)

        session.send("tổng quan hai năm")
        #expect(await waitUntil { !session.isWorking })

        let tool = try #require(toolResult(in: client.requests[1]))
        #expect(tool.text.contains("15/11/2025"))
        #expect(!tool.text.contains("2024"))
        #expect(session.error == nil)
    }

    // MARK: - Loop limits

    /// At most four tool executions per turn; the next tool request
    /// earns one final "no tools" call — its answer completes the turn.
    @Test func toolStepCapForcesFinalAnswer() async throws {
        let context = try makeContext()
        let (cash, _, _, _) = try seedBasics(in: context)
        seed(in: context, date: day(2026, 11, 10), account: cash)
        try context.save()
        let client = FakeAIClient()
        for _ in 0..<5 {
            client.queueReply(#"{"type":"search","args":{}}"#)
        }
        client.queueReply(#"{"type":"answer","text":"Đủ dữ liệu rồi."}"#)
        let session = makeSession(client: client, context: context)

        session.send("hỏi")
        #expect(await waitUntil { !session.isWorking })

        // Five contract replies + the one "no tools" final call.
        #expect(client.requests.count == 6)
        #expect(client.requests[5].messages.last?.text
            .hasPrefix(AIAgentChatProtocol.noToolsLeftPrefix) == true)
        #expect(session.messages.last?.text == "Đủ dữ liệu rồi.")
        #expect(session.error == nil)
        // Four tool-activity notes landed — one per execution.
        #expect(session.messages.filter { $0.kind == .toolActivity }.count == 4)
    }

    /// When even the final call asks for a tool, the turn fails with a
    /// typed Vietnamese error instead of spending more requests.
    @Test func toolRequestPastCapFailsTurn() async throws {
        let context = try makeContext()
        let (cash, _, _, _) = try seedBasics(in: context)
        seed(in: context, date: day(2026, 11, 10), account: cash)
        try context.save()
        let client = FakeAIClient()
        client.response = #"{"type":"search","args":{}}"#
        let session = makeSession(client: client, context: context)

        session.send("hỏi")
        #expect(await waitUntil { !session.isWorking })

        #expect(client.requests.count == 6)
        #expect(session.error as? AIAgentChatError == .toolBudgetExhausted)
        #expect(session.canRetry)
    }

    /// Malformed args earn exactly one corrective round — a second bad
    /// reply surfaces the validation error.
    @Test func malformedArgsEarnOneCorrectionThenError() async throws {
        let context = try makeContext()
        _ = try seedBasics(in: context)
        let client = FakeAIClient()
        client.response =
            #"{"type":"search","args":{"from":"15/11/2026"}}"#
        let session = makeSession(client: client, context: context)

        session.send("hỏi")
        #expect(await waitUntil { !session.isWorking })

        #expect(client.requests.count == 2)
        #expect(client.requests[1].messages.contains {
            $0.role == .user
                && $0.text.hasPrefix(AIAgentChatProtocol.correctionPrefix) })
        #expect(session.error as? AIAgentError == .malformedQuery)
        #expect(session.canRetry)
    }

    // MARK: - Access gate

    /// `.off` fails the turn with a typed error and zero requests —
    /// and a retry after the grant lands goes through.
    @Test func accessOffFailsBeforeNetworkThenRetryWorks() async throws {
        let context = try makeContext()
        _ = try seedBasics(in: context)
        let client = FakeAIClient()
        let box = AccessBox(.off)
        let session = makeSession(client: client, context: context,
                                  access: box)

        session.send("hỏi")
        #expect(await waitUntil { !session.isWorking })
        #expect(session.error as? AIAgentError == .permissionDenied)
        #expect(client.requests.isEmpty)
        #expect(session.canRetry)

        box.value = .scopedRead
        client.response = #"{"type":"answer","text":"Chào bạn!"}"#
        session.retry()
        #expect(await waitUntil { !session.isWorking && session.error == nil })
        #expect(client.requests.count == 1)
        #expect(session.messages.last?.text == "Chào bạn!")
    }

    // MARK: - Cancellation

    /// A task cancelled inside `complete` discards the reply that still
    /// arrived — the post-`complete` cancellation check holds.
    @Test func cancelBeforeReplyDiscardsIt() async throws {
        let context = try makeContext()
        _ = try seedBasics(in: context)
        let client = FakeAIClient()
        client.cancelInComplete = true
        client.response = #"{"type":"answer","text":"đã xong"}"#
        let session = makeSession(client: client, context: context)

        session.send("hỏi")
        #expect(await waitUntil { !session.isWorking })

        #expect(client.requests.count == 1)
        #expect(session.messages.count == 1)
        #expect(session.messages[0].kind == .user)
        #expect(session.error == nil)
    }

    /// `stop()` kills the in-flight turn — the user entry stays, no
    /// answer and no error land afterwards.
    @Test func stopDiscardsLateOutput() async throws {
        let context = try makeContext()
        _ = try seedBasics(in: context)
        let client = FakeAIClient()
        client.hangOnComplete = true
        let session = makeSession(client: client, context: context)

        session.send("hỏi")
        #expect(await waitUntil { client.requests.count == 1 })
        session.stop()
        #expect(await waitUntil { !session.isWorking })

        #expect(session.messages.count == 1)
        #expect(session.error == nil)
    }

    // MARK: - Trimming & handles

    /// The trimmer drops older tool results before any real turn text —
    /// the latest result and the user's question always survive.
    @Test func trimmingDropsOlderToolResultsFirst() async throws {
        let context = try makeContext()
        let (cash, _, _, _) = try seedBasics(in: context)
        seed(in: context, amount: 111_000, date: day(2026, 11, 10),
             note: "ALPHA-NOTE-111", account: cash)
        seed(in: context, amount: 222_000, date: day(2026, 11, 12),
             note: "BETA-NOTE-222", account: cash)
        try context.save()

        let client = FakeAIClient()
        client.queueReply(#"{"type":"search","args":{"text":"ALPHA"}}"#)
        client.queueReply(#"{"type":"search","args":{"text":"BETA"}}"#)
        client.queueReply(#"{"type":"answer","text":"xong"}"#)
        let session = makeSession(
            client: client, context: context, characterBudget: 600)

        session.send("hỏi gì")
        #expect(await waitUntil { !session.isWorking })

        let third = try #require(client.requests.last)
        let sent = third.messages.map(\.text).joined(separator: "\n")
        #expect(sent.contains("BETA-NOTE-222"))
        #expect(sent.contains("\"id\":\"R2\""))
        #expect(!sent.contains("ALPHA-NOTE-111"))
        // The user's own question survived — tool results drop first.
        #expect(sent.contains("hỏi gì"))
    }

    /// Handles are stable for the whole session: a row found again in a
    /// later turn keeps its `R…`, a new row mints the next number.
    @Test func handlesStayStableAcrossTurns() async throws {
        let context = try makeContext()
        let (cash, _, _, _) = try seedBasics(in: context)
        let rowA = seed(in: context, amount: 111_000,
                        date: day(2026, 11, 10),
                        note: "alpha row", account: cash)
        seed(in: context, amount: 222_000, date: day(2026, 11, 11),
             note: "beta row", account: cash)
        try context.save()

        let client = FakeAIClient()
        client.queueReply(#"{"type":"search","args":{"text":"alpha"}}"#)
        client.queueReply(#"{"type":"answer","text":"a1"}"#)
        client.queueReply(#"{"type":"search","args":{}}"#)
        client.queueReply(#"{"type":"answer","text":"a2"}"#)
        let session = makeSession(client: client, context: context)

        session.send("q1")
        #expect(await waitUntil { !session.isWorking })
        session.send("q2")
        #expect(await waitUntil {
            !session.isWorking && session.messages.count == 6 })

        #expect(client.requests.count == 4)
        let last = try #require(client.requests.last)
        let tool = try #require(toolResult(in: last))
        // Newest first — "beta row" is new (R2), "alpha row" keeps R1.
        let betaIndex = tool.text.range(of: "\"id\":\"R2\"")
        let alphaIndex = tool.text.range(of: "\"id\":\"R1\"")
        #expect(betaIndex != nil && alphaIndex != nil)
        #expect(betaIndex!.lowerBound < alphaIndex!.lowerBound)
        #expect(session.match(forHandle: "R1")?.original.id == rowA.id)
        #expect(session.match(forHandle: "R2")?.preview.note == "beta row")
    }
}
