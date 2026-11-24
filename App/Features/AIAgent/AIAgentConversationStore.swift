import Foundation

/// The list-facing half of a persisted conversation — what a history
/// UI needs without decoding the whole transcript.
struct AIAgentConversationSummary: Equatable, Sendable, Identifiable,
    Codable {
    var id: UUID
    /// First user message on one line, at most 60 characters —
    /// `AIAgentConversationStore.fallbackTitle` when there is none.
    var title: String
    var createdAt: Date
    var updatedAt: Date
    /// Visible messages in the stored snapshot.
    var messageCount: Int
}

/// One persisted conversation: the summary fields plus the versioned
/// session snapshot `AIAgentChatSession` restores from.
struct AIAgentConversationRecord: Equatable, Sendable, Identifiable,
    Codable {
    var id: UUID
    var title: String
    var createdAt: Date
    var updatedAt: Date
    var state: AIAgentConversationState

    /// Visible-message count — derived from the snapshot so it can
    /// never drift from what is actually stored.
    var messageCount: Int { state.messages.count }

    var summary: AIAgentConversationSummary {
        AIAgentConversationSummary(
            id: id, title: title, createdAt: createdAt,
            updatedAt: updatedAt, messageCount: messageCount)
    }

    init(
        id: UUID = UUID(), title: String, createdAt: Date = .now,
        updatedAt: Date = .now, state: AIAgentConversationState
    ) {
        self.id = id
        self.title = title
        self.createdAt = createdAt
        self.updatedAt = updatedAt
        self.state = state
    }
}

/// File-based persistence for agent conversations — one JSON file per
/// conversation inside a dedicated directory (`Application
/// Support/AgentConversations/` by default, injectable for tests).
///
/// The files are small and bounded — at most `maxConversations` of
/// them, each capped at `maxPersistedMessages` visible messages and
/// `maxPersistedTranscriptCharacters` of transcript — so the
/// synchronous API stays cheap enough for `@MainActor` callers (a
/// turn-end auto-save fires only a handful of times per turn, and a
/// whole-directory scan decodes at most 50 small JSON files).
///
/// Robustness rules: `list`/`load` skip a corrupt or unknown-version
/// file instead of throwing or crashing, and pruning/`deleteAll` only
/// ever touch files matching the `<uuid>.json` naming scheme — foreign
/// files inside the directory are never deleted. Writes are atomic
/// (temp file + rename) and files get the default iOS protection,
/// `completeUntilFirstUserAuthentication`, so a save can land during a
/// short background grace period.
struct AIAgentConversationStore: Sendable {

    /// The most recently `updatedAt` conversations kept on disk —
    /// older ones are pruned on each `save`.
    static let maxConversations = 50
    /// Visible messages persisted per conversation — the newest 400
    /// survive, older ones drop off before the record is written.
    static let maxPersistedMessages = 400
    /// Transcript characters persisted per conversation — the newest
    /// entries fitting the cap survive (the newest entry always does),
    /// generous headroom over the per-request character budget.
    static let maxPersistedTranscriptCharacters = 200_000

    /// "Cuộc trò chuyện mới" — the title a conversation gets when its
    /// first user message is missing or collapses to nothing.
    static let fallbackTitle = "Cuộc trò chuyện mới"
    /// Longest allowed title — first user message, one line, ellipsis.
    static let maxTitleLength = 60

    /// The directory holding one `<uuid>.json` file per conversation.
    let directory: URL

    init(directory: URL? = nil) {
        self.directory = directory ?? FileManager.default
            .urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("AgentConversations", isDirectory: true)
    }

    /// The store the app itself uses: the default Application Support
    /// directory in production, and under `-uiTestInMemoryStore` ONE
    /// fresh temporary directory shared by every `live()` call of the
    /// launch — the controller and the data-reset service then see the
    /// same store while UI tests can never read or write real history.
    static func live() -> AIAgentConversationStore {
        AIAgentConversationStore(directory: uiTestDirectory)
    }

    /// nil in production; under `-uiTestInMemoryStore` a unique path
    /// minted once per launch.
    private static let uiTestDirectory: URL? = {
        guard ProcessInfo.processInfo.arguments
            .contains("-uiTestInMemoryStore")
        else { return nil }
        return FileManager.default.temporaryDirectory
            .appendingPathComponent(
                "AgentConversationsUITest-\(UUID().uuidString)",
                isDirectory: true)
    }()

    // MARK: - Reads

    /// Every decodable conversation, newest `updatedAt` first —
    /// corrupt or unknown-version files are skipped.
    func list() -> [AIAgentConversationSummary] {
        allRecords().map(\.summary)
    }

    /// The full record for `id` — nil when the file is missing,
    /// corrupt or written by an unknown schema version.
    func load(id: UUID) -> AIAgentConversationRecord? {
        readRecord(at: fileURL(for: id))
    }

    // MARK: - Writes

