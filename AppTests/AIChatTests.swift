import Testing
import Foundation
import SwiftData
import FinanceCore
@testable import AMFinance

/// Tests for the AI summary + inbox-suggestion features: `AIChatScope`
/// interval/label math, the SwiftData → snapshot loader and its privacy
/// projection, and the `AIInboxSuggestModel` batching + apply semantics —
/// all through a fake `AIChatClientProtocol`, no network.
struct AIChatTests {

    // MARK: - Scaffolding

    /// Scriptable client: queued completions (or a handler) for
    /// `complete`, canned deltas + an optional error or a hang for
    /// `stream`. Records every request.
    private final class FakeAIClient: AIChatClientProtocol, @unchecked Sendable {
        private let lock = NSLock()
        private var recorded: [AIRequest] = []
        /// Per-request replies for `complete`; falls back to
        /// `completeResponse` once the queue is drained.
        private var queuedCompletions: [Result<String, Error>] = []
        var completeResponse = #"{"suggestions":[]}"#
        /// Optional full control over `complete` replies (e.g. building
        /// suggestion JSON per batch).
        var completeHandler: ((AIRequest) throws -> String)?
        /// Suspension point for "never answers" runs.
        var hangOnComplete = false
        /// Deltas `stream` yields before finishing / erroring.
        var deltas: [String] = []
        var streamError: Error?
        /// When true, `stream` yields its deltas then suspends forever —
        /// for the stop test.
        var hangsAfterDeltas = false

        var requests: [AIRequest] {
            lock.lock()
            defer { lock.unlock() }
            return recorded
        }

        func queueCompletion(_ result: Result<String, Error>) {
            lock.lock()
            queuedCompletions.append(result)
            lock.unlock()
        }

        /// Synchronous record+dequeue so the lock is never held across an
        /// `await`.
        private func dequeueReply(for request: AIRequest) -> Result<String, Error>? {
            lock.lock()
            defer { lock.unlock() }
            recorded.append(request)
            return queuedCompletions.isEmpty ? nil : queuedCompletions.removeFirst()
        }

        func complete(_ request: AIRequest) async throws -> AIResponse {
            if hangOnComplete { try await Task.sleep(for: .seconds(3600)) }
            let queued = dequeueReply(for: request)
            if let handler = completeHandler {
                return AIResponse(text: try handler(request))
            }
            switch queued {
            case .failure(let error): throw error
            case .success(let text): return AIResponse(text: text)
            case nil: return AIResponse(text: completeResponse)
            }
        }

        func stream(_ request: AIRequest) -> AsyncThrowingStream<String, Error> {
            lock.lock()
            recorded.append(request)
            let pieces = deltas
            let error = streamError
            let hangs = hangsAfterDeltas
            lock.unlock()
            return AsyncThrowingStream { continuation in
                let task = Task {
                    for piece in pieces { continuation.yield(piece) }
                    if hangs {
                        do {
                            try await Task.sleep(for: .seconds(3600))
                        } catch {
                            continuation.finish(throwing: error)
                            return
                        }
                    }
                    continuation.finish(throwing: error)
                }
                continuation.onTermination = { _ in task.cancel() }
            }
        }
    }

    /// Polls a condition — the session/model tasks update state off the
    /// call stack, so assertions wait for them deterministically.
    @MainActor
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

    /// Fixed "now" — 15/11/2026, Vietnam calendar.
    private var now: Date {
        calendar.date(
            from: DateComponents(year: 2026, month: 11, day: 15, hour: 12))!
    }

    private var calendar: Calendar { AppCalendar.vietnam }

    /// In-memory container + main-actor context, seeded.
    @MainActor
    private func makeContext() throws -> ModelContext {
        let container = try AppModelContainer.make(inMemory: true)
        let context = ModelContext(container)
        try SeedData.seedIfNeeded(context: context)
        return context
    }

    @MainActor
    private func firstCategory(
        named name: String, in context: ModelContext
    ) throws -> LedgerCategory {
        let categories = try context.fetch(FetchDescriptor<LedgerCategory>())
        return try #require(categories.first { $0.name == name })
    }

