import Testing
import SwiftData
import Foundation
import FinanceCore
@testable import AMFinance

/// Tests for the conversation persistence engine: the session's
/// `snapshot()`/`restoring:` round trip (visible messages, transcript,
/// handle numbering; live matches re-minted under the SAME handle by a
/// fresh search; no pending proposal; the "handles need a fresh
/// search" transcript note), the `onStateChange` auto-save hook, and
/// `AIAgentConversationStore`'s file store — save/load/list ordering,
/// delete, pruning, per-conversation bounds, corrupt and
/// unknown-version files, title derivation, the version field.
/// Scripted fake client, temp directory — no network, no real
/// Application Support.
@MainActor
struct AIAgentConversationStoreTests {

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
        private var queued: [String] = []
        var response = #"{"type":"answer","text":"Được rồi."}"#
        /// Sleeps "forever" inside `complete` — for the stop test.
        var hangOnComplete = false

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
            let reply = dequeue(for: request)
            if hangOnComplete { try await Task.sleep(for: .seconds(3600)) }
            return AIResponse(text: reply ?? response)
        }

        func stream(
            _ request: AIRequest
        ) -> AsyncThrowingStream<String, Error> {
            AsyncThrowingStream { $0.finish() }
        }
    }

    /// Mutable access behind the provider closure.
    private final class AccessBox {
        var value: AIAgentAccess
        init(_ value: AIAgentAccess) { self.value = value }
    }

    /// Counts `onStateChange` firings — a plain box the hook closes
    /// over.
    private final class HookCounter {
        var value = 0
    }

    /// An isolated defaults suite — the last-used account key stays
    /// out of the app's real defaults.
    private func makeDefaults(_ name: String) -> UserDefaults {
        let suite = "AIAgentConversationStoreTests.\(name)"
        let defaults = UserDefaults(suiteName: suite)!
        defaults.removePersistentDomain(forName: suite)
        return defaults
    }

    private func makeSession(
        client: FakeAIClient,
        context: ModelContext,
        access: AccessBox? = nil,
        restoring state: AIAgentConversationState? = nil
    ) -> AIAgentChatSession {
        AIAgentChatSession(
            client: client,
            context: context,
            accessProvider: {
                access?.value ?? .scopedReadAndProposeCategoryEdits },
            defaults: makeDefaults("session"),
            now: { self.now },
            calendar: calendar,
            restoring: state)
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
        category: LedgerCategory? = nil
    ) -> LedgerTransaction {
        let row = LedgerTransaction(
            kind: kind, amount: amount, date: date, note: note,
            account: account, category: category)
        context.insert(row)
        return row
    }

    @discardableResult
    private func seedBasics(
        in context: ModelContext
    ) throws -> (cash: Account, bank: Account,
                 food: LedgerCategory, salary: LedgerCategory) {
        let cash = Account(name: "10 Tiền mặt", kind: .cash)
        let bank = Account(name: "20 Ngân hàng", kind: .bank)
        let food = LedgerCategory(name: "30 Ăn uống", kind: .expense)
        let salary = LedgerCategory(name: "40 Lương", kind: .income)
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

    /// A `"actions"` reply around the given items.
    private func actionsReply(
        _ text: String, _ items: String
    ) -> String {
        #"{"type":"actions","text":""# + text
            + #"","actions":["# + items + "]}"
    }

    /// A fresh temp directory per test — the store only ever sees this.
    private func makeTempDirectory(_ name: String) throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent(
                "AIAgentConversationStoreTests-\(name)-\(UUID().uuidString)",
                isDirectory: true)
        try FileManager.default.createDirectory(
            at: url, withIntermediateDirectories: true)
        return url
    }

    /// A state carrying `count` tiny user messages — the store tests'
    /// quick record filler.
    private func makeState(
        messageCount: Int = 2
    ) -> AIAgentConversationState {
        var state = AIAgentConversationState()
        for index in 0..<messageCount {
            state.messages.append(AIAgentChatMessage(
                kind: index.isMultiple(of: 2) ? .user : .assistant,
                text: "msg \(index)"))
        }
        return state
    }

    /// Runs one `search` → `answer` turn that mints `R…` handles for
    /// every seeded "grab" row, then returns the snapshot.
    private func runGrabTurn(
        in context: ModelContext, client: FakeAIClient
    ) async -> (session: AIAgentChatSession,
                state: AIAgentConversationState) {
        client.queueReply(#"{"type":"search","args":{"text":"grab"}}"#)
        client.queueReply(#"{"type":"answer","text":"Có khoản grab."}"#)
        let session = makeSession(client: client, context: context)
        session.send("grab chi bao nhiêu?")
        _ = await waitUntil { !session.isWorking }
        return (session, session.snapshot())
    }

    // MARK: - Session snapshot & restore

    /// `snapshot()` carries the version, the visible messages, the
    /// transcript and every handle map — and JSON round-trips exactly.
    @Test func snapshotCapturesStateAndRoundTrips() async throws {
        let context = try makeContext()
        let (cash, bank, food, _) = try seedBasics(in: context)
        seed(in: context, amount: 95_000, date: day(2026, 11, 12),
             note: "grab bike", account: cash, category: food)
        seed(in: context, amount: 125_000, date: day(2026, 11, 10),
             note: "GRAB FOOD", account: bank)
        try context.save()

        let client = FakeAIClient()
        let (session, state) = await runGrabTurn(
            in: context, client: client)

        #expect(session.error == nil)
        #expect(state.version == AIAgentConversationState.currentVersion)
        #expect(state.messages == session.messages)
        // user question + assistant search call + tool result + answer.
        #expect(state.transcript.count == 4)
        #expect(state.transcript[0].role == .user)
        #expect(state.transcript[0].text == "grab chi bao nhiêu?")
        #expect(state.transcript[2].isToolResult)
        #expect(Set(state.handleByTransactionID.values) == ["R1", "R2"])
        #expect(state.nextHandleNumber == 3)
        // The A…/C… catalog was minted during the write-grant turn.
        #expect(state.accountHandles.count == 2)
        #expect(state.categoryHandles.count == 2)
        #expect(state.nextAccountHandle == 3)
        #expect(state.nextCategoryHandle == 3)

        let data = try JSONEncoder().encode(state)
        let decoded = try JSONDecoder().decode(
            AIAgentConversationState.self, from: data)
        #expect(decoded == state)
    }

    /// A restored session shows the same visible conversation, and the
    /// next request carries the earlier turns plus the one transcript
    /// note telling the model that old `R…` handles need a fresh
    /// search — the note never lands in the visible messages.
    @Test func restoreContinuesConversationWithNote() async throws {
        let context = try makeContext()
        let (cash, _, _, _) = try seedBasics(in: context)
        seed(in: context, amount: 95_000, date: day(2026, 11, 12),
             note: "grab bike", account: cash)
        try context.save()

        let client = FakeAIClient()
        let (session, state) = await runGrabTurn(
            in: context, client: client)

        let restoredClient = FakeAIClient()
        restoredClient.response =
            #"{"type":"answer","text":"Vẫn 95 k."}"#
        let restored = makeSession(
            client: restoredClient, context: context, restoring: state)

        // Visible conversation identical — the note is transcript-only.
        #expect(restored.messages == session.messages)
        #expect(restored.pendingProposal == nil)
        #expect(restored.error == nil)
        #expect(!restored.canRetry)

        restored.send("còn khoản nào khác?")
        #expect(await waitUntil { !restored.isWorking })

        // Transcript: question, search call, result, answer, the
        // restore note, the new question — six entries, one request.
        let request = try #require(restoredClient.requests.last)
        #expect(request.messages.count == 6)
        #expect(request.messages[0].text == "grab chi bao nhiêu?")
        #expect(request.messages[1].role == .assistant)
        #expect(request.messages[4].text
            == AIAgentChatSession.restoredTranscriptNote)
        #expect(request.messages[4].text.contains("\"search\""))
        #expect(request.messages[5].text == "còn khoản nào khác?")
        #expect(restored.messages.last?.text == "Vẫn 95 k.")
    }

    /// A pre-restore `R…` handle resolves to NO live match — a fresh
    /// `search` returning the same transaction re-mints the match
    /// under the SAME handle.
    @Test func restoredHandleReMintsUnderSameHandle() async throws {
        let context = try makeContext()
        let (cash, _, _, _) = try seedBasics(in: context)
        let row = seed(in: context, amount: 95_000,
                       date: day(2026, 11, 12), note: "grab bike",
                       account: cash)
        try context.save()

        let client = FakeAIClient()
        let (session, state) = await runGrabTurn(
            in: context, client: client)
        #expect(session.match(forHandle: "R1")?.original.id == row.id)

        let restoredClient = FakeAIClient()
        restoredClient.queueReply(#"{"type":"search","args":{}}"#)
        restoredClient.queueReply(
            #"{"type":"answer","text":"Tìm lại rồi."}"#)
        let restored = makeSession(
            client: restoredClient, context: context, restoring: state)

        // No live match until a new search returns the transaction.
        #expect(restored.match(forHandle: "R1") == nil)

        restored.send("tìm lại grab")
        #expect(await waitUntil { !restored.isWorking })

        let lastRequest = try #require(restoredClient.requests.last)
        let tool = try #require(toolResult(in: lastRequest))
        #expect(tool.text.contains("\"id\":\"R1\""))
        #expect(restored.match(forHandle: "R1")?.original.id == row.id)
    }

    /// Until that fresh search, a restored handle is not actionable:
    /// an `actions` reply naming it earns the `unknownHandle`
    /// correction instead of parking a proposal.
    @Test func staleHandleIsNotActionableAfterRestore() async throws {
        let context = try makeContext()
        let (cash, _, _, _) = try seedBasics(in: context)
        seed(in: context, amount: 95_000, date: day(2026, 11, 12),
             note: "grab bike", account: cash)
        try context.save()

        let client = FakeAIClient()
        let (_, state) = await runGrabTurn(in: context, client: client)

        let restoredClient = FakeAIClient()
        restoredClient.queueReply(actionsReply(
            "Phân loại lại",
            #"{"action":"setCategory","row":"R1","category":"C1"}"#))
        restoredClient.queueReply(
            #"{"type":"answer","text":"Cần tra cứu lại."}"#)
        let restored = makeSession(
            client: restoredClient, context: context, restoring: state)

        restored.send("phân loại grab đó")
        #expect(await waitUntil { !restored.isWorking })

        #expect(restoredClient.requests.count == 2)
        #expect(restoredClient.requests[1].messages.last?.text
            .hasPrefix(AIAgentChatProtocol.correctionPrefix) == true)
        #expect(restored.pendingProposal == nil)
        #expect(restored.error == nil)
        #expect(restored.messages.last?.text == "Cần tra cứu lại.")
    }

    /// The pending proposal is never part of a snapshot: parked state
    /// is dropped and the restored session has nothing to confirm —
    /// the proposal's visible assistant text stays as plain history.
    @Test func pendingProposalNeverInSnapshot() async throws {
        let context = try makeContext()
        let (cash, _, _, _) = try seedBasics(in: context)
        seed(in: context, amount: 95_000, date: day(2026, 11, 12),
             note: "grab bike", account: cash)
        try context.save()

        let client = FakeAIClient()
        client.queueReply(#"{"type":"search","args":{"text":"grab"}}"#)
        client.queueReply(actionsReply(
            "Gắn danh mục Ăn uống",
            #"{"action":"setCategory","row":"R1","category":"C1"}"#))
        let session = makeSession(client: client, context: context)
        session.send("phân loại grab")
        #expect(await waitUntil {
            !session.isWorking && session.pendingProposal != nil })
        let proposalText = try #require(session.pendingProposal).text

        let state = session.snapshot()
        let restored = makeSession(
            client: FakeAIClient(), context: context, restoring: state)

        #expect(restored.pendingProposal == nil)
        // The proposal's explanation remains visible — as history.
        #expect(restored.messages.contains {
            $0.kind == .assistant && $0.text == proposalText })
        // Confirming on the restored session writes nothing.
        restored.confirmProposal()
        #expect(restored.messages.last?.text == proposalText)
        #expect(restored.error == nil)
    }

    // MARK: - onStateChange

    /// The hook fires once per turn end (answer here), then once more
    /// for each explicit proposal decision — confirm and discard.
    @Test func hookFiresAtTurnEndConfirmAndDiscard() async throws {
        let context = try makeContext()
        let (cash, _, _, _) = try seedBasics(in: context)
        seed(in: context, amount: 95_000, date: day(2026, 11, 12),
             note: "grab bike", account: cash)
        try context.save()

        let client = FakeAIClient()
        client.queueReply(#"{"type":"answer","text":"a1"}"#)
        let session = makeSession(client: client, context: context)
        let counter = HookCounter()
        session.onStateChange = { counter.value += 1 }

        session.send("q1")
        #expect(await waitUntil { !session.isWorking })
        #expect(counter.value == 1)

        // A parked proposal ends its turn — one more firing.
        client.queueReply(#"{"type":"search","args":{"text":"grab"}}"#)
        client.queueReply(actionsReply(
            "Gắn danh mục Ăn uống",
            #"{"action":"setCategory","row":"R1","category":"C1"}"#))
        session.send("q2")
        #expect(await waitUntil {
            !session.isWorking && session.pendingProposal != nil })
        #expect(counter.value == 2)

        session.confirmProposal()
        #expect(counter.value == 3)
        #expect(session.error == nil)

        // Discard fires too — the declined record changed the state.
        // (`delete` — a second setCategory on the row would no-op.)
        client.queueReply(#"{"type":"search","args":{"text":"grab"}}"#)
        client.queueReply(actionsReply(
            "Xoá khoản grab",
            #"{"action":"delete","row":"R1"}"#))
        session.send("q3")
        #expect(await waitUntil {
            !session.isWorking && session.pendingProposal != nil })
        #expect(counter.value == 4)
        session.discardProposal()
        #expect(counter.value == 5)
    }

    /// Error and `stop()` turn ends fire the hook the same way.
    @Test func hookFiresOnErrorAndStop() async throws {
        let context = try makeContext()
        _ = try seedBasics(in: context)

        // Two malformed replies in a row exhaust the correction — the
        // turn ends in an error, the hook fires once.
        let failClient = FakeAIClient()
        failClient.response =
            #"{"type":"search","args":{"from":"15/11/2026"}}"#
        let failing = makeSession(client: failClient, context: context)
        let failCounter = HookCounter()
        failing.onStateChange = { failCounter.value += 1 }
        failing.send("hỏi")
        #expect(await waitUntil { !failing.isWorking })
        #expect(failing.error != nil)
        #expect(failCounter.value == 1)

        // A hanging request cancelled by stop() still ends the turn.
        let hangClient = FakeAIClient()
        hangClient.hangOnComplete = true
        let hanging = makeSession(client: hangClient, context: context)
        let hangCounter = HookCounter()
        hanging.onStateChange = { hangCounter.value += 1 }
        hanging.send("hỏi")
        #expect(await waitUntil { hangClient.requests.count == 1 })
        hanging.stop()
        #expect(await waitUntil { !hanging.isWorking })
        #expect(hangCounter.value == 1)
    }

    // MARK: - Store: save / load / list / delete

    /// A saved record loads back exactly, lists as its summary, and
    /// deletes cleanly.
    @Test func saveLoadListAndDelete() throws {
        let directory = try makeTempDirectory("roundtrip")
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = AIAgentConversationStore(directory: directory)

        let state = makeState(messageCount: 3)
        let record = try #require(
            AIAgentConversationStore.makeRecord(
                for: state, createdAt: day(2026, 11, 1),
                updatedAt: day(2026, 11, 2)))
        store.save(record)

        let loaded = try #require(store.load(id: record.id))
        #expect(loaded == record)
        #expect(loaded.messageCount == 3)
        #expect(store.list() == [record.summary])

        store.delete(id: record.id)
        #expect(store.load(id: record.id) == nil)
        #expect(store.list().isEmpty)
    }

    /// `list` orders by `updatedAt` descending regardless of save
    /// order — a re-saved conversation jumps to the front.
    @Test func listOrdersNewestUpdatedAtFirst() throws {
        let directory = try makeTempDirectory("ordering")
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = AIAgentConversationStore(directory: directory)
        let state = makeState()

        let oldest = AIAgentConversationRecord(
            title: "oldest", createdAt: day(2026, 10, 1),
            updatedAt: day(2026, 10, 1), state: state)
        let middle = AIAgentConversationRecord(
            title: "middle", createdAt: day(2026, 10, 2),
            updatedAt: day(2026, 10, 2), state: state)
        let newest = AIAgentConversationRecord(
            title: "newest", createdAt: day(2026, 10, 3),
            updatedAt: day(2026, 10, 3), state: state)
        for record in [oldest, newest, middle] { store.save(record) }

        #expect(store.list().map(\.id)
            == [newest.id, middle.id, oldest.id])

        // Bumping `updatedAt` and re-saving reorders the list.
        var bumped = oldest
        bumped.updatedAt = day(2026, 11, 1)
        store.save(bumped)
        #expect(store.list().map(\.id)
            == [oldest.id, newest.id, middle.id])
    }

    /// `deleteAll` removes every conversation file — including corrupt
    /// ones matching the naming scheme — but never foreign files in
    /// the directory.
    @Test func deleteAllKeepsForeignFiles() throws {
        let directory = try makeTempDirectory("deleteall")
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = AIAgentConversationStore(directory: directory)

        let record = try #require(
            AIAgentConversationStore.makeRecord(for: makeState()))
        store.save(record)
        // A corrupt-but-ours file and two foreign neighbours.
        let corrupt = directory
            .appendingPathComponent(UUID().uuidString)
            .appendingPathExtension("json")
        try Data("garbage".utf8).write(to: corrupt)
        let foreignJSON = directory
            .appendingPathComponent("notes.json")
        let foreignText = directory
            .appendingPathComponent("keep-me.txt")
        try Data("{}".utf8).write(to: foreignJSON)
        try Data("not ours".utf8).write(to: foreignText)

        store.deleteAll()

        #expect(store.list().isEmpty)
        #expect(!FileManager.default.fileExists(atPath: corrupt.path))
        #expect(FileManager.default.fileExists(atPath: foreignJSON.path))
        #expect(FileManager.default.fileExists(atPath: foreignText.path))
    }

    /// Only the 50 most recently updated conversations survive —
    /// pruned on save, oldest `updatedAt` first.
    @Test func pruningKeepsNewestFifty() throws {
        let directory = try makeTempDirectory("prune")
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = AIAgentConversationStore(directory: directory)

        var ids: [UUID] = []
        for index in 0..<55 {
            let record = AIAgentConversationRecord(
                title: "c\(index)", createdAt: day(2026, 10, 1),
                updatedAt: day(2026, 10, 1)
                    .addingTimeInterval(TimeInterval(index)),
                state: makeState())
            ids.append(record.id)
            store.save(record)
        }

        #expect(store.list().count
            == AIAgentConversationStore.maxConversations)
        // The first five saved are the five pruned.
        for index in 0..<5 {
            #expect(store.load(id: ids[index]) == nil)
        }
        #expect(store.load(id: ids[5]) != nil)
        // And the list still runs newest first.
        #expect(store.list().first?.id == ids[54])
    }

    /// A record's stored state is bounded to the last 400 visible
    /// messages — the newest survive.
    @Test func saveBoundsVisibleMessages() throws {
        let directory = try makeTempDirectory("boundmessages")
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = AIAgentConversationStore(directory: directory)

        var state = AIAgentConversationState()
        for index in 0..<410 {
            state.messages.append(AIAgentChatMessage(
                kind: .user, text: "q\(index)"))
        }
        let record = AIAgentConversationRecord(title: "t", state: state)
        store.save(record)

        let loaded = try #require(store.load(id: record.id))
        #expect(loaded.state.messages.count
            == AIAgentConversationStore.maxPersistedMessages)
        #expect(loaded.state.messages.first?.text == "q10")
        #expect(loaded.state.messages.last?.text == "q409")
        #expect(loaded.messageCount
            == AIAgentConversationStore.maxPersistedMessages)
    }

    /// The transcript keeps only the newest entries fitting the char
    /// cap — oldest drop first; an oversized newest entry always
    /// survives.
    @Test func saveBoundsTranscriptCharacters() throws {
        let directory = try makeTempDirectory("boundtranscript")
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = AIAgentConversationStore(directory: directory)

        // 60 × 5.000 = 300.000 chars → the newest 40 fit the cap.
        var state = makeState()
        for index in 0..<60 {
            state.transcript.append(AIAgentTranscriptEntry(
                role: .user,
                text: "e\(index)-" + String(repeating: "x", count: 4_990)))
        }
        let record = AIAgentConversationRecord(title: "t", state: state)
        store.save(record)

        let loaded = try #require(store.load(id: record.id))
        #expect(loaded.state.transcript.count == 40)
        #expect(loaded.state.transcript.first?.text.hasPrefix("e20-")
            == true)
        #expect(loaded.state.transcript.last?.text.hasPrefix("e59-")
            == true)
        let total = loaded.state.transcript
            .reduce(0) { $0 + $1.text.count }
        #expect(total
            <= AIAgentConversationStore.maxPersistedTranscriptCharacters)

        // One entry bigger than the cap alone still persists.
        var huge = makeState()
        huge.transcript.append(AIAgentTranscriptEntry(
            role: .user,
            text: String(
                repeating: "y",
                count: AIAgentConversationStore
                    .maxPersistedTranscriptCharacters + 5_000)))
        let hugeRecord = AIAgentConversationRecord(
            title: "huge", state: huge)
        store.save(hugeRecord)
        let loadedHuge = try #require(store.load(id: hugeRecord.id))
        #expect(loadedHuge.state.transcript.count == 1)
    }

    /// A corrupt file and an unknown-version file are skipped by both
    /// `list` and `load` — no crash, and sibling records still read.
    @Test func corruptAndUnknownVersionFilesAreSkipped() throws {
        let directory = try makeTempDirectory("corrupt")
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = AIAgentConversationStore(directory: directory)

        let good = try #require(
            AIAgentConversationStore.makeRecord(for: makeState()))
        store.save(good)

        let corruptID = UUID()
        try Data("not json at all".utf8).write(
            to: directory.appendingPathComponent(corruptID.uuidString)
                .appendingPathExtension("json"))

        let unknownID = UUID()
        let payload: [String: Any] = [
            "id": unknownID.uuidString, "title": "future",
            "createdAt": 0.0, "updatedAt": 0.0,
            "state": ["version": 99, "messages": []],
        ]
        try JSONSerialization.data(withJSONObject: payload).write(
            to: directory.appendingPathComponent(unknownID.uuidString)
                .appendingPathExtension("json"))

        #expect(store.list() == [good.summary])
        #expect(store.load(id: corruptID) == nil)
        #expect(store.load(id: unknownID) == nil)
        #expect(store.load(id: good.id) == good)

        // The state decoder itself refuses a version mismatch.
        let badState = try JSONSerialization.data(
            withJSONObject: ["version": 99, "messages": []])
        #expect(throws: (any Error).self) {
            try JSONDecoder().decode(
                AIAgentConversationState.self, from: badState)
        }
    }

    /// Title: first user message collapsed to one line, at most 60
    /// characters with an ellipsis; the fallback covers conversations
    /// with no usable user message — which are also not worth saving.
    @Test func titleDerivationAndWorthSaving() {
        var state = AIAgentConversationState()
        state.messages.append(AIAgentChatMessage(
            kind: .assistant, text: "chào bạn"))
        #expect(!AIAgentConversationStore.isWorthSaving(state))
        #expect(AIAgentConversationStore.title(for: state)
            == AIAgentConversationStore.fallbackTitle)
        #expect(AIAgentConversationStore.makeRecord(for: state) == nil)

        state.messages.append(AIAgentChatMessage(
            kind: .user, text: "  dòng đầu\nvẫn   tiếp  "))
        state.messages.append(AIAgentChatMessage(
            kind: .assistant, text: "trả lời"))
        state.messages.append(AIAgentChatMessage(
            kind: .user, text: "câu thứ hai"))
        #expect(AIAgentConversationStore.isWorthSaving(state))
        #expect(AIAgentConversationStore.title(for: state)
            == "dòng đầu vẫn tiếp")

        var longState = AIAgentConversationState()
        longState.messages.append(AIAgentChatMessage(
            kind: .user, text: String(repeating: "đ", count: 100)))
        let title = AIAgentConversationStore.title(for: longState)
        #expect(title.count == AIAgentConversationStore.maxTitleLength)
        #expect(title.hasSuffix("…"))

        let record = AIAgentConversationStore.makeRecord(for: state)
        #expect(record?.title == "dòng đầu vẫn tiếp")
        #expect(record?.messageCount == 4)
    }

    /// The encoded state carries `version` — the field the decoder
    /// gates on.
    @Test func jsonCarriesVersionField() throws {
        let data = try JSONEncoder().encode(makeState())
        let object = try #require(
            try JSONSerialization.jsonObject(with: data)
                as? [String: Any])
        #expect(object["version"] as? Int
            == AIAgentConversationState.currentVersion)
    }

    /// The default directory lands under Application Support —
    /// `AgentConversations/` — while tests inject their own.
    @Test func defaultDirectoryIsAgentConversations() {
        let store = AIAgentConversationStore()
        #expect(store.directory.lastPathComponent == "AgentConversations")
        #expect(store.directory.path.contains("Application Support"))
    }
}
