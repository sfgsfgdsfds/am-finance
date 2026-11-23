import Foundation
import SwiftData
import FinanceCore

/// What one `applyCategoryEdits` call committed — the batch is atomic,
/// so the count always equals the confirmed batch size.
struct AIAgentApplyResult: Equatable, Sendable {
    var appliedCount: Int
}

/// One confirmed category edit inside a batch — the lookup-issued match
/// (its `original` snapshot is re-verified before anything writes) plus
/// the live category it moves to. The batch apply takes a list of
/// these, so a mixed set of targets still lands in one atomic commit.
struct AIAgentCategoryEdit {
    var match: AIAgentLookupMatch
    var category: LedgerCategory
}

/// Every failure the agent ledger tools can produce — each case carries
/// a Vietnamese message the UI can show verbatim.
enum AIAgentError: LocalizedError {
    /// The grant's access level does not cover this tool — including a
    /// permission revoked between the lookup and the confirmed apply.
    case permissionDenied
    /// The granted window exceeds `AIAgentLedgerTools.maxWindow` —
    /// refused rather than silently clipped.
    case windowTooWide
    /// The query interval escapes the granted window — a query may only
    /// narrow the grant.
    case queryOutsideWindow
    /// An apply target's snapshot date sits outside the granted window.
    case rowOutsideWindow
    /// The context already holds unsaved writes; a rollback on failure
    /// would eat them, so the operation refuses to start.
    case contextHasChanges
    /// The confirmed batch was empty.
    case emptyBatch
    /// The same row appeared twice in one batch.
    case duplicateTransaction
    /// A target row changed, was deleted or can no longer be re-verified
    /// against its lookup snapshot — including a repeated submission of
    /// an already-applied edit.
    case staleTransaction
    /// A target is not a plain income/expense row — transfers,
    /// rental-linked rows and malformed rows are out of scope.
    case transactionNotEligible
    /// The category is archived, lives on another context or its kind
    /// does not match a target row's income/expense kind.
    case invalidCategory
    /// A target already carries this category and is not pending review
    /// — applying would change nothing.
    case noOpEdit
    /// The single commit failed; the batch's writes were rolled back.
    case saveFailed(any Error)
    /// The model's reply carried no usable JSON for the stage that ran.
    case unparseableModelReply
    /// The model asked for a tool or proposal action outside the
    /// allow-list — the only tools are `searchTransactions` and
    /// `setCategory`.
    case unsupportedTool
    /// The `searchTransactions` arguments were malformed — bad day
    /// strings, an inverted date or amount range, negative or non-numeric
    /// bounds, overlong text, or fields outside the allow-list.
    case malformedQuery
    /// A proposal referenced a row/category handle the preview never
    /// issued.
    case unknownHandle
    /// The proposal list itself was malformed — not objects, missing
    /// keys, or a row named twice.
    case invalidProposal
    /// More proposals than the cap allows — the model is told to
    /// propose at most one edit per surfaced row.
    case tooManyProposals
    /// The proposal's snapped category was renamed, archived or deleted
    /// since the preview was built — the confirm would write something
    /// the user never saw.
    case staleCategory