    /// Suggestion JSON for a run of `rowID` → entries.
    private func suggestionsJSON(
        _ entries: [(id: String, category: String?, business: String?,
                     transfer: Bool, confidence: Double)]
    ) -> String {
        let items: [[String: Any]] = entries.map { entry in
            var item: [String: Any] = [
                "id": entry.id,
                "transfer": entry.transfer,
                "confidence": entry.confidence,
            ]
            item["category"] = entry.category.map { $0 as Any } ?? NSNull()
            item["business"] = entry.business.map { $0 as Any } ?? NSNull()
            return item
        }
        let data = try! JSONSerialization.data(
            withJSONObject: ["suggestions": items])
        return String(data: data, encoding: .utf8)!
    }

    // MARK: - AIChatScope

    @Test func scopeIntervalsCoverExpectedRanges() {
        let thisMonth = AIChatScope(kind: .thisMonth)
            .interval(now: now, calendar: calendar)
        #expect(calendar.component(.day, from: thisMonth.start) == 1)
        #expect(calendar.component(.month, from: thisMonth.start) == 11)
        #expect(calendar.component(.month, from: thisMonth.end) == 12)

        // "3 tháng" = three calendar months ending with this one: Sep–Nov.
        let three = AIChatScope(kind: .threeMonths)
            .interval(now: now, calendar: calendar)
        #expect(calendar.component(.month, from: three.start) == 9)
        #expect(calendar.component(.month, from: three.end) == 12)

        let year = AIChatScope(kind: .thisYear)
            .interval(now: now, calendar: calendar)
        #expect(calendar.dateComponents([.year], from: year.start).year == 2026)
        #expect(calendar.component(.month, from: year.start) == 1)
        #expect(calendar.component(.year, from: year.end) == 2027)
    }

