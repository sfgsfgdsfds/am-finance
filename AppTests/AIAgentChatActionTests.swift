import Testing
import SwiftData
import Foundation
import FinanceCore
@testable import AMFinance

/// Tests for the chat agent's action-proposal layer: an `actions`
/// reply resolves `R…`/`A…`/`C…` handles to live objects, dry-run
/// validates through `AIAgentLedgerTools.validate`, parks on
/// `pendingProposal` — and only `confirmProposal()` writes. Covers
/// every action kind end to end, the one-correction-then-error path,
/// the read-only refusal, stale-at-confirm drops, discard semantics
/// and handle refresh after apply. Scripted fake client, in-memory
/// store — no network.
@MainActor
struct AIAgentChatActionTests {

    // MARK: - Scaffolding

    private let calendar = AppCalendar.vietnam

    private func makeContext() throws -> ModelContext {
        ModelContext(try AppModelContainer.make(inMemory: true))
    }

    private func day(
        _ year: Int, _ month: Int, _ dayOfMonth: Int,
        _ hour: Int = 12, _ minute: Int = 0
    ) -> Date {
        calendar.date(from: DateComponents(
            year: year, month: month, day: dayOfMonth,
            hour: hour, minute: minute))!
    }

    /// The session's frozen "now" — 15/11/2026 12:00, Vietnam calendar.
    private var now: Date { day(2026, 11, 15, 12) }