    var errorDescription: String? {
        switch self {
        case .permissionDenied:
            return "Trợ lý AI không có quyền thực hiện thao tác này."
        case .windowTooWide:
            return "Khoảng thời gian cấp phép quá rộng — tối đa khoảng 3 tháng."
        case .queryOutsideWindow:
            return "Truy vấn vượt ngoài khoảng thời gian đã cho phép."
        case .rowOutsideWindow:
            return "Giao dịch nằm ngoài khoảng thời gian đã cho phép."
        case .contextHasChanges:
            return "Có thay đổi chưa lưu — hãy lưu hoặc huỷ trước khi tiếp tục."
        case .emptyBatch:
            return "Không có giao dịch nào được chọn."
        case .duplicateTransaction:
            return "Một giao dịch xuất hiện hai lần trong danh sách."
        case .staleTransaction:
            return "Giao dịch đã thay đổi hoặc bị xoá — hãy tra cứu lại."
        case .transactionNotEligible:
            return "Chỉ đổi danh mục được khoản thu/chi thường — không áp dụng cho chuyển khoản hay giao dịch cho thuê."
        case .invalidCategory:
            return "Danh mục không hợp lệ — phải còn hoạt động và đúng loại thu/chi."
        case .noOpEdit:
            return "Giao dịch đã ở danh mục này — không có gì để thay đổi."
        case .saveFailed(let error):
            return "Không lưu được: \(error.localizedDescription)"
        case .unparseableModelReply:
            return "AI trả lời không đúng định dạng — hãy thử lại."
        case .unsupportedTool:
            return "AI yêu cầu một thao tác nằm ngoài phạm vi cho phép."
        case .malformedQuery:
            return "Bộ lọc AI trả về không hợp lệ."
        case .unknownHandle:
            return "Đề xuất tham chiếu một mục không có trong kết quả."
        case .invalidProposal:
            return "Đề xuất của AI không hợp lệ — không áp dụng đề xuất nào."
        case .tooManyProposals:
            return "AI đề xuất quá nhiều thay đổi — hãy thu hẹp yêu cầu."
        case .staleCategory:
            return "Danh mục đã đổi tên, bị ẩn hoặc bị xoá — hãy tra cứu lại."
        }
    }
}

extension AIAgentError: Equatable {
    /// Case equality — two `saveFailed`s compare equal regardless of the
    /// wrapped error, so tests can match the specific case.
    static func == (lhs: AIAgentError, rhs: AIAgentError) -> Bool {
        switch (lhs, rhs) {
        case (.permissionDenied, .permissionDenied),
             (.windowTooWide, .windowTooWide),
             (.queryOutsideWindow, .queryOutsideWindow),
             (.rowOutsideWindow, .rowOutsideWindow),
             (.contextHasChanges, .contextHasChanges),
             (.emptyBatch, .emptyBatch),
             (.duplicateTransaction, .duplicateTransaction),
             (.staleTransaction, .staleTransaction),
             (.transactionNotEligible, .transactionNotEligible),
             (.invalidCategory, .invalidCategory),
             (.noOpEdit, .noOpEdit),
             (.saveFailed, .saveFailed),
             (.unparseableModelReply, .unparseableModelReply),
             (.unsupportedTool, .unsupportedTool),
             (.malformedQuery, .malformedQuery),
             (.unknownHandle, .unknownHandle),
             (.invalidProposal, .invalidProposal),
             (.tooManyProposals, .tooManyProposals),
             (.staleCategory, .staleCategory):
            return true
        default:
            return false
        }
    }
}

/// The local ledger tools the AM Finance AI agent is allowed to call.
///
/// Two entry points, both gated on `AIAgentPermission`:
///
/// - `lookup` — a bounded read inside the granted date window. It fetches
///   at most `scanLimit` newest rows in-window, filters in memory (text
///   folding cannot live in a fetch predicate) and returns at most
///   `resultLimit` matches newest-first with a `truncated` honesty flag.
///   Rows come back as `AIAgentLookupMatch` — a displayable preview plus
///   a local-only precondition token. Nothing is serialized or sent.
///
/// - `applyCategoryEdits` — the single write path: a user-confirmed
///   batch of lookup-issued matches re-categorized to one active
///   category. Everything validates first (permission, window, clean
///   context, snapshot freshness, eligibility, no-ops), then one
///   `saveAndCheck` commit lands the whole batch; a failed commit rolls
///   back only this operation's writes. Only `category`, `needsReview`
///   and `updatedAt` ever move — amount, date, accounts, business and
///   external provenance are never touched. No deletions, inserts,
///   transfers, rollovers or account operations exist on this tool.
@MainActor
struct AIAgentLedgerTools {

