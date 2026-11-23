import Foundation

/// One transcript entry — what actually rides in `AIRequest`s. Tool
/// calls and answers keep the model's raw JSON reply so it can reason
/// over its own calls; `isToolResult` marks the entries the trimmer
/// drops before real turns (the newest one is never dropped). Codable
/// because the transcript persists inside `AIAgentConversationState`.
struct AIAgentTranscriptEntry: Equatable, Sendable, Codable {
    var role: AIRole
    var text: String
    var isToolResult = false

    init(role: AIRole, text: String, isToolResult: Bool = false) {
        self.role = role
        self.text = text
        self.isToolResult = isToolResult
    }
}

/// The versioned, persistable snapshot of one `AIAgentChatSession`:
/// the visible `messages`, the model-bound `transcript` and the handle
/// numbering — the transaction id → `R…` map plus the `A…`/`C…`
/// catalog maps and their next numbers — so a restored session keeps
/// every handle the model already saw stable.
///
/// Deliberately NOT inside: live `AIAgentLookupMatch` snapshots and
/// their lookup windows (point-in-time data — a restored `R…` handle
/// keeps its number but holds no match until a fresh `search` re-mints
/// it under the same handle), the pending proposal, errors and
/// in-flight work. A restored conversation never resumes a proposal.
///
/// Decoding is version-gated: a file written by an unknown schema
/// version fails to decode (the store then skips it), while missing
/// fields inside a known version decode to empty defaults.
struct AIAgentConversationState: Equatable, Sendable {

    /// The only schema version this build writes and reads.
    static let currentVersion = 1

    /// `Self.currentVersion` on everything this build produces.
    var version: Int
    /// The visible conversation — user text, tool-activity notes and
    /// assistant answers, in order.
    var messages: [AIAgentChatMessage]
    /// The model-bound transcript — a superset of `messages` that also
    /// carries the raw JSON replies and the tool results.
    var transcript: [AIAgentTranscriptEntry]
    /// Transaction id → its session-stable `R…` handle — the map a
    /// fresh `search` re-mints matches under after a restore.
    var handleByTransactionID: [UUID: String]
    /// The next `R…` number — minting continues, never reuses.
    var nextHandleNumber: Int
    /// `A…`/`C…` catalog handle → object id, and their next numbers —
    /// kept so a catalog refresh after restore preserves the numbering
    /// the transcript's earlier turns referenced.
    var accountHandles: [String: UUID]
    var categoryHandles: [String: UUID]
    var nextAccountHandle: Int
    var nextCategoryHandle: Int

    init(
        version: Int = AIAgentConversationState.currentVersion,
        messages: [AIAgentChatMessage] = [],
        transcript: [AIAgentTranscriptEntry] = [],
        handleByTransactionID: [UUID: String] = [:],
        nextHandleNumber: Int = 1,
        accountHandles: [String: UUID] = [:],
        categoryHandles: [String: UUID] = [:],
        nextAccountHandle: Int = 1,
        nextCategoryHandle: Int = 1
    ) {
        self.version = version
        self.messages = messages
        self.transcript = transcript
        self.handleByTransactionID = handleByTransactionID
        self.nextHandleNumber = nextHandleNumber
        self.accountHandles = accountHandles
        self.categoryHandles = categoryHandles
        self.nextAccountHandle = nextAccountHandle
        self.nextCategoryHandle = nextCategoryHandle
    }
}

extension AIAgentConversationState: Codable {

    private enum CodingKeys: String, CodingKey {
        case version, messages, transcript, handleByTransactionID
        case nextHandleNumber, accountHandles, categoryHandles
        case nextAccountHandle, nextCategoryHandle
    }

    /// Version-gated, field-tolerant decode: an absent or mismatched
    /// `version` corrupts the decode (the file is skipped, never
    /// partially read), while every content field falls back to empty.
    init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let version = try container.decodeIfPresent(
            Int.self, forKey: .version) ?? 0
        guard version == Self.currentVersion else {
            throw DecodingError.dataCorruptedError(
                forKey: .version, in: container,
                debugDescription:
                    "Unsupported conversation state version \(version)")
        }
        self.version = version
        self.messages = try container.decodeIfPresent(
            [AIAgentChatMessage].self, forKey: .messages) ?? []
        self.transcript = try container.decodeIfPresent(
            [AIAgentTranscriptEntry].self, forKey: .transcript) ?? []
        self.handleByTransactionID = try container.decodeIfPresent(
            [UUID: String].self, forKey: .handleByTransactionID) ?? [:]
        self.nextHandleNumber = try container.decodeIfPresent(
            Int.self, forKey: .nextHandleNumber) ?? 1
        self.accountHandles = try container.decodeIfPresent(
            [String: UUID].self, forKey: .accountHandles) ?? [:]
        self.categoryHandles = try container.decodeIfPresent(
            [String: UUID].self, forKey: .categoryHandles) ?? [:]
        self.nextAccountHandle = try container.decodeIfPresent(
            Int.self, forKey: .nextAccountHandle) ?? 1
        self.nextCategoryHandle = try container.decodeIfPresent(
            Int.self, forKey: .nextCategoryHandle) ?? 1
    }
}
