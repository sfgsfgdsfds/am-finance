import Testing
import Foundation
@testable import AMFinance

/// The proposal card's pure display contracts — the apply button's label
/// counts and announces deletes — plus the scripted UI-test client's
/// gating and reply logic (`AIAgentUITestScript`, DEBUG-only like the
/// client itself).
struct AIAgentProposalCardTests {

    // MARK: - Apply button label

    /// A batch without deletes reads plainly — the confirm is one tap.
    @Test func applyTitleWithoutDeletes() {
        #expect(AIAgentProposalCard.applyTitle(itemCount: 1, deleteCount: 0)
            == "Áp dụng 1 thay đổi")
        #expect(AIAgentProposalCard.applyTitle(itemCount: 3, deleteCount: 0)
            == "Áp dụng 3 thay đổi")
    }

    /// Deletes ride in the label so a destructive batch is announced.
    @Test func applyTitleWithDeletes() {
        #expect(AIAgentProposalCard.applyTitle(itemCount: 3, deleteCount: 1)
            == "Áp dụng 3 thay đổi (xoá 1)")
        #expect(AIAgentProposalCard.applyTitle(itemCount: 4, deleteCount: 2)
            == "Áp dụng 4 thay đổi (xoá 2)")
    }

    // MARK: - Field lines

    /// `add` lines show only the new value, `edit`/`setCategory` the
    /// `old → new` transition, `delete` only the current values.
    @Test func fieldLineShapes() {
        #expect(AIAgentProposalCard.fieldLine(.init(
            field: "Số tiền", new: "50.000 ₫"))
            == "Số tiền: 50.000 ₫")
        #expect(AIAgentProposalCard.fieldLine(.init(
            field: "Số tiền", old: "60.000 ₫", new: "75.000 ₫"))
            == "Số tiền: 60.000 ₫ → 75.000 ₫")
        #expect(AIAgentProposalCard.fieldLine(.init(
            field: "Số tiền", old: "100.000 ₫"))
            == "Số tiền: 100.000 ₫")
        #expect(AIAgentProposalCard.fieldLine(.init(
            field: "Danh mục", old: "Chưa phân loại", new: "Ăn uống"))
            == "Danh mục: Chưa phân loại → Ăn uống")
    }

    // MARK: - Scripted client (DEBUG only)

    #if DEBUG
    /// The script needs BOTH launch arguments — either one alone is a
    /// no-op, so it can never fire beside a real store.
    @Test func scriptedClientGateNeedsBothArguments() {
        #expect(!AIAgentUITestScript.enabled(arguments: []))
        #expect(!AIAgentUITestScript.enabled(
            arguments: ["-uiTestAgentScript"]))
        #expect(!AIAgentUITestScript.enabled(
            arguments: ["-uiTestInMemoryStore"]))
        #expect(AIAgentUITestScript.enabled(
            arguments: ["-uiTestAgentScript", "-uiTestInMemoryStore"]))
        #expect(AIAgentUITestScript.enabled(
            arguments: ["-uiTestInMemoryStore", "-uiTestAgentScript", "-x"]))
    }

    /// A catalog-carrying system prompt (the shape
    /// `AIAgentChatProtocol.systemPrompt` emits) — one account handle on
    /// the account line, one CHI handle on the CHI line and a THU line
    /// the extractor must not pick for an expense.
    private static let catalogSystem = """
        Mỗi lượt trả lời là ĐÚNG MỘT đối tượng JSON…
        Tài khoản hợp lệ (handle tên (loại)): A1 Tiền mặt (Tiền mặt) — mặc định.
        Danh mục CHI hợp lệ: C2 Ăn nhậu, C4 Ăn uống.
        Danh mục THU hợp lệ: C1 Lương.
        """

    /// Reads the canned `actions` reply into a plain dictionary.
    private func replyObject(_ text: String) throws -> [String: Any] {
        let object = try JSONSerialization.jsonObject(
            with: try #require(text.data(using: .utf8)))
        return try #require(object as? [String: Any])
    }

    /// A plain user message earns the canned `actions` reply: one
    /// expense add — 50.000 ₫, note "Phở UI test" — with the real
    /// account/category handles scraped from the system prompt's
    /// catalog lines (CHI, never THU).
    @Test func scriptedReplyProposesExpenseAdd() async throws {
        let client = AIAgentUITestScript.Client()
        let request = AIRequest(
            system: Self.catalogSystem,
            messages: [AIMessage(role: .user, text: "ghi lại phở 50k")],
            jsonMode: true)
        let reply = try await client.complete(request)
        let object = try replyObject(reply.text)

        #expect(object["type"] as? String == "actions")
        let actions = try #require(object["actions"] as? [[String: Any]])
        #expect(actions.count == 1)
        let action = try #require(actions.first)
        #expect(action["action"] as? String == "add")
        #expect(action["kind"] as? String == "expense")
        #expect(action["amount"] as? Int == 50_000)
        #expect(action["note"] as? String == "Phở UI test")
        // The A… handle comes off the account catalog line…
        #expect(action["account"] as? String == "A1")
        // …and the C… handle off the CHI line — C1 is THU here and must
        // not leak into an expense proposal.
        #expect(action["category"] as? String == "C2")
    }

    /// Once a tool result or the apply record rides the conversation the
    /// script answers plainly — its proposing streak is over.
    @Test func scriptedReplyAnswersAfterToolAndApplyEntries() async throws {
        let client = AIAgentUITestScript.Client()
        for entry in [
            AIAgentChatProtocol.toolResultPrefix + "\n{}",
            AIAgentChatProtocol.appliedPrefix + " Đã áp dụng: thêm 1",
        ] {
            let request = AIRequest(
                system: Self.catalogSystem,
                messages: [
                    AIMessage(role: .user, text: "ghi lại phở 50k"),
                    AIMessage(role: .assistant, text: "{}"),
                    AIMessage(role: .user, text: entry),
                ],
                jsonMode: true)
            let reply = try await client.complete(request)
            let object = try replyObject(reply.text)
            #expect(object["type"] as? String == "answer")
        }
    }

    /// A declined batch does not end the proposing streak — the next
    /// user message re-proposes, which is what the discard check needs.
    @Test func scriptedReplyReproposesAfterDecline() async throws {
        let client = AIAgentUITestScript.Client()
        let request = AIRequest(
            system: Self.catalogSystem,
            messages: [
                AIMessage(role: .user, text: "ghi lại phở 50k"),
                AIMessage(role: .assistant, text: "{}"),
                AIMessage(role: .user,
                          text: AIAgentChatProtocol.declinedPrefix + " …"),
                AIMessage(role: .user, text: "ghi lại lần nữa"),
            ],
            jsonMode: true)
        let reply = try await client.complete(request)
        let object = try replyObject(reply.text)
        #expect(object["type"] as? String == "actions")
    }

    /// No catalog in the system prompt (a read-only grant prompt): the
    /// add omits both handles and still resolves via the default
    /// account.
    @Test func scriptedReplyOmitsMissingHandles() async throws {
        let client = AIAgentUITestScript.Client()
        let request = AIRequest(
            system: "Phiên này chỉ đọc — không đề xuất thêm/xoá/sửa dữ liệu.",
            messages: [AIMessage(role: .user, text: "ghi lại phở 50k")],
            jsonMode: true)
        let reply = try await client.complete(request)
        let object = try replyObject(reply.text)
        let action = try #require(
            (object["actions"] as? [[String: Any]])?.first)
        #expect(action["account"] == nil)
        #expect(action["category"] == nil)
    }
    #endif
}