    /// App-controlled caps the model cannot raise — instance-overridable
    /// for tests only.
    nonisolated static let resultLimit = 30
    /// The bounded scan slice: the newest rows inside the window a
    /// single lookup inspects. Deliberately not the whole ledger.
    nonisolated static let scanLimit = 500
    /// The widest window a permission may grant — ~3 months.
    nonisolated static let maxWindow: TimeInterval = 93 * 86_400

    var resultLimit = Self.resultLimit
    var scanLimit = Self.scanLimit

    /// Commit seam — `LedgerBalanceStore.saveAndCheck` in production so
    /// the fingerprint check runs inline after the save; tests inject a
    /// thrower to prove a failed commit leaves no partial writes.
    var saveAndCheck: @MainActor (ModelContext) throws -> Void

    init(
        resultLimit: Int? = nil,
        scanLimit: Int? = nil,
        saveAndCheck: (@MainActor (ModelContext) throws -> Void)? = nil
    ) {
        if let resultLimit { self.resultLimit = resultLimit }
        if let scanLimit { self.scanLimit = scanLimit }
        self.saveAndCheck = saveAndCheck ?? { context in
            try LedgerBalanceStores.shared(for: context.container)
                .saveAndCheck(context)
        }
    }

    // MARK: - Lookup

    /// Runs the bounded read tool. The access level and the window are
    /// re-checked here — a revoked or oversized grant fails loudly, and
    /// a query interval escaping the grant is refused rather than
    /// clipped.
    func lookup(
        _ query: AIAgentLookupQuery = .init(),
        permission: AIAgentPermission,
        in context: ModelContext
    ) throws -> AIAgentLookupResult {
        guard permission.access.canLookup
        else { throw AIAgentError.permissionDenied }
        let window = try checked(permission.window)
        let interval = try narrowed(query.interval, within: window)
        let rows = try fetchWindow(interval, in: context)

        let folded = TransactionListSearch.normalizedQuery(query.text)
        var matches: [AIAgentLookupMatch] = []
        var stoppedEarly = false
        for row in rows {
            guard Self.matches(row, query: query, folded: folded)
            else { continue }
            matches.append(Self.makeMatch(row))
            if matches.count >= resultLimit {
                stoppedEarly = true
                break
            }
        }
        return AIAgentLookupResult(
            window: interval,
            matches: matches,
            scanned: rows.count,
            truncated: stoppedEarly || rows.count >= scanLimit)
    }

    // MARK: - Apply category edits

    /// Applies one user-confirmed batch: every `matches` entry must be a
    /// lookup-issued match whose snapshot still verifies a live,
    /// eligible income/expense row, and `category` must be active and
    /// kind-matching for every target. Any rejection — revoked
    /// permission, oversized window, dirty context, empty or duplicated
    /// batch, stale/deleted/out-of-window/ineligible/no-op targets —
    /// writes nothing. On success each row keeps its id, amount, date,
    /// accounts, business, note and external provenance; `needsReview`
    /// clears and `updatedAt` is stamped on every applied row.
    @discardableResult
    func applyCategoryEdits(
        _ matches: [AIAgentLookupMatch],
        to category: LedgerCategory,
        permission: AIAgentPermission,
        in context: ModelContext
    ) throws -> AIAgentApplyResult {
        try applyCategoryEdits(
            matches.map { AIAgentCategoryEdit(match: $0, category: category) },
            permission: permission, in: context)
    }

