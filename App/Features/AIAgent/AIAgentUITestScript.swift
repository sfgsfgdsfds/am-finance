#if DEBUG
import Foundation

/// Deterministic, fully offline agent client for UI tests — reachable
/// only when the app launches with BOTH `-uiTestAgentScript` and
/// `-uiTestInMemoryStore`, and compiled only in DEBUG builds, so it can
/// never serve a real user or a real store. With it the Agent screen
/// counts as configured even with no provider profile, letting
/// `testAgentProposalConfirm` drive the proposal-card flow end to end
/// without a network.
enum AIAgentUITestScript {
    /// The launch argument that turns the scripted client on.
    static let launchArgument = "-uiTestAgentScript"
    /// The flag it is honoured beside — the throwaway in-memory UI-test
    /// store. `-uiTestAgentScript` alone does nothing.
    static let inMemoryArgument = "-uiTestInMemoryStore"

    /// The pure gate — both arguments, or the script never runs.
    static func enabled(arguments: [String]) -> Bool {
        arguments.contains(launchArgument)
            && arguments.contains(inMemoryArgument)
    }

    /// Whether this process should serve the Agent from `Client`.
    static var isEnabled: Bool {
        enabled(arguments: ProcessInfo.processInfo.arguments)
    }

    /// The deterministic replies — one canned contract reply per request.
    ///
    /// A plain user message earns an `actions` reply proposing one
    /// expense — 50.000 ₫, note "Phở UI test" — carrying the first `A…`
    /// account handle and, when the catalog advertises one, the first
    /// `C…` handle of the CHI list, both scraped from the request's
    /// system prompt so the batch resolves and validates like a real
    /// model's would. Once the conversation carries a tool result or an
    /// apply record the script answers plainly — its work is done.
    /// (A declined or failed batch does NOT count: the next user message
    /// re-proposes, which is what the discard check needs.)
    static func reply(to request: AIRequest) -> String {
        if request.messages.contains(where: isToolOrApplyEntry) {
            return #"{"type":"answer","text":"Xong rồi — không còn gì để đề xuất."}"#
        }
        var action: [String: Any] = [
            "action": "add",
            "kind": "expense",
            "amount": 50_000,
            "note": "Phở UI test",
        ]
        if let account = accountHandle(in: request.system) {
            action["account"] = account
        }
        if let category = categoryHandle(in: request.system) {
            action["category"] = category
        }
        let payload: [String: Any] = [
            "type": "actions",
            "text": "Đề xuất thêm khoản chi phở 50.000 ₫.",
            "actions": [action],
        ]
        guard let data = try? JSONSerialization.data(
            withJSONObject: payload, options: [.sortedKeys])
        else { return #"{"type":"answer","text":"Không dựng được đề xuất."}"# }
        return String(decoding: data, as: UTF8.self)
    }

    /// The transcript entries that end the proposing streak — a tool
    /// result or the "[HỆ THỐNG — đã áp dụng]" record.
    private static func isToolOrApplyEntry(_ message: AIMessage) -> Bool {
        message.text.hasPrefix(AIAgentChatProtocol.toolResultPrefix)
            || message.text.hasPrefix(AIAgentChatProtocol.appliedPrefix)
    }

    /// First `A…` handle on the system prompt's account catalog line
    /// ("Tài khoản hợp lệ (handle tên (loại)): A1 Tiền mặt (…)").
    static func accountHandle(in system: String?) -> String? {
        handle(prefix: "A", in: system, lineMarker: "Tài khoản hợp lệ")
    }

    /// First `C…` handle on the CHI category catalog line — never the
    /// THU line, so the proposed expense's category kind always matches.
    static func categoryHandle(in system: String?) -> String? {
        handle(prefix: "C", in: system, lineMarker: "Danh mục CHI hợp lệ")
    }

    /// Finds `prefix` immediately followed by digits inside the `system`
    /// line containing `marker` — catalog entries render as
    /// "A1 Tiền mặt", "C3 Ăn uống".
    private static func handle(
        prefix: Character, in system: String?, lineMarker marker: String
    ) -> String? {
        guard let line = system?.components(separatedBy: .newlines)
            .first(where: { $0.contains(marker) })
        else { return nil }
        var index = line.startIndex
        while index < line.endIndex {
            let cursor = line.index(after: index)
            guard line[index] == prefix else {
                index = cursor
                continue
            }
            var end = cursor
            while end < line.endIndex, line[end].isNumber {
                end = line.index(after: end)
            }
            guard end > cursor else {
                index = cursor
                continue
            }
            return String(line[index..<end])
        }
        return nil
    }

    /// The offline client `AIAgentView` prefers over the provider store
    /// while `isEnabled` holds. `complete` and `stream` serve the same
    /// canned reply; nothing is recorded, nothing goes out.
    struct Client: AIChatClientProtocol {
        func complete(_ request: AIRequest) async throws -> AIResponse {
            AIResponse(text: AIAgentUITestScript.reply(to: request))
        }

        func stream(
            _ request: AIRequest
        ) -> AsyncThrowingStream<String, Error> {
            AsyncThrowingStream { continuation in
                continuation.yield(AIAgentUITestScript.reply(to: request))
                continuation.finish()
            }
        }
    }
}
#endif