    /// Atomically writes the record to `<id>.json`, bounding the
    /// stored state to the per-conversation caps first, then prunes
    /// the directory down to `Self.maxConversations` newest records.
    func save(_ record: AIAgentConversationRecord) {
        var stored = record
        stored.state = bounded(record.state)
        guard let data = try? Self.encoder.encode(stored) else { return }
        ensureDirectory()
        let url = fileURL(for: record.id)
        try? data.write(to: url, options: [.atomic])
        try? FileManager.default.setAttributes(
            [.protectionKey: FileProtectionType
                .completeUntilFirstUserAuthentication],
            ofItemAtPath: url.path)
        prune()
    }

    /// Removes `id`'s file — a no-op when it is already gone.
    func delete(id: UUID) {
        try? FileManager.default.removeItem(at: fileURL(for: id))
    }

    /// Removes every conversation file — only files matching the
    /// `<uuid>.json` scheme; foreign files in the directory stay.
    func deleteAll() {
        for url in conversationFileURLs() {
            try? FileManager.default.removeItem(at: url)
        }
    }

    // MARK: - Record helpers

    /// Worth saving means the user actually said something — a
    /// conversation with no user message is not.
    static func isWorthSaving(
        _ state: AIAgentConversationState
    ) -> Bool {
        state.messages.contains { $0.kind == .user }
    }

    /// The record title: first user message collapsed to one line,
    /// cut to `maxTitleLength` characters with an ellipsis;
    /// `fallbackTitle` when there is no usable user message.
    static func title(for state: AIAgentConversationState) -> String {
        let text = state.messages.first { $0.kind == .user }?.text ?? ""
        let collapsed = text
            .components(separatedBy: .whitespacesAndNewlines)
            .filter { !$0.isEmpty }
            .joined(separator: " ")
        guard !collapsed.isEmpty else { return fallbackTitle }
        guard collapsed.count > maxTitleLength else { return collapsed }
        return String(collapsed.prefix(maxTitleLength - 1)) + "…"
    }

    /// A fresh record for `state` — nil when the conversation is not
    /// worth saving (see `isWorthSaving`).
    static func makeRecord(
        for state: AIAgentConversationState,
        id: UUID = UUID(),
        createdAt: Date = .now,
        updatedAt: Date = .now
    ) -> AIAgentConversationRecord? {
        guard isWorthSaving(state) else { return nil }
        return AIAgentConversationRecord(
            id: id, title: title(for: state),
            createdAt: createdAt, updatedAt: updatedAt, state: state)
    }

    // MARK: - Internals

    /// Every decodable conversation file in `directory`, newest
    /// `updatedAt` first — the ordering `list` advertises and `prune`
    /// keeps. Files that fail to decode are skipped everywhere.
    private func allRecords() -> [AIAgentConversationRecord] {
        conversationFileURLs()
            .compactMap { readRecord(at: $0) }
            .sorted {
                $0.updatedAt == $1.updatedAt
                    ? $0.id.uuidString < $1.id.uuidString
                    : $0.updatedAt > $1.updatedAt
            }
    }

    /// Keeps the `Self.maxConversations` most recently updated
    /// records; undecodable files are never pruned blind.
    private func prune() {
        let records = allRecords()
        guard records.count > Self.maxConversations else { return }
        for record in records.dropFirst(Self.maxConversations) {
            try? FileManager.default.removeItem(
                at: fileURL(for: record.id))
        }
    }

    /// `<uuid>.json` files inside `directory` — the only files the
    /// store ever reads or deletes.
    private func conversationFileURLs() -> [URL] {
        guard let urls = try? FileManager.default.contentsOfDirectory(
            at: directory, includingPropertiesForKeys: nil,
            options: [.skipsHiddenFiles])
        else { return [] }
        return urls.filter {
            $0.pathExtension == "json"
                && UUID(uuidString: $0.deletingPathExtension()
                    .lastPathComponent) != nil
        }
    }

    /// One decoded record — nil for unreadable, corrupt or
    /// unknown-version files.
    private func readRecord(at url: URL) -> AIAgentConversationRecord? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        return try? Self.decoder.decode(
            AIAgentConversationRecord.self, from: data)
    }

    private func fileURL(for id: UUID) -> URL {
        directory
            .appendingPathComponent(id.uuidString, isDirectory: false)
            .appendingPathExtension("json")
    }

    private func ensureDirectory() {
        try? FileManager.default.createDirectory(
            at: directory, withIntermediateDirectories: true)
    }

    /// Applies the per-conversation caps before a record hits disk:
    /// the last `maxPersistedMessages` visible messages, and the
    /// newest transcript entries fitting
    /// `maxPersistedTranscriptCharacters` — the newest transcript
    /// entry always survives, even oversized alone.
    private func bounded(
        _ state: AIAgentConversationState
    ) -> AIAgentConversationState {
        var state = state
        if state.messages.count > Self.maxPersistedMessages {
            state.messages.removeFirst(
                state.messages.count - Self.maxPersistedMessages)
        }
        var total = 0
        var kept: [AIAgentTranscriptEntry] = []
        for entry in state.transcript.reversed() {
            if !kept.isEmpty,
               total + entry.text.count
                   > Self.maxPersistedTranscriptCharacters {
                break
            }
            total += entry.text.count
            kept.append(entry)
        }
        state.transcript = kept.reversed()
        return state
    }

    private static let encoder: JSONEncoder = {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        return encoder
    }()

    private static let decoder = JSONDecoder()
}