    /// Scriptable client — queued replies first, `response` after.
    private final class FakeAIClient: AIChatClientProtocol,
                                    @unchecked Sendable {
        private let lock = NSLock()
        private var recorded: [AIRequest] = []
        private var queued: [String] = []
        var response = #"{"type":"answer","text":"Được rồi."}"#

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

    /// Mutable access behind the provider closure.
    private final class AccessBox {
        var value: AIAgentAccess
        init(_ value: AIAgentAccess) { self.value = value }
    }

    /// An isolated defaults suite — the last-used account key stays
    /// out of the app's real defaults.
    private func makeDefaults(_ name: String) -> UserDefaults {
        let suite = "AIAgentChatActionTests.\(name)"
        let defaults = UserDefaults(suiteName: suite)!
        defaults.removePersistentDomain(forName: suite)
        return defaults
    }

    private func makeSession(
        client: FakeAIClient,
        context: ModelContext,
        access: AccessBox? = nil,
        defaults: UserDefaults? = nil
    ) -> AIAgentChatSession {
        AIAgentChatSession(
            client: client,
            context: context,
            accessProvider: {
                access?.value ?? .scopedReadAndProposeCategoryEdits },
            defaults: defaults ?? makeDefaults("default"),
            now: { self.now },
            calendar: calendar)
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
        needsReview: Bool = false
    ) -> LedgerTransaction {
        let row = LedgerTransaction(
            kind: kind, amount: amount, date: date, note: note,
            account: account, toAccount: toAccount, category: category,
            needsReview: needsReview)
        context.insert(row)
        return row
    }

    /// Accounts and categories whose name sort order pins the minted
    /// handles: "10…" < "20…" so cash is A1, bank A2; "30…" < "40…" so
    /// food is C1, salary C2. The tests assert the pinned mapping on
    /// the system prompt too, so a mint-order change fails loudly.
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

    private func fetchAll<T: PersistentModel>(
        _ type: T.Type, in context: ModelContext
    ) throws -> [T] {
        try context.fetch(FetchDescriptor<T>())
    }

    /// A `"actions"` reply around the given items.
    private func actionsReply(
        _ text: String, _ items: String
    ) -> String {
        #"{"type":"actions","text":""# + text
            + #"","actions":["# + items + "]}"
    }

    // MARK: - Catalog in the prompt

    /// The write grant gets the actions contract and the `A…`/`C…`
    /// catalog with the default account marked — the read-only grant
    /// gets neither and keeps "Phiên này chỉ đọc".
    @Test func catalogAppearsOnlyWhenAccessMayAct() async throws {
        let context = try makeContext()
        let (cash, bank, _, _) = try seedBasics(in: context)
        let defaults = makeDefaults("catalog")
        defaults.set(bank.id.uuidString,
                     forKey: DataResetService.lastUsedAccountDefaultsKey)

        let box = AccessBox(.scopedReadAndProposeCategoryEdits)
        let client = FakeAIClient()
        let session = makeSession(
            client: client, context: context, access: box,
            defaults: defaults)
        session.send("q")
        #expect(await waitUntil { !session.isWorking })
        let system = try #require(client.requests.first?.system)
        #expect(system.contains("\"type\":\"actions\""))
        #expect(system.contains("\"action\":\"setCategory\""))
        #expect(system.contains("\"action\":\"add\""))
        #expect(system.contains("\"action\":\"edit\""))
        #expect(system.contains("\"action\":\"delete\""))
        // The pinned mint order — asserted so handle usage below is
        // not silently wrong.
        #expect(system.contains("A1 \(cash.name)"))
        #expect(system.contains("A2 \(bank.name)"))
        #expect(system.contains("— mặc định"))
        #expect(system.contains("C1 30 Ăn uống"))
        #expect(system.contains("C2 40 Lương"))
        #expect(system.contains("Danh mục CHI"))
        #expect(system.contains("Danh mục THU"))
        #expect(!system.contains("Phiên này chỉ đọc"))

        // The read-only grant advertises none of it.
        let readClient = FakeAIClient()
        let readSession = makeSession(
            client: readClient, context: context,
            access: AccessBox(.scopedRead), defaults: defaults)
        readSession.send("q")
        #expect(await waitUntil { !readSession.isWorking })
        let readSystem = try #require(readClient.requests.first?.system)
        #expect(readSystem.contains("Phiên này chỉ đọc"))
        #expect(!readSystem.contains("\"type\":\"actions\""))
        #expect(!readSystem.contains("A1 "))
        #expect(!readSystem.contains("C1 "))
    }

    // MARK: - Happy paths: preview then confirm

    /// `setCategory` resolves R1 + C1 to live objects, previews the
    /// old → new transition, writes only on confirm and invalidates
    /// the touched handle afterwards.
    @Test func setCategoryPreviewsThenAppliesOnConfirm() async throws {
        let context = try makeContext()
        let (cash, _, food, _) = try seedBasics(in: context)
        let row = seed(in: context, amount: 95_000,
                       date: day(2026, 11, 10), note: "GRAB",
                       account: cash, needsReview: true)
        try context.save()

        let client = FakeAIClient()
        client.queueReply(#"{"type":"search","args":{"text":"grab"}}"#)
        client.queueReply(actionsReply(
            "Gắn danh mục Ăn uống cho khoản GRAB",
            #"{"action":"setCategory","row":"R1","category":"C1"}"#))
        let session = makeSession(client: client, context: context)

        session.send("phân loại grab")
        #expect(await waitUntil {
            !session.isWorking && session.pendingProposal != nil })

        // Preview state — nothing written.
        let proposal = try #require(session.pendingProposal)
        #expect(proposal.text
            == "Gắn danh mục Ăn uống cho khoản GRAB")
        #expect(proposal.items.count == 1)
        let item = try #require(proposal.items.first)
        #expect(item.kind == .setCategory)
        #expect(item.row == "R1")
        #expect(item.changes == [
            .init(field: "Danh mục", old: "Chưa phân loại",
                  new: "30 Ăn uống"),
        ])
        #expect(row.category == nil && row.needsReview)
        #expect(session.messages.last?.text == proposal.text)

        session.confirmProposal()

