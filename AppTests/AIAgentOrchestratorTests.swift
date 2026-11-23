import Testing
import SwiftData
import Foundation
import FinanceCore
@testable import AMFinance

/// Tests for the two-stage `AIAgentOrchestrator`: the stage-1
/// `searchTransactions` planner (bounded request, strict allow-list
/// parsing, permission-before-ledger), the privacy preview + fixed
/// stage-2 request, proposal validation, and the category-edit bridge —
/// all through a fake `AIChatClientProtocol`, no network. The atomic
/// mixed-category apply and the narrowed-window re-resolve are covered
/// here too since the orchestration tests seeded the fixtures.
@MainActor
struct AIAgentOrchestratorTests {

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

    /// The working grant — November 2026 in Vietnam-local days.
    private var window: DateInterval {
        DateInterval(start: day(2026, 11, 1, 0), end: day(2026, 12, 1, 0))
    }

    private func permission(
        _ access: AIAgentAccess = .scopedReadAndProposeCategoryEdits,
        window: DateInterval? = nil
    ) -> AIAgentPermission {
        AIAgentPermission(access: access, window: window ?? self.window)
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

    /// Scriptable client: `response` (or the queued list) per `complete`
    /// call; `stream` is never used by the orchestrator. Records every
    /// request so tests can prove nothing was sent when it shouldn't be.
    private final class FakeAIClient: AIChatClientProtocol,
                                        @unchecked Sendable {
        private let lock = NSLock()
        private var recorded: [AIRequest] = []
        private var queued: [String] = []
        var response = #"{"tool":"searchTransactions","args":{}}"#

        var requests: [AIRequest] {
            lock.lock()
            defer { lock.unlock() }
            return recorded
        }

        func queueReply(_ text: String) {
            lock.lock()
            queued.append(text)
            lock.unlock()
        }

        private func dequeue(for request: AIRequest) -> String? {
            lock.lock()
            defer { lock.unlock() }
            recorded.append(request)
            return queued.isEmpty ? nil : queued.removeFirst()
        }

        func complete(_ request: AIRequest) async throws -> AIResponse {
            AIResponse(text: dequeue(for: request) ?? response)
        }

        func stream(
            _ request: AIRequest
        ) -> AsyncThrowingStream<String, Error> {
            AsyncThrowingStream { $0.finish() }
        }
    }

    private func orchestrator(
        _ client: FakeAIClient,
        now: Date? = nil
    ) -> AIAgentOrchestrator {
        AIAgentOrchestrator(
            client: client,
            now: { now ?? self.day(2026, 11, 15, 12) },
            calendar: calendar)
    }

    /// The serialized stage-2 payload — parses the prepared request's
    /// user message back into a dictionary.
    private func payloadDict(
        _ prepared: AIAgentPreparedAnalysis
    ) throws -> [String: Any] {
        let text = try #require(prepared.request.messages.first?.text)
        let data = try #require(text.data(using: .utf8))
        return try #require(
            try JSONSerialization.jsonObject(with: data) as? [String: Any])
    }

    /// Runs stage 1 with a scripted search reply, then stage-2 prepare.
    private func searchedAndPrepared(
        _ searchReply: String,
        in context: ModelContext,
        question: String = "Tiền đi đâu?",
        options: AIAgentPreviewOptions = AIAgentPreviewOptions(),
        permission: AIAgentPermission? = nil,
        client: FakeAIClient? = nil
    ) async throws -> (prepared: AIAgentPreparedAnalysis,
                       client: FakeAIClient) {
        let fake = client ?? FakeAIClient()
        fake.response = searchReply
        let orchestrator = orchestrator(fake)
        let search = try await orchestrator.search(
            question: question,
            permission: permission ?? self.permission(),
            in: context)
        let prepared = try orchestrator.prepareAnalysis(
            search, options: options,
            permission: permission ?? self.permission(),
            in: context)
        return (prepared, fake)
    }

    // MARK: - Stage 1 request: question only, nothing unapproved