    /// The mixed form: one confirmed batch where each edit carries its
    /// own target category — the orchestrator's validated proposals —
    /// still committed atomically under the same guards. `lookupWindow`
    /// is the effective window the matches' lookup actually scanned
    /// (`AIAgentLookupResult.window`): verified to sit inside the grant,
    /// then re-fetched instead of the grant's broader first-`scanLimit`
    /// slice, so a narrowed lookup's rows always re-resolve. Pass nil to
    /// re-resolve over the whole grant — the single-category path's
    /// original behavior.
    @discardableResult
    func applyCategoryEdits(
        _ edits: [AIAgentCategoryEdit],
        permission: AIAgentPermission,
        in context: ModelContext,
        lookupWindow: DateInterval? = nil
    ) throws -> AIAgentApplyResult {
        guard permission.access.canProposeCategoryEdits
        else { throw AIAgentError.permissionDenied }
        let window = try checked(permission.window)
        if context.hasChanges { throw AIAgentError.contextHasChanges }
        guard !edits.isEmpty else { throw AIAgentError.emptyBatch }
        // Category sanity before the row loop — the same order the
        // single-category batch checked them.
        for edit in edits {
            guard edit.category.modelContext === context,
                  !edit.category.isArchived
            else { throw AIAgentError.invalidCategory }
        }

        // Re-resolve targets through the effective lookup window — the
        // grant itself, or the narrowed interval verified inside it —
        // keeping the same bounded slice semantics the lookup used.
        let scanWindow = try narrowed(lookupWindow, within: window)
        let fetched = try fetchWindow(scanWindow, in: context)
        let rowsByID = Dictionary(
            fetched.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })

        var seen = Set<UUID>()
        var resolved: [(row: LedgerTransaction, category: LedgerCategory)] = []
        resolved.reserveCapacity(edits.count)
        for edit in edits {
            let snapshot = edit.match.original
            let category = edit.category
            guard seen.insert(snapshot.id).inserted
            else { throw AIAgentError.duplicateTransaction }
            guard window.contains(snapshot.date)
            else { throw AIAgentError.rowOutsideWindow }
            guard let row = rowsByID[snapshot.id], snapshot.matches(row)
            else { throw AIAgentError.staleTransaction }
            guard Self.canEditCategory(of: row)
            else { throw AIAgentError.transactionNotEligible }
            guard category.kind == Self.categoryKind(of: row.kind)
            else { throw AIAgentError.invalidCategory }
            // Re-categorizing a pending-review row onto the category it
            // already carries is a real edit — it confirms the
            // classification. Only a clean same-category row is a no-op.
            let noOp = row.category?.id == category.id && !row.needsReview
            guard !noOp else { throw AIAgentError.noOpEdit }
            resolved.append((row, category))
        }