        #expect(session.pendingProposal == nil)
        #expect(session.error == nil)
        #expect(row.category?.id == food.id)
        #expect(!row.needsReview)
        #expect(session.messages.last?.text == "Đã áp dụng: phân loại 1")
        // The touched handle is stale now — re-search before reuse.
        #expect(session.match(forHandle: "R1") == nil)
    }

    /// `add` expense: every field from the contract lands — amount,
    /// merged date+time, account, category, note — and the balance
    /// moves on confirm.
    @Test func addExpensePreviewsThenApplies() async throws {
        let context = try makeContext()
        let (cash, _, food, _) = try seedBasics(in: context)

        let client = FakeAIClient()
        client.queueReply(actionsReply(
            "Thêm 50 k phở sáng",
            #"{"action":"add","kind":"expense","amount":50000,"#
                + #""date":"2026-11-10","time":"07:30","#
                + #""note":"Phở sáng","account":"A1","category":"C1"}"#))
        let session = makeSession(client: client, context: context)

        session.send("thêm phở 50k")
        #expect(await waitUntil { session.pendingProposal != nil })
        #expect(await waitUntil { !session.isWorking })

        let proposal = try #require(session.pendingProposal)
        let item = try #require(proposal.items.first)
        #expect(item.kind == .add)
        #expect(item.row == nil)
        #expect(item.changes.contains(.init(
            field: "Loại", new: "Chi tiêu")))
        #expect(item.changes.contains(.init(
            field: "Số tiền", new: VND.format(50_000))))
        #expect(item.changes.contains(.init(
            field: "Ngày", new: "10/11 07:30")))
        #expect(item.changes.contains(.init(
            field: "Tài khoản", new: cash.name)))
        #expect(item.changes.contains(.init(
            field: "Danh mục", new: food.name)))
        #expect(item.changes.contains(.init(
            field: "Ghi chú", new: "Phở sáng")))
        #expect(try fetchAll(LedgerTransaction.self, in: context).isEmpty)

        session.confirmProposal()
        #expect(session.error == nil)
        let rows = try fetchAll(LedgerTransaction.self, in: context)
        let added = try #require(rows.first)
        #expect(rows.count == 1)
        #expect(added.amount == 50_000)
        #expect(added.kind == .expense)
        #expect(added.date == day(2026, 11, 10, 7, 30))
        #expect(added.account?.id == cash.id)
        #expect(added.category?.id == food.id)
        #expect(added.note == "Phở sáng")
        #expect(cash.balance == -50_000)
        #expect(session.messages.last?.text == "Đã áp dụng: thêm 1")
    }

    /// `add` income and transfer in one batch — income lands on the
    /// income category, the transfer moves both balances.
    @Test func addIncomeAndTransferApplyTogether() async throws {
        let context = try makeContext()
        let (cash, bank, _, salary) = try seedBasics(in: context)

        let client = FakeAIClient()
        client.queueReply(actionsReply(
            "Thêm lương và rút tiền",
            #"{"action":"add","kind":"income","amount":5000000,"#
                + #""date":"2026-11-12","note":"Lương T11","#
                + #""account":"A2","category":"C2"},"#
                + #"{"action":"add","kind":"transfer","amount":300000,"#
                + #""date":"2026-11-12","note":"Rút tiền","#
                + #""account":"A2","toAccount":"A1"}"#))
        let session = makeSession(client: client, context: context)

        session.send("thêm lương 5tr và rút 300k")
        #expect(await waitUntil { session.pendingProposal != nil })
        let proposal = try #require(session.pendingProposal)
        #expect(proposal.items.map(\.kind) == [.add, .add])
        #expect(proposal.items[1].changes.contains(.init(
            field: "Tài khoản đích", new: cash.name)))

        session.confirmProposal()
        #expect(session.error == nil)
        let rows = try fetchAll(LedgerTransaction.self, in: context)
        #expect(rows.count == 2)
        let income = try #require(rows.first { $0.kind == .income })
        #expect(income.account?.id == bank.id)
        #expect(income.category?.id == salary.id)
        let transfer = try #require(rows.first { $0.kind == .transfer })
        #expect(transfer.account?.id == bank.id)
        #expect(transfer.toAccount?.id == cash.id)
        #expect(cash.balance == 300_000)
        #expect(bank.balance == 4_700_000)
        #expect(session.messages.last?.text == "Đã áp dụng: thêm 2")
    }

    /// `edit` patches only the given fields — note and amount change,
    /// date/account/category keep the live row's values — and the
    /// preview lists just the changed lines.
    @Test func editPatchesOnlyGivenFields() async throws {
        let context = try makeContext()
        let (cash, _, food, _) = try seedBasics(in: context)
        let row = seed(in: context, amount: 60_000,
                       date: day(2026, 11, 11), note: "cũ",
                       account: cash, category: food)
        try context.save()

        let client = FakeAIClient()
        client.queueReply(#"{"type":"search","args":{}}"#)
        client.queueReply(actionsReply(
            "Sửa khoản thành 75 k",
            #"{"action":"edit","row":"R1","amount":75000,"#
                + #""note":"mới"}"#))
        let session = makeSession(client: client, context: context)

        session.send("sửa dòng đó")
        #expect(await waitUntil { session.pendingProposal != nil })
        let item = try #require(session.pendingProposal?.items.first)
        #expect(item.kind == .edit)
        #expect(item.row == "R1")
        // Only the changed fields are previewed.
        #expect(item.changes == [
            .init(field: "Số tiền", old: VND.format(60_000),
                  new: VND.format(75_000)),
            .init(field: "Ghi chú", old: "cũ", new: "mới"),
        ])
        #expect(row.amount == 60_000)

        session.confirmProposal()
        #expect(session.error == nil)
        #expect(row.amount == 75_000)
        #expect(row.note == "mới")
        #expect(row.date == day(2026, 11, 11))
        #expect(row.account?.id == cash.id)
        #expect(row.category?.id == food.id)
        #expect(session.messages.last?.text == "Đã áp dụng: sửa 1")
    }

    /// `delete` previews the row's date/amount/note/account and removes
    /// it on confirm — its handle becomes unknown afterwards.
    @Test func deletePreviewsRowThenRemoves() async throws {
        let context = try makeContext()
        let (cash, _, _, _) = try seedBasics(in: context)
        let row = seed(in: context, amount: 100_000,
                       date: day(2026, 11, 10), note: "xài",
                       account: cash)
        try context.save()

        let client = FakeAIClient()
        client.queueReply(#"{"type":"search","args":{}}"#)
        client.queueReply(actionsReply(
            "Xoá khoản xài", #"{"action":"delete","row":"R1"}"#))
        let session = makeSession(client: client, context: context)

        session.send("xoá khoản xài")
        #expect(await waitUntil { session.pendingProposal != nil })
        let item = try #require(session.pendingProposal?.items.first)
        #expect(item.kind == .delete)
        #expect(item.row == "R1")
        #expect(item.changes.contains(.init(
            field: "Số tiền", old: VND.format(100_000))))
        #expect(item.changes.contains(.init(
            field: "Ghi chú", old: "xài")))
        #expect(item.changes.contains(.init(
            field: "Tài khoản", old: cash.name)))
        // Nothing deleted yet.
        #expect(try fetchAll(LedgerTransaction.self, in: context).count == 1)

        session.confirmProposal()
        #expect(session.error == nil)
        #expect(try fetchAll(LedgerTransaction.self, in: context).isEmpty)
        #expect(cash.balance == 0)
        #expect(session.messages.last?.text == "Đã áp dụng: xoá 1")
        // The deleted row's handle is gone for good — no refresh.
        #expect(session.match(forHandle: "R1") == nil)
    }

    /// All four verbs in one batch land in a single commit with the
    /// per-kind counts in the applied message; every touched handle
    /// goes stale.
    @Test func mixedBatchPreviewsAndAppliesAtomically() async throws {
        let context = try makeContext()
        let (cash, bank, food, _) = try seedBasics(in: context)
        let categorize = seed(in: context, amount: 40_000,
                              date: day(2026, 11, 10), account: cash)
        let edit = seed(in: context, amount: 60_000,
                        date: day(2026, 11, 11), account: cash)
        let delete = seed(in: context, amount: 10_000,
                          date: day(2026, 11, 12), account: cash)
        try context.save()

        let client = FakeAIClient()
        // Newest first → R1 = delete, R2 = edit, R3 = categorize.
        client.queueReply(#"{"type":"search","args":{}}"#)
        client.queueReply(actionsReply(
            "Một đợt đầy đủ",
            #"{"action":"setCategory","row":"R3","category":"C1"},"#
                + #"{"action":"add","kind":"transfer","amount":200000,"#
                + #""account":"A2","toAccount":"A1"},"#
                + #"{"action":"edit","row":"R2","amount":75000},"#
                + #"{"action":"delete","row":"R1"}"#))
        let session = makeSession(client: client, context: context)

        session.send("dọn sổ")
        #expect(await waitUntil { session.pendingProposal != nil })
        let proposal = try #require(session.pendingProposal)
        #expect(proposal.items.map(\.kind)
            == [.setCategory, .add, .edit, .delete])
        #expect(proposal.items.map(\.row) == ["R3", nil, "R2", "R1"])

        session.confirmProposal()
        #expect(session.error == nil)
        #expect(session.messages.last?.text
            == "Đã áp dụng: phân loại 1, thêm 1, sửa 1, xoá 1")
        #expect(categorize.category?.id == food.id)
        #expect(edit.amount == 75_000)
        let rows = try fetchAll(LedgerTransaction.self, in: context)
        #expect(rows.count == 3)
        #expect(!rows.contains { $0.id == delete.id })
        #expect(rows.contains { $0.kind == .transfer })
        // cash: -40k -75k +200k in = +85k (the -10k row was deleted);
        // bank: -200k out.
        #expect(cash.balance == 85_000)
        #expect(bank.balance == -200_000)
        for handle in ["R1", "R2", "R3"] {
            #expect(session.match(forHandle: handle) == nil)
        }
    }

    // MARK: - Add defaults

    /// An `add` without "account"/"date"/"time" resolves to the
    /// last-used account (the quick-add key) and the session's now.
    @Test func addDefaultsToLastUsedAccountAndNow() async throws {
        let context = try makeContext()
        let (cash, bank, _, _) = try seedBasics(in: context)
        let defaults = makeDefaults("lastused")
        defaults.set(bank.id.uuidString,
                     forKey: DataResetService.lastUsedAccountDefaultsKey)

        let client = FakeAIClient()
        client.queueReply(actionsReply(
            "Thêm phở 85k",
            #"{"action":"add","kind":"expense","amount":85000,"#
                + #""note":"Phở"}"#))
        let session = makeSession(
            client: client, context: context, defaults: defaults)

        session.send("ăn phở 85k")
        #expect(await waitUntil { session.pendingProposal != nil })
        let item = try #require(session.pendingProposal?.items.first)
        #expect(item.changes.contains(.init(
            field: "Tài khoản", new: bank.name)))
        #expect(item.changes.contains(.init(
            field: "Ngày", new: "15/11 12:00")))

        session.confirmProposal()
        #expect(session.error == nil)
        let added = try #require(
            fetchAll(LedgerTransaction.self, in: context).first)
        #expect(added.account?.id == bank.id)
        #expect(added.date == now)
        #expect(added.category == nil)
        #expect(bank.balance == -85_000)
        #expect(cash.balance == 0)
    }

    /// Without a remembered account the lowest active `A…` handle is
    /// the fallback — the catalog's first listing.
    @Test func addFallsBackToFirstAccountWithoutLastUsed() async throws {
        let context = try makeContext()
        let (cash, _, _, _) = try seedBasics(in: context)

        let client = FakeAIClient()
        client.queueReply(actionsReply(
            "Thêm cà phê",
            #"{"action":"add","kind":"expense","amount":20000}"#))
        let session = makeSession(client: client, context: context)

        session.send("cf 20k")
        #expect(await waitUntil { session.pendingProposal != nil })
        session.confirmProposal()
        #expect(session.error == nil)
        let added = try #require(
            fetchAll(LedgerTransaction.self, in: context).first)
        #expect(added.account?.id == cash.id)
    }

    // MARK: - Read-only grant

    /// A read-only session answers an `actions` reply with the
    /// settings hint — no retry, no proposal, no write.
    @Test func readOnlyGrantRefusesActionsWithoutCorrection() async throws {
        let context = try makeContext()
        let (cash, _, _, _) = try seedBasics(in: context)
        _ = seed(in: context, date: day(2026, 11, 10), account: cash)
        try context.save()

        let client = FakeAIClient()
        client.response = actionsReply(
            "Thêm", #"{"action":"delete","row":"R1"}"#)
        let session = makeSession(
            client: client, context: context,
            access: AccessBox(.scopedRead))

        session.send("xoá dòng 1")
        #expect(await waitUntil { !session.isWorking })

        #expect(client.requests.count == 1)
        #expect(session.pendingProposal == nil)
        #expect(session.error == nil)
        #expect(session.messages.last?.text
            == AIAgentChatProtocol.readOnlyActionsReply)
        #expect(try fetchAll(LedgerTransaction.self, in: context).count == 1)
    }

    // MARK: - Correction then error

    /// An `R…` handle the session never minted earns exactly one
    /// corrective round carrying the failing index — the second bad
    /// batch surfaces the indexed error.
    @Test func unknownHandleEarnsCorrectionThenError() async throws {
        let context = try makeContext()
        _ = try seedBasics(in: context)

        let client = FakeAIClient()
        client.queueReply(actionsReply(
            "Sửa", #"{"action":"edit","row":"R9","amount":1}"#))
        client.queueReply(actionsReply(
            "Sửa", #"{"action":"delete","row":"R8"}"#))
        let session = makeSession(client: client, context: context)

        session.send("sửa")
        #expect(await waitUntil { !session.isWorking })

        #expect(client.requests.count == 2)
        let correction = client.requests[1].messages.last {
            $0.role == .user
                && $0.text.hasPrefix(AIAgentChatProtocol.correctionPrefix)
        }
        #expect(correction?.text.contains("Mục #1") == true)
        #expect(session.error as? AIAgentApplyError
            == .action(0, .unknownHandle))
        #expect(session.pendingProposal == nil)
        #expect(try fetchAll(LedgerTransaction.self, in: context).isEmpty)
    }

    /// An unknown `C…` catalog handle fails the same way — index and
    /// reason ride the correction.
    @Test func unknownCategoryHandleEarnsCorrectionThenError() async throws {
        let context = try makeContext()
        let (cash, _, _, _) = try seedBasics(in: context)
        _ = seed(in: context, date: day(2026, 11, 10), account: cash)
        try context.save()

        let client = FakeAIClient()
        client.queueReply(#"{"type":"search","args":{}}"#)
        client.queueReply(actionsReply(
            "Gắn", #"{"action":"setCategory","row":"R1","category":"C9"}"#))
        client.queueReply(actionsReply(
            "Gắn", #"{"action":"setCategory","row":"R1","category":"C8"}"#))
        let session = makeSession(client: client, context: context)

        session.send("gắn danh mục")
        #expect(await waitUntil { !session.isWorking })

        #expect(session.error as? AIAgentApplyError
            == .action(0, .unknownHandle))
        #expect(session.pendingProposal == nil)
    }

    /// A refused row — a rental-linked transaction cannot be edited or
    /// deleted — goes through the same correction-then-error path.
    @Test func refusedRowEarnsCorrectionThenError() async throws {
        let context = try makeContext()
        let (_, bank, _, _) = try seedBasics(in: context)
        let rent = seed(in: context, kind: .income, amount: 4_000_000,
                        date: day(2026, 11, 10), account: bank)
        rent.rentalPeriod = day(2026, 11, 1)
        try context.save()

        let client = FakeAIClient()
        client.queueReply(#"{"type":"search","args":{}}"#)
        client.queueReply(actionsReply(
            "Xoá tiền thuê", #"{"action":"delete","row":"R1"}"#))
        client.queueReply(actionsReply(
            "Xoá tiền thuê", #"{"action":"delete","row":"R1"}"#))
        let session = makeSession(client: client, context: context)

        session.send("xoá tiền thuê")
        #expect(await waitUntil { !session.isWorking })

        #expect(client.requests.count == 3)
        #expect(session.error as? AIAgentApplyError
            == .action(0, .transactionNotEligible))
        #expect(session.pendingProposal == nil)
        #expect(try fetchAll(LedgerTransaction.self, in: context).count == 1)
    }

    /// A batch over the action limit fails the dry-run as a batch
    /// error — the correction carries the reason without an index.
    @Test func oversizedBatchEarnsCorrectionThenError() async throws {
        let context = try makeContext()
        _ = try seedBasics(in: context)

        let oversized = (0...AIAgentLedgerTools.actionLimit).map { _ in
            #"{"action":"add","kind":"expense","amount":1}"#
        }.joined(separator: ",")
        let client = FakeAIClient()
        client.queueReply(actionsReply("Nhiều", oversized))
        client.queueReply(actionsReply("Nhiều", oversized))
        let session = makeSession(client: client, context: context)

        session.send("thêm nhiều")
        #expect(await waitUntil { !session.isWorking })

        #expect(session.error as? AIAgentApplyError
            == .batch(.tooManyActions))
        #expect(try fetchAll(LedgerTransaction.self, in: context).isEmpty)
    }

    // MARK: - Confirm-time failures

    /// A row changed between proposal and confirm makes the apply
    /// stale — the error surfaces, the proposal clears and the store
    /// keeps the newer state.
    @Test func staleRowAtConfirmErrorsAndDropsProposal() async throws {
        let context = try makeContext()
        let (cash, _, food, _) = try seedBasics(in: context)
        let row = seed(in: context, amount: 50_000,
                       date: day(2026, 11, 10), account: cash)
        try context.save()

        let client = FakeAIClient()
        client.queueReply(#"{"type":"search","args":{}}"#)
        client.queueReply(actionsReply(
            "Gắn danh mục",
            #"{"action":"setCategory","row":"R1","category":"C1"}"#))
        let session = makeSession(client: client, context: context)

        session.send("gắn")
        #expect(await waitUntil { session.pendingProposal != nil })

        // Someone edited the row meanwhile.
        row.note = "Đã đổi chỗ khác"
        row.updatedAt = .now
        try context.save()

        session.confirmProposal()
        #expect(session.pendingProposal == nil)
        #expect(session.error as? AIAgentApplyError
            == .action(0, .staleTransaction))
        #expect(row.category == nil)
        #expect(row.note == "Đã đổi chỗ khác")

        // The failure was recorded for the model — the next request's
        // transcript carries the applyFailed entry telling it to
        // search again.
        client.response = #"{"type":"answer","text":"ok"}"#
        session.send("tiếp")
        #expect(await waitUntil { !session.isWorking && client.requests.count == 3 })
        #expect(client.requests.last?.messages.contains {
            $0.role == .user
                && $0.text.hasPrefix(AIAgentChatProtocol.applyFailedPrefix)
        } == true)
        _ = food
    }

    // MARK: - Discard

    /// `discardProposal` clears the pending batch untouched and leaves
    /// a declined marker for the model's next request.
    @Test func discardProposalClearsAndRecordsDecline() async throws {
        let context = try makeContext()
        let (cash, _, _, _) = try seedBasics(in: context)
        _ = seed(in: context, date: day(2026, 11, 10), account: cash)
        try context.save()

        let client = FakeAIClient()
        client.queueReply(#"{"type":"search","args":{}}"#)
        client.queueReply(actionsReply(
            "Xoá", #"{"action":"delete","row":"R1"}"#))
        client.queueReply(#"{"type":"answer","text":"Đã hiểu."}"#)
        let session = makeSession(client: client, context: context)

        session.send("xoá")
        #expect(await waitUntil { session.pendingProposal != nil })

        session.discardProposal()
        #expect(session.pendingProposal == nil)
        #expect(session.error == nil)
        #expect(try fetchAll(LedgerTransaction.self, in: context).count == 1)

        session.send("tiếp")
        #expect(await waitUntil {
            !session.isWorking && client.requests.count == 3 })
        #expect(client.requests.last?.messages.contains {
            $0.role == .user
                && $0.text.hasPrefix(AIAgentChatProtocol.declinedPrefix)
        } == true)
    }

    /// A new `send` while a proposal is pending discards it the same
    /// way — the decline rides into the new turn's transcript.
    @Test func newSendDiscardsPendingProposal() async throws {
        let context = try makeContext()
        let (cash, _, _, _) = try seedBasics(in: context)
        _ = seed(in: context, date: day(2026, 11, 10), account: cash)
        try context.save()

        let client = FakeAIClient()
        client.queueReply(#"{"type":"search","args":{}}"#)
        client.queueReply(actionsReply(
            "Xoá", #"{"action":"delete","row":"R1"}"#))
        client.queueReply(#"{"type":"answer","text":"Ok, bỏ qua."}"#)
        let session = makeSession(client: client, context: context)

        session.send("xoá")
        #expect(await waitUntil { session.pendingProposal != nil })

        session.send("câu hỏi khác")
        #expect(session.pendingProposal == nil)
        #expect(await waitUntil { !session.isWorking })
        #expect(try fetchAll(LedgerTransaction.self, in: context).count == 1)
        #expect(client.requests.last?.messages.contains {
            $0.role == .user
                && $0.text.hasPrefix(AIAgentChatProtocol.declinedPrefix)
        } == true)
    }

    // MARK: - Handle refresh

    /// After a confirmed edit the row's handle is stale; a later
    /// `search` re-mints it under the SAME `R…` with the refreshed
    /// snapshot, so a follow-up edit can target it again.
    @Test func handleRefreshesOnReSearchAfterApply() async throws {
        let context = try makeContext()
        let (cash, _, _, _) = try seedBasics(in: context)
        let row = seed(in: context, amount: 50_000,
                       date: day(2026, 11, 10), note: "grab beer",
                       account: cash)
        try context.save()

        let client = FakeAIClient()
        client.queueReply(#"{"type":"search","args":{"text":"grab"}}"#)
        client.queueReply(actionsReply(
            "Đổi note", #"{"action":"edit","row":"R1","note":"grab food"}"#))
        client.queueReply(#"{"type":"search","args":{"text":"grab"}}"#)
        client.queueReply(#"{"type":"answer","text":"xong"}"#)
        let session = makeSession(client: client, context: context)

        session.send("sửa note")
        #expect(await waitUntil { session.pendingProposal != nil })
        session.confirmProposal()
        #expect(session.error == nil)
        #expect(row.note == "grab food")
        #expect(session.match(forHandle: "R1") == nil)

        session.send("tìm lại")
        #expect(await waitUntil {
            !session.isWorking && client.requests.count == 4 })

        // The applied-transcript entry told the model which handles
        // went stale and to search again.
        let appliedEntry = client.requests[2].messages.last {
            $0.role == .user
                && $0.text.hasPrefix(AIAgentChatProtocol.appliedPrefix)
        }
        #expect(appliedEntry?.text.contains("R1") == true)

        // The re-search minted the same handle with the new snapshot —
        // a second edit may target R1 again.
        let tool = try #require(client.requests.last?.messages.last {
            $0.role == .user
                && $0.text.hasPrefix(AIAgentChatProtocol.toolResultPrefix) })
        #expect(tool.text.contains("\"id\":\"R1\""))
        #expect(tool.text.contains("grab food"))
        let refreshed = try #require(session.match(forHandle: "R1"))
        #expect(refreshed.original.id == row.id)
        #expect(refreshed.preview.note == "grab food")
        #expect(refreshed.original.note == "grab food")
    }

    /// A deleted row's handle never comes back — a re-search finds no
    /// trace of it.
    @Test func deletedHandleStaysUnknown() async throws {
        let context = try makeContext()
        let (cash, _, _, _) = try seedBasics(in: context)
        let row = seed(in: context, date: day(2026, 11, 10), account: cash)
        _ = seed(in: context, amount: 20_000, date: day(2026, 11, 9),
                 account: cash)
        try context.save()

        let client = FakeAIClient()
        client.queueReply(#"{"type":"search","args":{}}"#)
        client.queueReply(actionsReply(
            "Xoá", #"{"action":"delete","row":"R1"}"#))
        client.queueReply(#"{"type":"search","args":{}}"#)
        client.queueReply(#"{"type":"answer","text":"xong"}"#)
        let session = makeSession(client: client, context: context)

        session.send("xoá")
        #expect(await waitUntil { session.pendingProposal != nil })
        session.confirmProposal()
        #expect(session.error == nil)
        let remaining = try fetchAll(LedgerTransaction.self, in: context)
        #expect(remaining.count == 1)
        #expect(!remaining.contains { $0.id == row.id })

        session.send("tìm lại")
        #expect(await waitUntil {
            !session.isWorking && client.requests.count == 4 })
        // The remaining row is minted fresh — R1 is not resurrected.
        #expect(session.match(forHandle: "R1") == nil)
        #expect(session.match(forHandle: "R2")?.original.id != row.id)
    }
}
