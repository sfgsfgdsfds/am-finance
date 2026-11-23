import Foundation
import SwiftData
import FinanceCore

/// Opt-in privacy switches for the data preview. Both default OFF —
/// transaction notes and real account names only enter the outgoing
/// payload when the caller explicitly asks, and always truncated.
struct AIAgentPreviewOptions: Equatable, Sendable {
    var includeNotes = false
    var includeAccountNames = false
}

/// What the provider will see — and what the UI shows before the user
/// sends it. Rows are ephemeral `R…` handles carrying kind, đồng
/// magnitude, day, category name, provenance bucket and flags; nothing
/// identifies a row outside this session. No SwiftData ids, external
/// ids, balances or keys ever appear here.
struct AIAgentDataPreview: Equatable, Sendable {

    struct Row: Equatable, Sendable, Identifiable {
        /// The ephemeral handle the model references — "R1", "R2", …
        var handle: String
        var kind: TransactionKind
        /// Positive đồng magnitude — `kind` carries the sign.
        var amount: Int64
        var date: Date
        var categoryName: String?
        var source: AIAgentSource
        var needsReview: Bool
        /// `TransactionListScope.unclassified` semantics, kept for the UI.
        var unclassified: Bool
        /// May receive a `setCategory` proposal — a plain, unlinked
        /// income/expense row (never transfer, never rent-linked).
        var editable: Bool
        /// Opt-in only, truncated — absent otherwise.
        var note: String?
        /// Opt-in only, truncated — absent otherwise.
        var accountName: String?

        var id: String { handle }
    }

    /// The bounded question this preview answers.
    var question: String
    /// The effective window that was scanned.
    var window: DateInterval
    /// Rows the bounded scan loaded.
    var scanned: Int
    /// True when caps may have hidden further matches.
    var truncated: Bool
    /// The privacy switches the projection was built with.
    var options: AIAgentPreviewOptions
    var rows: [Row]
}

/// An active category minted into an ephemeral `C…` handle for the
/// analysis prompt. `id`/`name`/`kind` are the snapshot the confirm path
/// revalidates against — a category renamed, archived or deleted since
/// the preview no longer matches its handle. Local only: the provider
/// sees `handle` + `name` at most.
struct AIAgentCategoryHandle: Equatable, Sendable {
    var handle: String
    var id: UUID
    var name: String
    var kind: CategoryKind
}

/// The immutable stage-2 artifact: the displayable preview (exactly what
/// will be sent), the minted category handles, the fixed provider
/// request and the local-only handle → precondition-token map. The UI
/// shows `preview`, then calls `analyze` with this value — `request` is
/// sent verbatim and `matches` never leave the device.
struct AIAgentPreparedAnalysis: Equatable, Sendable {
    var preview: AIAgentDataPreview
    /// Active categories minted into handles — empty unless the grant
    /// allowed proposals when this was built.
    var categories: [AIAgentCategoryHandle]
    /// The exact request `analyze` sends — built once, never rebuilt.
    var request: AIRequest
    /// `R…` handle → lookup-issued snapshot token. Local only.
    var matches: [String: AIAgentLookupMatch]
    /// The window the lookup actually scanned — pass it back to
    /// `applyCategoryEdits` as `lookupWindow` so confirmed edits
    /// re-resolve the same slice instead of the grant's first
    /// `scanLimit` rows.
    var effectiveWindow: DateInterval
    /// Whether the built request offers `setCategory` proposals.
    var grantsProposals: Bool
}

/// What stage 1 produced: the bounded question, the parsed tool args
/// and the bounded local lookup — the only copy of the rows.
struct AIAgentSearchResult: Equatable, Sendable {
    var question: String
    var query: AIAgentLookupQuery
    var result: AIAgentLookupResult
}

/// One validated `setCategory` proposal: the preview row it names, the
/// local precondition token the apply re-verifies, and the snapped
/// category handle. Nothing here executes — the user confirms in PR3.
struct AIAgentCategoryProposal: Equatable, Sendable {
    var row: AIAgentDataPreview.Row
    var match: AIAgentLookupMatch
    var category: AIAgentCategoryHandle
}

/// The presentable stage-2 reply: the model's brief Vietnamese answer
/// plus every proposal that survived validation — or none plus the
/// reason the whole list was voided. Applying is a separate, explicit
/// call; this value never triggers a write.
struct AIAgentAnalysis: Equatable, Sendable {
    /// The model's short Vietnamese answer — may be "" when it only
    /// proposed edits or could not phrase a reply.
    var answer: String
    var proposals: [AIAgentCategoryProposal]
    /// Non-nil when proposals arrived but were voided wholesale.
    var proposalRejection: AIAgentError?
    /// The window the proposals' lookup scanned — the `lookupWindow`
    /// the confirmed apply expects.
    var effectiveWindow: DateInterval
}