    /// The stage-1 request carries the user's question plus the granted
    /// day range — never ledger rows, category names, account names,
    /// amounts or external ids, and no prior history turns.
    @Test func searchRequestCarriesOnlyQuestionAndGrantBounds()
        async throws {
        let context = try makeContext()
        let (cash, bank, food, _) = try seedBasics(in: context)
        seed(in: context, amount: 125_000, date: day(2026, 11, 10),
             note: "GRAB FOOD", account: bank,
             needsReview: true, source: .wallet)
        seed(in: context, amount: 60_000, date: day(2026, 11, 11),
             note: "Ăn trưa", account: cash, category: food)
        try context.save()

        let fake = FakeAIClient()
        let orchestrator = orchestrator(fake)
        _ = try await orchestrator.search(
            question: "Chi cho grab bao nhiêu?",
            permission: permission(), in: context)

        let request = try #require(fake.requests.first)
        #expect(fake.requests.count == 1)
        #expect(request.jsonMode)
        #expect(request.messages.count == 1)
        #expect(request.messages.first?.role == .user)
        #expect(request.messages.first?.text == "Chi cho grab bao nhiêu?")

        let sent = (request.system ?? "") + "|"
            + request.messages.map(\.text).joined(separator: "|")
        // The grant bounds are the only ledger-adjacent data present.
        #expect(sent.contains("2026-11-01") && sent.contains("2026-11-30"))
        // Nothing from the ledger or the vocabulary may leak in.
        for leak in ["GRAB", "Ăn trưa", "Tiền mặt", "VPBank", "Ăn uống",
                     "Lương", "w-1", "125000", "125.000", "60000"] {
            #expect(!sent.contains(leak), "leaked \(leak)")
        }
    }

    /// The question is cut to the app's bound before it is sent.
    @Test func questionIsBoundedBeforeSending() async throws {
        let context = try makeContext()
        _ = try seedBasics(in: context)
        let fake = FakeAIClient()
        let orchestrator = orchestrator(fake)
        let long = String(repeating: "ă", count: 5_000)
        let search = try await orchestrator.search(
            question: long, permission: permission(), in: context)

        let sent = try #require(fake.requests.first?.messages.first?.text)
        #expect(sent.count == AIAgentToolPlanner.maxQuestionLength)
        #expect(search.question.count == AIAgentToolPlanner.maxQuestionLength)
    }