        for (row, category) in resolved {
            row.category = category
            row.needsReview = false
            row.updatedAt = .now
        }
        try commit(context)
        return AIAgentApplyResult(appliedCount: resolved.count)
    }

    // MARK: - Row semantics

    /// The provenance bucket a row falls in — manual rows carry no
    /// marker; anything unrecognized counts as a generic import.
    nonisolated static func source(of row: LedgerTransaction) -> AIAgentSource {
        guard let marker = row.externalSource, !marker.isEmpty
        else { return .manual }
        switch marker {
        case WalletSyncEngine.externalSource: return .wallet
        case CSVImportDeduper.externalSource: return .csv
        default: return .otherImported
        }
    }

    /// `TransactionListScope.unclassified` semantics: non-transfer rows
    /// missing a category OR still flagged `needsReview`.
    nonisolated static func isUnclassified(_ row: LedgerTransaction) -> Bool {
        row.kind != .transfer && (row.category == nil || row.needsReview)
    }

    /// The apply's row-level rule — also safe for a UI to pre-check:
    /// a plain, unlinked income or expense; never a transfer, never
    /// rent-linked. The service still re-validates on apply.
    nonisolated static func canEditCategory(of row: LedgerTransaction) -> Bool {
        (row.kind == .income || row.kind == .expense)
            && row.rentalLease == nil
            && row.rentalPeriod == nil
            && row.toAccount == nil
    }

    /// The same rule read off a lookup snapshot — the preview and the
    /// proposal validator mark proposal-eligible rows without touching
    /// the live row.
    nonisolated static func canEditCategory(of snapshot: BillSplitOriginal) -> Bool {
        (snapshot.kind == .income || snapshot.kind == .expense)
            && snapshot.rentalLeaseID == nil
            && snapshot.rentalPeriod == nil
            && snapshot.toAccountID == nil
    }

    /// The category kind a transaction kind accepts — transfers have
    /// none (they are never editable here anyway).
    nonisolated static func categoryKind(of kind: TransactionKind) -> CategoryKind? {
        switch kind {
        case .income: return .income
        case .expense: return .expense
        case .transfer: return nil
        }
    }

    // MARK: - Internals

    /// The newest `scanLimit` rows inside `interval`, date-descending —
    /// the bounded slice both entry points share. Never the whole table.
    private func fetchWindow(
        _ interval: DateInterval, in context: ModelContext
    ) throws -> [LedgerTransaction] {
        let start = interval.start, end = interval.end
        var descriptor = FetchDescriptor<LedgerTransaction>(
            predicate: #Predicate { $0.date >= start && $0.date < end },
            sortBy: [SortDescriptor(\LedgerTransaction.date, order: .reverse)])
        descriptor.fetchLimit = max(0, scanLimit)
        return try context.fetch(descriptor)
    }

    /// The granted window, bounded — anything wider than ~3 months is
    /// refused rather than silently clipped.
    private func checked(_ window: DateInterval) throws -> DateInterval {
        guard window.duration <= Self.maxWindow
        else { throw AIAgentError.windowTooWide }
        return window
    }

    /// The effective scan window: the grant itself, or the query's
    /// interval when it stays strictly inside it.
    private func narrowed(
        _ interval: DateInterval?, within window: DateInterval
    ) throws -> DateInterval {
        guard let interval else { return window }
        guard interval.start >= window.start, interval.end <= window.end
        else { throw AIAgentError.queryOutsideWindow }
        return interval
    }

    /// In-memory filter pass — every axis of the typed query ANDed.
    private static func matches(
        _ row: LedgerTransaction,
        query: AIAgentLookupQuery,
        folded: TransactionListSearch.NormalizedQuery
    ) -> Bool {
        if let kind = query.kind, row.kind != kind { return false }
        if let source = query.source, self.source(of: row) != source {
            return false
        }
        if query.unclassifiedOnly && !isUnclassified(row) { return false }
        if let min = query.minAmount, row.amount < min { return false }
        if let max = query.maxAmount, row.amount > max { return false }
        guard !folded.normalized.isEmpty else { return true }
        if let digits = folded.digits {
            return String(row.amount).contains(digits)
        }
        return [row.note, row.category?.name, row.account?.name,
                row.toAccount?.name, row.business?.name]
            .compactMap { $0 }
            .map { TransactionListSearch.normalize($0) }
            .contains { $0.contains(folded.normalized) }
    }

    /// One hit: the displayable preview plus the local-only precondition
    /// token — the same full-state fingerprint `BillSplitOriginal`
    /// captures, so apply re-verifies every mutable field before writing.
    private static func makeMatch(
        _ row: LedgerTransaction
    ) -> AIAgentLookupMatch {
        AIAgentLookupMatch(
            preview: AIAgentTransactionPreview(
                kind: row.kind,
                amount: row.amount,
                date: row.date,
                note: row.note,
                source: source(of: row),
                needsReview: row.needsReview,
                unclassified: isUnclassified(row),
                accountName: row.account?.name,
                accountKind: row.account?.kind,
                toAccountName: row.toAccount?.name,
                categoryName: row.category?.name,
                businessName: row.business?.name),
            original: BillSplitOriginal(of: row))
    }

    /// The single commit. A failed save rolls back only this
    /// operation's writes — the context entered clean, so no
    /// pre-existing edits are at risk — and the error is never
    /// swallowed.
    private func commit(_ context: ModelContext) throws {
        do {
            try saveAndCheck(context)
        } catch {
            context.rollback()
            throw AIAgentError.saveFailed(error)
        }
    }
}