extension AIAgentAnalysis {
    /// Maps the validated proposals to tool edits: each snapped category
    /// handle must still resolve to a live, un-renamed, un-archived
    /// category or the whole batch throws `staleCategory`. Call only on
    /// explicit user confirmation — then hand the result plus
    /// `effectiveWindow` to `applyCategoryEdits`.
    @MainActor
    func categoryEdits(in context: ModelContext) throws -> [AIAgentCategoryEdit] {
        let fetched = try context.fetch(FetchDescriptor<LedgerCategory>())
        let byID = Dictionary(
            fetched.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        return try proposals.map { proposal in
            let handle = proposal.category
            guard let live = byID[handle.id],
                  !live.isArchived,
                  live.name == handle.name,
                  live.kind == handle.kind
            else { throw AIAgentError.staleCategory }
            return AIAgentCategoryEdit(
                match: proposal.match, category: live)
        }
    }
}

/// The two explicit stages of the AI agent — no loops, no autonomy:
///
/// - `search` sends the bounded question plus the granted day range to
///   the model, parses the single allow-listed `searchTransactions`
///   reply and runs it through `AIAgentLedgerTools.lookup`. Permission
///   and window are re-checked before the request and before the read.
///
/// - `prepareAnalysis` mints the immutable preview + fixed request from
///   the lookup hits — nothing is sent or written.
///
/// - `analyze` — only when the UI asks — re-checks the grant (revocation
///   means no network), sends the prepared request and parses the reply
///   into a presentable answer plus strictly validated proposals.
///
/// Neither AI method writes. Applying needs a separate, user-confirmed
/// call to `AIAgentLedgerTools.applyCategoryEdits` (PR3).
@MainActor
struct AIAgentOrchestrator {

    /// Outgoing-payload caps the model cannot raise.
    static let maxNoteLength = 80
    static let maxAccountNameLength = 40
    static let maxCategoryNameLength = 60
    /// Active categories minted per direction into `C…` handles.
    static let maxCategoriesPerDirection = 40
    /// Hard bound on the category fetch itself.
    static let categoryFetchLimit = 200

    var client: any AIChatClientProtocol
    var tools: AIAgentLedgerTools
    /// The "now" the prompts stamp — injected in tests.
    var now: () -> Date
    var calendar: Calendar

    init(
        client: any AIChatClientProtocol,
        tools: AIAgentLedgerTools = AIAgentLedgerTools(),
        now: @escaping () -> Date = { .now },
        calendar: Calendar = AppCalendar.vietnam
    ) {
        self.client = client
        self.tools = tools
        self.now = now
        self.calendar = calendar
    }

    // MARK: - Stage 1: question → bounded local lookup

    /// Sends the question to the model, parses the allow-listed tool
    /// call and runs the bounded lookup — all under `permission`.
    /// A denied or oversized grant fails before the request is sent;
    /// a wrong tool name or malformed args fail before the ledger read.
    func search(
        question: String,
        permission: AIAgentPermission,
        in context: ModelContext
    ) async throws -> AIAgentSearchResult {
        guard permission.access.canLookup
        else { throw AIAgentError.permissionDenied }
        guard permission.window.duration <= AIAgentLedgerTools.maxWindow
        else { throw AIAgentError.windowTooWide }
        let boundedQuestion = AIAgentToolPlanner.bounded(question)
        guard !boundedQuestion.isEmpty
        else { throw AIAgentError.malformedQuery }

        let request = AIAgentToolPlanner.request(
            question: boundedQuestion, permission: permission,
            now: now(), calendar: calendar)
        let reply = try await client.complete(request)
        let query = try AIAgentToolPlanner.parse(
            reply.text, grantedWindow: permission.window,
            calendar: calendar)
        let result = try tools.lookup(
            query, permission: permission, in: context)
        return AIAgentSearchResult(
            question: boundedQuestion, query: query, result: result)
    }

    // MARK: - Stage 2: hits → immutable preview + request → analysis