    /// Denied and oversized grants fail before the request leaves — the
    /// fake records zero calls.
    @Test func searchDeniesPermissionBeforeNetwork() async throws {
        let context = try makeContext()
        _ = try seedBasics(in: context)
        let fake = FakeAIClient()
        let orchestrator = orchestrator(fake)

        await #expect(throws: AIAgentError.permissionDenied) {
            _ = try await orchestrator.search(
                question: "x", permission: .off, in: context)
        }
        let wide = permission(window: DateInterval(
            start: day(2026, 1, 1, 0), end: day(2026, 6, 1, 0)))
        await #expect(throws: AIAgentError.windowTooWide) {
            _ = try await orchestrator.search(
                question: "x", permission: wide, in: context)
        }
        let readOnly = AIAgentPermission(access: .scopedRead, window: window)
        // A read-only grant may still search — but a blank question may not.
        await #expect(throws: AIAgentError.malformedQuery) {
            _ = try await orchestrator.search(
                question: "   ", permission: readOnly, in: context)
        }
        #expect(fake.requests.isEmpty)
    }

    // MARK: - Stage 1 parsing → typed bounded lookup

    /// A valid tool call maps onto the typed query: `to` is an inclusive
    /// day (the interval ends at the next day start) and every filter
    /// axis lands where the lookup expects it.
    @Test func searchRunsParsedFiltersThroughLookup() async throws {
        let context = try makeContext()
        let (cash, bank, _, _) = try seedBasics(in: context)
        seed(in: context, amount: 125_000, date: day(2026, 11, 10),
             note: "GRAB FOOD", account: bank,
             needsReview: true, source: .wallet)
        seed(in: context, amount: 95_000, date: day(2026, 11, 12),
             note: "grab bike", account: cash, source: .wallet)
        seed(in: context, date: day(2026, 11, 13), note: "ngày sau",
             account: cash)
        try context.save()

        let fake = FakeAIClient()
        fake.response = """
        {"tool":"searchTransactions","args":{"from":"2026-11-10",
            "to":"2026-11-12","kind":"expense","source":"wallet",
            "text":"grab"}}
        """
        let search = try await orchestrator(fake).search(
            question: "grab tuần này",
            permission: permission(), in: context)

        #expect(search.query.kind == .expense)
        #expect(search.query.source == .wallet)
        #expect(search.query.text == "grab")
        let interval = try #require(search.query.interval)
        #expect(interval.start == day(2026, 11, 10, 0))
        #expect(interval.end == day(2026, 11, 13, 0))
        // The 11/13 row sits outside the inclusive "to".
        #expect(search.result.matches.map(\.preview.note)
            == ["grab bike", "GRAB FOOD"])
        #expect(search.result.window == interval)
    }

    /// Wrong tool, non-dict args, unknown fields, bad dates, inverted
    /// ranges and bounds — every malformed reply fails before the read.
    @Test func searchRejectsWrongToolAndMalformedArgs() async throws {
        let context = try makeContext()
        let (cash, _, _, _) = try seedBasics(in: context)
        seed(in: context, date: day(2026, 11, 10), account: cash)
        try context.save()
        let fake = FakeAIClient()
        let orchestrator = orchestrator(fake)

        // A different tool name → not the allow-listed call.
        fake.response = #"{"tool":"deleteTransactions","args":{}}"#
        await #expect(throws: AIAgentError.unsupportedTool) {
            _ = try await orchestrator.search(
                question: "x", permission: permission(), in: context)
        }
        // Missing tool name → not the allow-listed call.
        fake.response = #"{"args":{"kind":"expense"}}"#
        await #expect(throws: AIAgentError.unsupportedTool) {
            _ = try await orchestrator.search(
                question: "x", permission: permission(), in: context)
        }
        // args must be an object.
        fake.response = #"{"tool":"searchTransactions","args":[1,2]}"#
        await #expect(throws: AIAgentError.malformedQuery) {
            _ = try await orchestrator.search(
                question: "x", permission: permission(), in: context)
        }
        // Unknown arg fields are refused — strict allow-list.
        fake.response = #"{"tool":"searchTransactions","args":{"account":"Tiền mặt"}}"#
        await #expect(throws: AIAgentError.malformedQuery) {
            _ = try await orchestrator.search(
                question: "x", permission: permission(), in: context)
        }
        // Bad day strings and inverted ranges.
        for reply in [
            #"{"tool":"searchTransactions","args":{"from":"10/11/2026"}}"#,
            #"{"tool":"searchTransactions","args":{"from":"2026-13-01"}}"#,
            #"{"tool":"searchTransactions","args":{"from":"2026-11-20","to":"2026-11-10"}}"#,
            #"{"tool":"searchTransactions","args":{"to":"hôm qua"}}"#,
        ] {
            fake.response = reply
            await #expect(throws: AIAgentError.malformedQuery) {
                _ = try await orchestrator.search(
                    question: "x", permission: permission(), in: context)
            }
        }
        // Inverted/negative bounds and a boolean-as-amount.
        for reply in [
            #"{"tool":"searchTransactions","args":{"minAmount":500,"maxAmount":100}}"#,
            #"{"tool":"searchTransactions","args":{"minAmount":-5}}"#,
            #"{"tool":"searchTransactions","args":{"maxAmount":true}}"#,
        ] {
            fake.response = reply
            await #expect(throws: AIAgentError.malformedQuery) {
                _ = try await orchestrator.search(
                    question: "x", permission: permission(), in: context)
            }
        }
        // Unknown enum values.
        for reply in [
            #"{"tool":"searchTransactions","args":{"kind":"saving"}}"#,
            #"{"tool":"searchTransactions","args":{"source":"bank"}}"#,
            #"{"tool":"searchTransactions","args":{"needsReview":"yes"}}"#,
        ] {
            fake.response = reply
            await #expect(throws: AIAgentError.malformedQuery) {
                _ = try await orchestrator.search(
                    question: "x", permission: permission(), in: context)
            }
        }
        // Overlong search text.
        fake.response = """
        {"tool":"searchTransactions","args":{"text":"\(String(repeating: "a", count: 200))"}}
        """
        await #expect(throws: AIAgentError.malformedQuery) {
            _ = try await orchestrator.search(
                question: "x", permission: permission(), in: context)
        }
        // A day range escaping the grant — refused, not clipped.
        for reply in [
            #"{"tool":"searchTransactions","args":{"from":"2026-10-01"}}"#,
            #"{"tool":"searchTransactions","args":{"to":"2026-12-15"}}"#,
            #"{"tool":"searchTransactions","args":{"from":"2027-01-05","to":"2027-01-10"}}"#,
        ] {
            fake.response = reply
            await #expect(throws: AIAgentError.queryOutsideWindow) {
                _ = try await orchestrator.search(
                    question: "x", permission: permission(), in: context)
            }
        }
        // Only the malformed replies produced requests — and the ledger
        // row was never touched.
        #expect(fake.requests.count > 0)
        #expect(!context.hasChanges)
    }

    /// A reply with no usable JSON at all is a stage failure.
    @Test func searchUnparseableReplyThrows() async throws {
        let context = try makeContext()
        _ = try seedBasics(in: context)
        let fake = FakeAIClient()
        fake.response = "Xin lỗi, tôi không hiểu."
        await #expect(throws: AIAgentError.unparseableModelReply) {
            _ = try await orchestrator(fake).search(
                question: "x", permission: permission(), in: context)
        }
    }

    // MARK: - Stage 2 preview: the exact privacy projection

    /// The prepared payload carries only ephemeral handles and the
    /// allowed fields — no notes or account names by default, no real
    /// ids, external ids or balances anywhere.
    @Test func previewIsExactPrivacyProjection() async throws {
        let context = try makeContext()
        let (cash, bank, food, _) = try seedBasics(in: context)
        let row = seed(in: context, amount: 125_000,
                       date: day(2026, 11, 10), note: "GRAB FOOD ăn trưa",
                       account: bank, needsReview: true, source: .wallet)
        seed(in: context, kind: .transfer, amount: 900_000,
             date: day(2026, 11, 11), account: cash, toAccount: bank)
        try context.save()

        let (prepared, _) = try await searchedAndPrepared(
            #"{"tool":"searchTransactions","args":{}}"#,
            in: context, question: "Liệt kê")

        #expect(prepared.request.jsonMode)
        #expect(prepared.grantsProposals)
        #expect(prepared.effectiveWindow == window)
        #expect(prepared.matches.count == 2)
        #expect(prepared.categories.map(\.handle) == ["C1", "C2"])
        #expect(Set(prepared.categories.map(\.name))
            == ["Ăn uống", "Lương"])

        let payload = try payloadDict(prepared)
        #expect(payload["question"] as? String == "Liệt kê")
        #expect(payload["truncated"] as? Bool == false)
        #expect(payload["scanned"] as? Int == 2)
        let rows = try #require(payload["rows"] as? [[String: Any]])
        #expect(rows.count == 2)
        for item in rows {
            #expect(Set(item.keys).isSubset(of: [
                "id", "kind", "amount", "date", "category", "source",
                "needsReview", "canEdit",
            ]))
        }
        // Newest first — the transfer row is R1 and is not editable.
        #expect(rows[0]["id"] as? String == "R1")
        #expect(rows[0]["kind"] as? String == "transfer")
        #expect(rows[0]["canEdit"] as? Bool == false)
        #expect(rows[1]["id"] as? String == "R2")
        #expect(rows[1]["canEdit"] as? Bool == true)
        #expect(rows[1]["amount"] as? Int64 == 125_000)
        #expect(rows[1]["date"] as? String == "2026-11-10")
        #expect(rows[1]["source"] as? String == "wallet")

        // The whole serialized request must stay clean of real
        // identifiers and details.
        let sent = prepared.request.messages[0].text
            + (prepared.request.system ?? "")
        for leak in [row.id.uuidString, "w-1", "VPBank", "GRAB FOOD",
                     "externalID", "balance"] {
            #expect(!sent.contains(leak), "leaked \(leak)")
        }
        let catalog = try #require(payload["categories"] as? [String: Any])
        #expect((catalog["expense"] as? [[String: Any]])?.count == 1)
        #expect((catalog["income"] as? [[String: Any]])?.count == 1)
    }

    /// Opt-in adds notes and account names — bounded — to both the
    /// preview rows and the outgoing payload.
    @Test func optInAddsBoundedNotesAndAccountNames() async throws {
        let context = try makeContext()
        let (cash, _, _, _) = try seedBasics(in: context)
        seed(in: context, date: day(2026, 11, 10),
             note: String(repeating: "x", count: 200),
             account: cash)
        try context.save()
        let options = AIAgentPreviewOptions(
            includeNotes: true, includeAccountNames: true)
        let (prepared, _) = try await searchedAndPrepared(
            #"{"tool":"searchTransactions","args":{}}"#,
            in: context, options: options)

        let row = try #require(prepared.preview.rows.first)
        #expect(row.note?.count == AIAgentOrchestrator.maxNoteLength)
        #expect(row.note?.hasSuffix("…") == true)
        #expect(row.accountName == "Tiền mặt")
        let payload = try payloadDict(prepared)
        let items = try #require(payload["rows"] as? [[String: Any]])
        #expect((items[0]["note"] as? String)?.count
            == AIAgentOrchestrator.maxNoteLength)
        #expect(items[0]["account"] as? String == "Tiền mặt")
    }

    /// A read-only grant mints no category handles and no catalog — the
    /// model cannot be offered what the grant forbids.
    @Test func readOnlyGrantOmitsCatalogAndHandles() async throws {
        let context = try makeContext()
        let (cash, _, _, _) = try seedBasics(in: context)
        seed(in: context, date: day(2026, 11, 10), account: cash)
        try context.save()
        let read = permission(.scopedRead)
        let (prepared, _) = try await searchedAndPrepared(
            #"{"tool":"searchTransactions","args":{}}"#,
            in: context, permission: read)
        #expect(!prepared.grantsProposals)
        #expect(prepared.categories.isEmpty)
        let payload = try payloadDict(prepared)
        #expect(payload["categories"] == nil)
    }

    // MARK: - Stage 2 analyze: verbatim request + validated reply

    /// `analyze` sends exactly the request `prepareAnalysis` minted —
    /// byte for byte.
    @Test func analyzeSendsPreparedRequestVerbatim() async throws {
        let context = try makeContext()
        let (cash, _, _, _) = try seedBasics(in: context)
        seed(in: context, date: day(2026, 11, 10), account: cash)
        try context.save()
        let (prepared, fake) = try await searchedAndPrepared(
            #"{"tool":"searchTransactions","args":{}}"#,
            in: context)
        fake.queueReply(#"{"answer":"Có 1 khoản.","proposals":[]}"#)
        let analysis = try await orchestrator(fake).analyze(
            prepared, permission: permission())
        #expect(fake.requests.last == prepared.request)
        #expect(analysis.answer == "Có 1 khoản.")
        #expect(analysis.proposals.isEmpty)
        #expect(analysis.proposalRejection == nil)
        #expect(analysis.effectiveWindow == window)
    }

    /// A valid proposal maps back through the ephemeral handles to the
    /// lookup match and the snapped category — nothing applied.
    @Test func analyzeMapsValidProposalsThroughHandles() async throws {
        let context = try makeContext()
        let (cash, _, food, _) = try seedBasics(in: context)
        let row = seed(in: context, amount: 88_000,
                       date: day(2026, 11, 10), note: "cà phê",
                       account: cash)
        try context.save()
        let (prepared, fake) = try await searchedAndPrepared(
            #"{"tool":"searchTransactions","args":{}}"#,
            in: context)
        let foodHandle = try #require(prepared.categories.first {
            $0.id == food.id }).handle
        fake.queueReply("""
        {"answer":"Gán vào Ăn uống?","proposals":[
            {"action":"setCategory","row":"R1","category":"\(foodHandle)"}]}
        """)
        let analysis = try await orchestrator(fake).analyze(
            prepared, permission: permission())
        #expect(analysis.proposals.count == 1)
        let proposal = try #require(analysis.proposals.first)
        #expect(proposal.row.handle == "R1")
        #expect(proposal.match.original.id == row.id)
        #expect(proposal.category.id == food.id)
        #expect(proposal.category.name == "Ăn uống")
        // Nothing was written — the proposal is inert data.
        #expect(row.category == nil)
        #expect(!context.hasChanges)
    }

    /// Every rule the proposal validator enforces, each voiding the
    /// whole list while the answer survives.
    @Test func analyzeRejectsBadProposalsWholesale() async throws {
        let context = try makeContext()
        let (cash, bank, food, salary) = try seedBasics(in: context)
        let expense = seed(in: context, date: day(2026, 11, 10),
                           note: "chi", account: cash)
        seed(in: context, kind: .income, date: day(2026, 11, 11),
             note: "thu", account: bank)
        seed(in: context, kind: .transfer, date: day(2026, 11, 12),
             account: cash, toAccount: bank)
        let done = seed(in: context, date: day(2026, 11, 13),
                        note: "đã gán", account: cash, category: food)
        try context.save()
        let (prepared, fake) = try await searchedAndPrepared(
            #"{"tool":"searchTransactions","args":{}}"#,
            in: context)
        let foodHandle = try #require(prepared.categories.first {
            $0.id == food.id }).handle
        let salaryHandle = try #require(prepared.categories.first {
            $0.id == salary.id }).handle
        // Rows are newest-first: R1 "đã gán", R2 transfer, R3 "thu", R4 "chi".
        func handle(of row: LedgerTransaction) throws -> String {
            try #require(prepared.matches.first {
                $0.value.original.id == row.id }).key
        }
        let expenseHandle = try handle(of: expense)
        let doneHandle = try handle(of: done)

        func reply(_ proposals: String) -> String {
            #"{"answer":"ok","proposals":\#(proposals)}"#
        }
        func rejection(for text: String) async throws -> AIAgentError? {
            fake.queueReply(text)
            return try await orchestrator(fake)
                .analyze(prepared, permission: permission())
                .proposalRejection
        }

        // Unknown / out-of-scope handles.
        #expect(try await rejection(for: reply(
            #"[{"action":"setCategory","row":"R99","category":"\#(foodHandle)"}]"#))
            == .unknownHandle)
        #expect(try await rejection(for: reply(
            #"[{"action":"setCategory","row":"R1","category":"C99"}]"#))
            == .unknownHandle)
        // Same row twice — on an unclassified row so the first passes.
        #expect(try await rejection(for: reply(
            #"[{"action":"setCategory","row":"\#(expenseHandle)","category":"\#(foodHandle)"},{"action":"setCategory","row":"\#(expenseHandle)","category":"\#(foodHandle)"}]"#))
            == .duplicateTransaction)
        // The transfer row can never receive a category.
        #expect(try await rejection(for: reply(
            #"[{"action":"setCategory","row":"R2","category":"\#(foodHandle)"}]"#))
            == .transactionNotEligible)
        // An income row cannot take an expense category (wrong direction).
        #expect(try await rejection(for: reply(
            #"[{"action":"setCategory","row":"R3","category":"\#(foodHandle)"}]"#))
            == .invalidCategory)
        // …but the income category on an expense row fails the same way.
        #expect(try await rejection(for: reply(
            #"[{"action":"setCategory","row":"\#(expenseHandle)","category":"\#(salaryHandle)"}]"#))
            == .invalidCategory)
        // Re-picking the category a clean row already has is a no-op.
        #expect(try await rejection(for: reply(
            #"[{"action":"setCategory","row":"\#(doneHandle)","category":"\#(foodHandle)"}]"#))
            == .noOpEdit)
        // Unsupported actions.
        #expect(try await rejection(for: reply(
            #"[{"action":"delete","row":"R1"}]"#)) == .unsupportedTool)
        #expect(try await rejection(for: reply(
            #"[{"action":"setAmount","row":"R1","amount":1}]"#))
            == .unsupportedTool)
        // Structurally bad items.
        #expect(try await rejection(for: reply(#"["x"]"#))
            == .invalidProposal)
        #expect(try await rejection(for: reply(
            #"[{"row":"R1","category":"C1"}]"#)) == .invalidProposal)
        #expect(try await rejection(for:
            #"{"answer":"ok","proposals":{"row":"R1"}}"#)
            == .invalidProposal)
        // Over the cap.
        let many = (1...31).map {
            #"{"action":"setCategory","row":"R\#($0)","category":"\#(foodHandle)"}"#
        }.joined(separator: ",")
        #expect(try await rejection(for: reply("[\(many)]"))
            == .tooManyProposals)
        // The answer was never lost through any of this.
        #expect(!context.hasChanges)
    }

    /// `analyze` re-checks the grant before the request leaves: revoked
    /// is refused outright, and a proposal-scoped request fails under a
    /// read-only grant — in both cases zero network.
    @Test func analyzeRechecksPermissionBeforeNetwork() async throws {
        let context = try makeContext()
        let (cash, _, _, _) = try seedBasics(in: context)
        seed(in: context, date: day(2026, 11, 10), account: cash)
        try context.save()
        let (prepared, fake) = try await searchedAndPrepared(
            #"{"tool":"searchTransactions","args":{}}"#,
            in: context)
        let sent = fake.requests.count

        await #expect(throws: AIAgentError.permissionDenied) {
            _ = try await orchestrator(fake).analyze(
                prepared, permission: .off)
        }
        await #expect(throws: AIAgentError.permissionDenied) {
            _ = try await orchestrator(fake).analyze(
                prepared, permission: permission(.scopedRead))
        }
        #expect(fake.requests.count == sent)
    }

    /// Prepared without proposals and analyzed under a read-only grant:
    /// the analysis still runs, but proposals the model emits anyway are
    /// refused wholesale.
    @Test func readOnlyAnalysisRefusesEmittedProposals() async throws {
        let context = try makeContext()
        let (cash, _, _, _) = try seedBasics(in: context)
        seed(in: context, date: day(2026, 11, 10), account: cash)
        try context.save()
        let read = permission(.scopedRead)
        let (prepared, fake) = try await searchedAndPrepared(
            #"{"tool":"searchTransactions","args":{}}"#,
            in: context, permission: read)
        fake.queueReply(#"{"answer":"x","proposals":[{"action":"setCategory","row":"R1","category":"C1"}]}"#)
        let analysis = try await orchestrator(fake).analyze(
            prepared, permission: read)
        #expect(analysis.answer == "x")
        #expect(analysis.proposals.isEmpty)
        #expect(analysis.proposalRejection == .permissionDenied)
    }

    /// A reply with no JSON object at all fails the whole stage.
    @Test func analyzeUnparseableReplyThrows() async throws {
        let context = try makeContext()
        let (cash, _, _, _) = try seedBasics(in: context)
        seed(in: context, date: day(2026, 11, 10), account: cash)
        try context.save()
        let (prepared, fake) = try await searchedAndPrepared(
            #"{"tool":"searchTransactions","args":{}}"#,
            in: context)
        fake.queueReply("Tôi xin lỗi nhé")
        await #expect(throws: AIAgentError.unparseableModelReply) {
            _ = try await orchestrator(fake).analyze(
                prepared, permission: permission())
        }
    }

    /// The full flow writes nothing: search, prepare and analyze are
    /// all side-effect-free — a confirmed apply is a separate call.
    @Test func neitherStageWrites() async throws {
        let context = try makeContext()
        let (cash, _, food, _) = try seedBasics(in: context)
        let row = seed(in: context, date: day(2026, 11, 10),
                       account: cash, needsReview: true)
        try context.save()
        let (prepared, fake) = try await searchedAndPrepared(
            #"{"tool":"searchTransactions","args":{}}"#,
            in: context)
        let foodHandle = try #require(prepared.categories.first {
            $0.id == food.id }).handle
        fake.queueReply("""
        {"answer":"ok","proposals":[
            {"action":"setCategory","row":"R1","category":"\(foodHandle)"}]}
        """)
        let analysis = try await orchestrator(fake).analyze(
            prepared, permission: permission())
        #expect(analysis.proposals.count == 1)
        #expect(row.category == nil)
        #expect(row.needsReview)
        #expect(!context.hasChanges)
    }

    // MARK: - Confirmed edits → atomic apply

    /// `categoryEdits` resolves the snapped handles to live categories —
    /// and refuses the batch when one drifted since the preview.
    @Test func confirmedEditsDetectCategoryDrift() async throws {
        let context = try makeContext()
        let (cash, _, food, _) = try seedBasics(in: context)
        seed(in: context, date: day(2026, 11, 10), account: cash)
        try context.save()
        let (prepared, fake) = try await searchedAndPrepared(
            #"{"tool":"searchTransactions","args":{}}"#,
            in: context)
        let foodHandle = try #require(prepared.categories.first {
            $0.id == food.id }).handle
        fake.queueReply("""
        {"answer":"ok","proposals":[
            {"action":"setCategory","row":"R1","category":"\(foodHandle)"}]}
        """)
        let analysis = try await orchestrator(fake).analyze(
            prepared, permission: permission())

        // Fresh state resolves.
        let edits = try analysis.categoryEdits(in: context)
        #expect(edits.count == 1)
        #expect(edits[0].category.id == food.id)
        #expect(edits[0].match.original.id
            == analysis.proposals[0].match.original.id)

        // Renamed since the preview → the snapped handle is stale.
        food.name = "Đồ ăn"
        try context.save()
        #expect(throws: AIAgentError.staleCategory) {
            _ = try analysis.categoryEdits(in: context)
        }
        food.name = "Ăn uống"
        try context.save()
        _ = try analysis.categoryEdits(in: context)

        // Archived since the preview.
        food.isArchived = true
        try context.save()
        #expect(throws: AIAgentError.staleCategory) {
            _ = try analysis.categoryEdits(in: context)
        }
        food.isArchived = false
        try context.save()

        // Deleted since the preview.
        context.delete(food)
        try context.save()
        #expect(throws: AIAgentError.staleCategory) {
            _ = try analysis.categoryEdits(in: context)
        }
    }

    /// End to end: proposals → confirmed edits → the mixed batch apply —
    /// one commit, different categories per row.
    @Test func applyLandsMixedCategoriesAtomically() async throws {
        let context = try makeContext()
        let (cash, bank, food, salary) = try seedBasics(in: context)
        let other = LedgerCategory(name: "Di chuyển", kind: .expense)
        context.insert(other)
        let coffee = seed(in: context, amount: 40_000,
                          date: day(2026, 11, 10), note: "cf",
                          account: cash)
        let taxi = seed(in: context, amount: 150_000,
                        date: day(2026, 11, 11), note: "grab",
                        account: bank)
        let pay = seed(in: context, kind: .income, amount: 9_000_000,
                       date: day(2026, 11, 12), note: "lương",
                       account: bank)
        try context.save()
        let (prepared, fake) = try await searchedAndPrepared(
            #"{"tool":"searchTransactions","args":{}}"#,
            in: context)
        func handle(_ category: LedgerCategory) throws -> String {
            try #require(prepared.categories.first {
                $0.id == category.id }).handle
        }
        func row(_ transaction: LedgerTransaction) throws -> String {
            try #require(prepared.matches.first {
                $0.value.original.id == transaction.id }).key
        }
        fake.queueReply("""
        {"answer":"ok","proposals":[
            {"action":"setCategory","row":"\(try row(coffee))","category":"\(try handle(food))"},
            {"action":"setCategory","row":"\(try row(taxi))","category":"\(try handle(other))"},
            {"action":"setCategory","row":"\(try row(pay))","category":"\(try handle(salary))"}]}
        """)
        let analysis = try await orchestrator(fake).analyze(
            prepared, permission: permission())
        #expect(analysis.proposals.count == 3)

        // The PR3 flow: confirmed edits → one atomic mixed apply over
        // the effective lookup window.
        let edits = try analysis.categoryEdits(in: context)
        let result = try AIAgentLedgerTools().applyCategoryEdits(
            edits, permission: permission(), in: context,
            lookupWindow: analysis.effectiveWindow)
        #expect(result.appliedCount == 3)
        #expect(coffee.category?.id == food.id)
        #expect(taxi.category?.id == other.id)
        #expect(pay.category?.id == salary.id)
        #expect(!context.hasChanges)
    }

    /// The mixed batch still dies whole: one stale target rolls back
    /// the other valid edit.
    @Test func mixedApplyIsAtomicWhenStale() async throws {
        let context = try makeContext()
        let (cash, bank, food, _) = try seedBasics(in: context)
        let other = LedgerCategory(name: "Di chuyển", kind: .expense)
        context.insert(other)
        let moved = seed(in: context, date: day(2026, 11, 10),
                         account: cash)
        let clean = seed(in: context, date: day(2026, 11, 11),
                         account: bank)
        try context.save()
        let tools = AIAgentLedgerTools()
        let looked = try tools.lookup(permission: permission(), in: context)
        func match(_ row: LedgerTransaction) throws -> AIAgentLookupMatch {
            try #require(looked.matches.first { $0.original.id == row.id })
        }
        let edits = [
            AIAgentCategoryEdit(match: try match(moved), category: food),
            AIAgentCategoryEdit(match: try match(clean), category: other),
        ]
        moved.note = "đổi rồi"
        moved.updatedAt = .now
        try context.save()
        #expect(throws: AIAgentError.staleTransaction) {
            _ = try tools.applyCategoryEdits(
                edits, permission: permission(), in: context)
        }
        #expect(moved.category == nil && clean.category == nil)
        #expect(!context.hasChanges)
    }

    /// A narrowed lookup's matches re-resolve inside that same window —
    /// even when the grant's broader first-scanLimit slice would have
    /// missed them. Passing no lookupWindow falls back to the grant and
    /// honestly reports stale.
    @Test func applyReResolvesInsideNarrowedLookupWindow() async throws {
        let context = try makeContext()
        let (cash, _, food, _) = try seedBasics(in: context)
        // Fill the grant's head so the bounded grant slice cannot reach
        // the target day.
        for index in 1...20 {
            seed(in: context, date: day(2026, 11, 29, 0)
                .addingTimeInterval(TimeInterval(index * 60)),
                 note: "filler \(index)", account: cash)
        }
        let target = seed(in: context, date: day(2026, 11, 5),
                          note: "mục tiêu", account: cash)
        try context.save()
        let tools = AIAgentLedgerTools(scanLimit: 10)
        let narrowed = DateInterval(
            start: day(2026, 11, 5, 0), end: day(2026, 11, 6, 0))
        let looked = try tools.lookup(
            AIAgentLookupQuery(interval: narrowed),
            permission: permission(), in: context)
        #expect(looked.matches.count == 1)
        #expect(looked.window == narrowed)

        let edit = AIAgentCategoryEdit(
            match: looked.matches[0], category: food)
        // Same effective window → the row re-resolves and applies.
        let applied = try tools.applyCategoryEdits(
            [edit], permission: permission(), in: context,
            lookupWindow: narrowed)
        #expect(applied.appliedCount == 1)
        #expect(target.category?.id == food.id)
        target.category = nil
        try context.save()

        // The un-narrowed path re-scans only the grant's first slice —
        // the target is beyond it, so the snapshot reads as stale.
        #expect(throws: AIAgentError.staleTransaction) {
            _ = try tools.applyCategoryEdits(
                [edit], permission: permission(), in: context)
        }
        // And a window escaping the grant is refused, not used.
        #expect(throws: AIAgentError.queryOutsideWindow) {
            _ = try tools.applyCategoryEdits(
                [edit], permission: permission(), in: context,
                lookupWindow: DateInterval(
                    start: day(2026, 10, 1, 0), end: day(2026, 12, 1, 0)))
        }
    }
}