    @Test func customScopeIsInclusiveAndLabelsRead() {
        var scope = AIChatScope(kind: .custom)
        scope.customStart = calendar.date(
            from: DateComponents(year: 2026, month: 11, day: 10))!
        scope.customEnd = calendar.date(
            from: DateComponents(year: 2026, month: 11, day: 20))!
        let interval = scope.interval(now: now, calendar: calendar)
        #expect(calendar.component(.day, from: interval.start) == 10)
        // End is exclusive → the 21st at 00:00.
        #expect(calendar.component(.day, from: interval.end) == 21)
        #expect(scope.periodLabel(now: now, calendar: calendar) == "10/11 – 20/11/2026")
        #expect(
            AIChatScope(kind: .thisMonth)
                .periodLabel(now: now, calendar: calendar) == "Tháng 11/2026")
        #expect(
            AIChatScope(kind: .thisYear)
                .periodLabel(now: now, calendar: calendar) == "Năm 2026")
    }

    // MARK: - AIChatContextLoader

    @Test @MainActor func loaderBuildsSnapshotForScope() throws {
        let context = try makeContext()
        let cash = try #require(
            try context.fetch(FetchDescriptor<Account>()).first)
        let food = try firstCategory(named: "Ăn uống", in: context)
        let salary = try firstCategory(named: "Lương & thù lao", in: context)

        let nov5 = calendar.date(
            from: DateComponents(year: 2026, month: 11, day: 5))!
        let oct20 = calendar.date(
            from: DateComponents(year: 2026, month: 10, day: 20))!
        context.insert(LedgerTransaction(
            kind: .expense, amount: 100_000, date: nov5,
            note: "Ăn trưa", account: cash, category: food))
        context.insert(LedgerTransaction(
            kind: .income, amount: 5_000_000, date: nov5,
            account: cash, category: salary))
        // Out of this month's range — must not appear.
        context.insert(LedgerTransaction(
            kind: .expense, amount: 999_000, date: oct20,
            account: cash, category: food))
        try context.save()

        let snapshot = try AIChatContextLoader.makeSnapshot(
            in: context,
            scope: AIChatScope(kind: .thisMonth),
            now: now, calendar: calendar)

        #expect(snapshot.income == 5_000_000)
        #expect(snapshot.expense == 100_000)
        #expect(snapshot.periodLabel == "Tháng 11/2026")
        #expect(snapshot.transactions.count == 2)
        // Newest-first ordering is not guaranteed between same-day rows;
        // what matters is the October row is excluded and signs are right.
        let expenseLine = try #require(
            snapshot.transactions.first { $0.signedAmount < 0 })
        #expect(expenseLine.signedAmount == -100_000)
        #expect(expenseLine.categoryName == "Ăn uống")
        #expect(expenseLine.note == "Ăn trưa")
        let incomeLine = try #require(
            snapshot.transactions.first { $0.signedAmount > 0 })
        #expect(incomeLine.signedAmount == 5_000_000)
        #expect(snapshot.accounts.contains { $0.name == "Tiền mặt" })
        #expect(snapshot.categories.contains {
            $0.name == "Ăn uống" && $0.amount == 100_000 && $0.kind == .expense })
    }

    @Test @MainActor func privacySwitchesChangeOutgoingText() throws {
        let context = try makeContext()
        let cash = try #require(
            try context.fetch(FetchDescriptor<Account>()).first)
        context.insert(LedgerTransaction(
            kind: .expense, amount: 100_000, date: now,
            note: "GHI CHÚ RIÊNG TƯ", account: cash))
        try context.save()
        let snapshot = try AIChatContextLoader.makeSnapshot(
            in: context,
            scope: AIChatScope(kind: .thisMonth),
            now: now, calendar: calendar)

        let open = AIFinanceContextBuilder.outgoingText(
            snapshot: snapshot,
            options: AIFinancePrivacyOptions(
                includeTransactions: true, includeNotes: true))
        let noNotes = AIFinanceContextBuilder.outgoingText(
            snapshot: snapshot,
            options: AIFinancePrivacyOptions(
                includeTransactions: true, includeNotes: false))
        let minimal = AIFinanceContextBuilder.outgoingText(
            snapshot: snapshot,
            options: AIFinancePrivacyOptions(
                includeTransactions: false, includeNotes: false))

        #expect(open != noNotes)
        #expect(open.contains("GHI CHÚ RIÊNG TƯ"))
        #expect(!noNotes.contains("GHI CHÚ RIÊNG TƯ"))
        #expect(!minimal.contains("GHI CHÚ RIÊNG TƯ"))
        // The transaction list section itself only exists when enabled.
        #expect(open.contains("Giao dịch trong kỳ"))
        #expect(!minimal.contains("Giao dịch trong kỳ"))
        // The summary header stays — privacy only narrows it.
        #expect(minimal.contains("Bối cảnh tài chính"))
    }

    // MARK: - AIInboxSuggestModel

    @MainActor
    private func pendingInputs(_ count: Int) -> [AIInboxPendingInput] {
        (0..<count).map { index in
            AIInboxPendingInput(
                transactionID: UUID(),
                kind: .expense,
                signedAmount: -50_000 - Int64(index) * 1_000,
                note: "SAO KE \(index)",
                date: now.addingTimeInterval(Double(-index) * 3600),
                accountName: "VPBank")
        }
    }

    @Test @MainActor func batchingSplitsAtForty() {
        let rows = AIInboxSuggestModel.batches(
            of: AIInboxSuggestModel.batchSize,
            rows: Array(0..<85))
        #expect(rows.map(\.count) == [40, 40, 5])
        #expect(AIInboxSuggestModel.batches(of: 40, rows: [Int]()).isEmpty)
        #expect(AIInboxSuggestModel.batches(of: 40, rows: [1, 2]).count == 1)
    }

    @Test @MainActor func runBatchesPendingRowsInForties() async {
        let inputs = pendingInputs(85)
        let client = FakeAIClient()
        var batchSizes: [Int] = []
        client.completeHandler = { request in
            let data = request.messages[0].text.data(using: .utf8)!
            let rows = try! JSONSerialization.jsonObject(with: data)
                as! [[String: Any]]
            batchSizes.append(rows.count)
            return #"{"suggestions":[]}"#
        }
        let model = AIInboxSuggestModel(client: client)
        model.run(
            pending: inputs,
            vocabulary: AIInboxVocabulary(
                expenseCategories: [(UUID(), "Ăn uống")]))
        #expect(await waitUntil { model.phase == .finished })
        #expect(batchSizes == [40, 40, 5])
        #expect(client.requests.count == 3)
        // Unsuggested rows end up .noSuggestion.
        #expect(model.rows.allSatisfy { $0.status == .noSuggestion })
    }

    @Test @MainActor func acceptAppliesCategoryAndClearsReview() async throws {
        let context = try makeContext()
        let cash = try #require(
            try context.fetch(FetchDescriptor<Account>()).first)
        let food = try firstCategory(named: "Ăn uống", in: context)
        let transaction = LedgerTransaction(
            kind: .expense, amount: 155_000, date: now,
            note: "GRAB BIKE", account: cash, needsReview: true)
        context.insert(transaction)
        try context.save()

        let client = FakeAIClient()
        client.completeResponse = suggestionsJSON([
            (transaction.id.uuidString, "Ăn uống", nil, false, 0.9),
        ])
        let model = AIInboxSuggestModel(client: client)
        model.run(
            pending: [
                AIInboxPendingInput(
                    transactionID: transaction.id, kind: .expense,
                    signedAmount: -155_000, note: "GRAB BIKE",
                    date: now, accountName: "VPBank")
            ],
            vocabulary: AIInboxVocabulary(
                expenseCategories: [(food.id, food.name)]))
        #expect(await waitUntil { model.phase == .finished })
        #expect(model.rows.first?.targetName == "Ăn uống")

        #expect(model.accept(
            transaction.id, in: context,
            transactions: [transaction.id: transaction],
            categories: [food.id: food], businesses: [:]))
        #expect(transaction.category?.id == food.id)
        #expect(!transaction.needsReview)
        #expect(model.rows.first?.status == .accepted)
        #expect(model.appliedCount == 1)
    }

    @Test @MainActor func unknownCategoryIsIgnored() async throws {
        let context = try makeContext()
        let cash = try #require(
            try context.fetch(FetchDescriptor<Account>()).first)
        let transaction = LedgerTransaction(
            kind: .expense, amount: 80_000, date: now,
            note: "ABC", account: cash, needsReview: true)
        context.insert(transaction)
        try context.save()

        let client = FakeAIClient()
        client.completeResponse = suggestionsJSON([
            (transaction.id.uuidString, "Danh mục bịa", nil, false, 0.95),
        ])
        let model = AIInboxSuggestModel(client: client)
        model.run(
            pending: [
                AIInboxPendingInput(
                    transactionID: transaction.id, kind: .expense,
                    signedAmount: -80_000, note: "ABC", date: now)
            ],
            vocabulary: AIInboxVocabulary(
                expenseCategories: [(UUID(), "Ăn uống")]))
        #expect(await waitUntil { model.phase == .finished })
        #expect(model.rows.first?.suggestion == nil)
        #expect(model.rows.first?.status == .noSuggestion)
        #expect(transaction.needsReview)
        #expect(transaction.category == nil)
    }

    @Test @MainActor func acceptAllHighConfidenceAppliesOnlyAtThreshold() async throws {
        let context = try makeContext()
        let cash = try #require(
            try context.fetch(FetchDescriptor<Account>()).first)
        let food = try firstCategory(named: "Ăn uống", in: context)

        var transactions: [UUID: LedgerTransaction] = [:]
        var inputs: [AIInboxPendingInput] = []
        for index in 0..<3 {
            let transaction = LedgerTransaction(
                kind: .expense, amount: 100_000, date: now,
                note: "ROW \(index)", account: cash, needsReview: true)
            context.insert(transaction)
            transactions[transaction.id] = transaction
            inputs.append(AIInboxPendingInput(
                transactionID: transaction.id, kind: .expense,
                signedAmount: -100_000, note: "ROW \(index)", date: now))
        }
        try context.save()

        let client = FakeAIClient()
        // 0.9 and 0.8 pass the 0.8 floor; 0.5 stays for the user.
        client.completeResponse = suggestionsJSON([
            (inputs[0].transactionID.uuidString, "Ăn uống", nil, false, 0.9),
            (inputs[1].transactionID.uuidString, "Ăn uống", nil, false, 0.5),
            (inputs[2].transactionID.uuidString, "Ăn uống", nil, false, 0.8),
        ])
        let model = AIInboxSuggestModel(client: client)
        model.run(
            pending: inputs,
            vocabulary: AIInboxVocabulary(
                expenseCategories: [(food.id, food.name)]))
        #expect(await waitUntil { model.phase == .finished })
        #expect(model.highConfidenceCount == 2)

        let applied = model.acceptAllHighConfidence(
            in: context,
            transactions: transactions,
            categories: [food.id: food],
            businesses: [:])
        #expect(applied == 2)
        #expect(transactions[inputs[0].transactionID]?.needsReview == false)
        #expect(transactions[inputs[0].transactionID]?.category?.id == food.id)
        #expect(transactions[inputs[2].transactionID]?.needsReview == false)
        // Below the threshold — untouched.
        #expect(transactions[inputs[1].transactionID]?.needsReview == true)
        #expect(transactions[inputs[1].transactionID]?.category == nil)
        #expect(model.rows[1].status == .pending)
    }

    @Test @MainActor func internalTransferSuggestionMarksOnly() async throws {
        let context = try makeContext()
        let cash = try #require(
            try context.fetch(FetchDescriptor<Account>()).first)
        let savings = Account(name: "Tiết kiệm", kind: .bank)
        context.insert(savings)
        let transaction = LedgerTransaction(
            kind: .expense, amount: 2_000_000, date: now,
            note: "CK TIET KIEM", account: cash, needsReview: true)
        context.insert(transaction)
        try context.save()

        let client = FakeAIClient()
        client.completeResponse = suggestionsJSON([
            (transaction.id.uuidString, nil, nil, true, 0.93),
        ])
        let model = AIInboxSuggestModel(client: client)
        model.run(
            pending: [
                AIInboxPendingInput(
                    transactionID: transaction.id, kind: .expense,
                    signedAmount: -2_000_000, note: "CK TIET KIEM", date: now)
            ],
            vocabulary: AIInboxVocabulary(
                expenseCategories: [(UUID(), "Ăn uống")]))
        #expect(await waitUntil { model.phase == .finished })
        #expect(model.rows.first?.targetName == "Chuyển khoản nội bộ")

        // "Accepting" a transfer suggestion only flags the row — the
        // transaction itself is not converted and keeps needsReview.
        #expect(model.accept(
            transaction.id, in: context,
            transactions: [transaction.id: transaction],
            categories: [:], businesses: [:]))
        #expect(model.rows.first?.status == .transferMarked)
        #expect(transaction.kind == .expense)
        #expect(transaction.toAccount == nil)
        #expect(transaction.needsReview)

        // The existing conversion flow does the real work afterwards.
        #expect(WalletSyncTransfer.convert(transaction, with: savings))
        try context.save()
        model.markConverted(transaction.id)
        #expect(transaction.kind == .transfer)
        #expect(!transaction.needsReview)
        #expect(model.rows.first?.status == .accepted)
    }

    @Test @MainActor func cancelDuringRunChangesNothing() async throws {
        let context = try makeContext()
        let cash = try #require(
            try context.fetch(FetchDescriptor<Account>()).first)
        let transaction = LedgerTransaction(
            kind: .expense, amount: 60_000, date: now,
            note: "CHUA PHAN LOAI", account: cash, needsReview: true)
        context.insert(transaction)
        try context.save()

        // The provider never answers — cancel must leave everything as is.
        let client = FakeAIClient()
        client.hangOnComplete = true
        let model = AIInboxSuggestModel(client: client)
        model.run(
            pending: [
                AIInboxPendingInput(
                    transactionID: transaction.id, kind: .expense,
                    signedAmount: -60_000, note: "CHUA PHAN LOAI", date: now)
            ],
            vocabulary: AIInboxVocabulary(
                expenseCategories: [(UUID(), "Ăn uống")]))
        if case .running = model.phase {} else {
            Issue.record("run should be in progress")
        }
        model.cancel()
        #expect(await waitUntil { model.phase == .idle })
        #expect(transaction.needsReview)
        #expect(transaction.category == nil)
        #expect(model.appliedCount == 0)
        #expect(model.rows.first?.status == .pending)
    }

    @Test @MainActor func changeAppliesUserPickedBusiness() async throws {
        let context = try makeContext()
        let cash = try #require(
            try context.fetch(FetchDescriptor<Account>()).first)
        let web = try #require(
            try context.fetch(FetchDescriptor<Business>())
                .first { $0.name == "Làm web" })
        let transaction = LedgerTransaction(
            kind: .income, amount: 3_000_000, date: now,
            note: "THANH TOAN WEB", account: cash, needsReview: true)
        context.insert(transaction)
        try context.save()

        let client = FakeAIClient()
        client.completeResponse = suggestionsJSON([
            (transaction.id.uuidString, nil, nil, false, 0.0),
        ])
        let model = AIInboxSuggestModel(client: client)
        model.run(
            pending: [
                AIInboxPendingInput(
                    transactionID: transaction.id, kind: .income,
                    signedAmount: 3_000_000, note: "THANH TOAN WEB", date: now)
            ],
            vocabulary: AIInboxVocabulary(
                businesses: [(web.id, web.name)]))
        #expect(await waitUntil { model.phase == .finished })
        // Nothing suggested — the row is .noSuggestion but still changeable.
        #expect(model.rows.first?.status == .noSuggestion)
        #expect(model.change(
            transaction.id, to: .business(web.id), in: context,
            transactions: [transaction.id: transaction],
            categories: [:], businesses: [web.id: web]))
        #expect(transaction.business?.id == web.id)
        #expect(!transaction.needsReview)
        #expect(model.rows.first?.status == .accepted)
    }
}