    /// Builds the exact artifact the UI shows and `analyze` sends:
    /// `R…` rows projected under `options`, the category handles a
    /// proposal may name (only when the grant allows proposing), the
    /// fixed request and the local handle map. Pure — no network, no
    /// writes; a revoked grant still refuses.
    func prepareAnalysis(
        _ search: AIAgentSearchResult,
        options: AIAgentPreviewOptions = AIAgentPreviewOptions(),
        permission: AIAgentPermission,
        in context: ModelContext
    ) throws -> AIAgentPreparedAnalysis {
        guard permission.access.canLookup
        else { throw AIAgentError.permissionDenied }

        var rows: [AIAgentDataPreview.Row] = []
        rows.reserveCapacity(search.result.matches.count)
        var matches: [String: AIAgentLookupMatch] = [:]
        for (index, match) in search.result.matches.enumerated() {
            let handle = "R\(index + 1)"
            let preview = match.preview
            rows.append(AIAgentDataPreview.Row(
                handle: handle,
                kind: preview.kind,
                amount: preview.amount,
                date: preview.date,
                categoryName: preview.categoryName.map {
                    Self.truncated($0, limit: Self.maxCategoryNameLength)
                },
                source: preview.source,
                needsReview: preview.needsReview,
                unclassified: preview.unclassified,
                editable: AIAgentLedgerTools.canEditCategory(
                    of: match.original),
                note: options.includeNotes
                    ? Self.truncated(preview.note, limit: Self.maxNoteLength)
                    : nil,
                accountName: options.includeAccountNames
                    ? preview.accountName.map {
                        Self.truncated(
                            $0, limit: Self.maxAccountNameLength)
                    }
                    : nil))
            matches[handle] = match
        }

        // The category catalog only enters the payload when proposals
        // are on the table — a read-only grant gets no catalog at all.
        let grantsProposals = permission.access.canProposeCategoryEdits
        let categories = grantsProposals
            ? mintCategoryHandles(from: try activeCategories(in: context))
            : []

        let preview = AIAgentDataPreview(
            question: search.question,
            window: search.result.window,
            scanned: search.result.scanned,
            truncated: search.result.truncated,
            options: options,
            rows: rows)
        let request = AIAgentAnalysisPlanner.request(
            preview: preview, categories: categories,
            grantsProposals: grantsProposals, calendar: calendar)
        return AIAgentPreparedAnalysis(
            preview: preview,
            categories: categories,
            request: request,
            matches: matches,
            effectiveWindow: search.result.window,
            grantsProposals: grantsProposals)
    }

    /// Sends the prepared request — only when the UI explicitly calls
    /// it — and parses the reply. The grant is re-checked first: full
    /// revocation means no network at all, and a request minted with
    /// proposals fails when the grant no longer covers them.
    func analyze(
        _ prepared: AIAgentPreparedAnalysis,
        permission: AIAgentPermission
    ) async throws -> AIAgentAnalysis {
        guard permission.access.canLookup
        else { throw AIAgentError.permissionDenied }
        if prepared.grantsProposals,
           !permission.access.canProposeCategoryEdits {
            throw AIAgentError.permissionDenied
        }
        let reply = try await client.complete(prepared.request)
        return try AIAgentAnalysisPlanner.parse(
            reply.text, prepared: prepared,
            canPropose: permission.access.canProposeCategoryEdits)
    }

    // MARK: - Internals

    /// Active categories for handle minting — bounded fetch, stable
    /// order (sort order then name).
    private func activeCategories(
        in context: ModelContext
    ) throws -> [LedgerCategory] {
        var descriptor = FetchDescriptor<LedgerCategory>(
            predicate: #Predicate { !$0.isArchived },
            sortBy: [SortDescriptor(\.sortOrder),
                     SortDescriptor(\.name)])
        descriptor.fetchLimit = Self.categoryFetchLimit
        return try context.fetch(descriptor)
    }

    /// `C1`, `C2`, … over the active categories — at most
    /// `maxCategoriesPerDirection` per kind.
    private func mintCategoryHandles(
        from categories: [LedgerCategory]
    ) -> [AIAgentCategoryHandle] {
        var handles: [AIAgentCategoryHandle] = []
        var counts: [CategoryKind: Int] = [:]
        for category in categories {
            let used = counts[category.kind, default: 0]
            guard used < Self.maxCategoriesPerDirection else { continue }
            counts[category.kind] = used + 1
            handles.append(AIAgentCategoryHandle(
                handle: "C\(handles.count + 1)",
                id: category.id,
                name: category.name,
                kind: category.kind))
        }
        return handles
    }

    /// Cuts a string to `limit` characters with an ellipsis.
    private static func truncated(_ text: String, limit: Int) -> String {
        guard text.count > limit else { return text }
        return String(text.prefix(max(0, limit - 1))) + "…"
    }
}
