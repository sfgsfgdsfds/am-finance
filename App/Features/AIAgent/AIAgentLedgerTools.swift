import Foundation
import SwiftData
import FinanceCore

/// One user-confirmed action inside a mixed `apply` batch — the chat
/// agent's whole write vocabulary. Existing rows are addressed only
/// through lookup-issued matches, so nothing the tools never surfaced
/// can be touched; `add` stands alone because a brand-new row has no
/// match to mint.
enum AIAgentLedgerAction {
    /// Move an existing row to a new category.
    case setCategory(match: AIAgentLookupMatch, category: LedgerCategory)
    /// Insert a new row from a validated draft — an ordinary manual row
    /// (no external provenance, `needsReview == false`). The permission
    /// window does not bound where the new row may be dated.
    case add(draft: TransactionDraft)
    /// Rewrite an existing row's editable fields from a draft. Income/
    /// expense rows may move amount, date, note, source account and
    /// category; transfers only amount, date and note. Kind, business,
    /// rental links and external provenance never move.
    case edit(match: AIAgentLookupMatch, draft: TransactionDraft)
    /// Remove an existing row through the tombstone-aware delete, so an
    /// imported row never comes back on the next sync or re-import.
    case delete(match: AIAgentLookupMatch)
}

extension AIAgentLedgerAction {
    /// Whether the action carries a lookup match — everything but `add`.
    var targetsARow: Bool {
        if case .add = self { return false }
        return true
    }
}

/// What one `apply` call committed — counts per action kind plus the
/// ids of inserted rows, so the caller can point at the new entries.
struct AIAgentApplySummary: Equatable, Sendable {
    /// Rows re-categorized by `setCategory` actions.
    var categorized = 0
    /// Rows inserted by `add` actions — `insertedIDs` lists them in
    /// action order.
    var added = 0
    /// Rows rewritten in place by `edit` actions.
    var edited = 0
    /// Rows removed by `delete` actions.
    var deleted = 0
    /// Persistent ids of the `add`-inserted rows, in action order.
    var insertedIDs: [UUID] = []
}

/// What `apply(_:permission:in:lookupWindow:)` throws. A batch-level
/// failure no single action owns rides as `.batch`; a failure one
/// action caused rides as `.action` paired with that action's index in
/// the confirmed list, so the confirm UI can point at the offending
/// entry. Either way the underlying `AIAgentError` is in `reason`.
enum AIAgentApplyError: LocalizedError {
    /// Permission, window, dirty context, empty/oversized batch or the
    /// commit itself — nothing a single action caused.
    case batch(AIAgentError)
    /// The action at this index failed — nothing was written.
    case action(Int, AIAgentError)

    /// The underlying reason, whichever shape it arrived in.
    var reason: AIAgentError {
        switch self {
        case .batch(let error), .action(_, let error): return error
        }
    }

    /// The failing action's index — nil for batch-level failures.
    var actionIndex: Int? {
        switch self {
        case .action(let index, _): return index
        case .batch: return nil
        }
    }

    var errorDescription: String? { reason.errorDescription }
}

extension AIAgentApplyError: Equatable {}

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
    /// More actions than `AIAgentLedgerTools.actionLimit` in one
    /// confirmed batch.
    case tooManyActions
    /// An `add`/`edit` draft failed `TransactionDraft.validate()`, or
    /// referenced objects that are archived or live on another context.
    case invalidDraft
    /// An `edit` draft touches a field outside the allowed surface —
    /// the kind, a transfer's accounts, any category/business on a
    /// transfer, or an income/expense row's business.
    case invalidEdit

    var errorDescription: String? {
        switch self {
        case .permissionDenied:
            return "Trợ lý AI không có quyền thực hiện thao tác này."
        case .windowTooWide:
            return "Khoảng thời gian cấp phép quá rộng — tối đa 366 ngày."
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
        case .tooManyActions:
            return "Quá nhiều thao tác một lần — tối đa \(AIAgentLedgerTools.actionLimit) mục."
        case .invalidDraft:
            return "Giao dịch chưa đủ điều kiện — kiểm tra số tiền, tài khoản và danh mục."
        case .invalidEdit:
            return "Sửa không hợp lệ — loại giao dịch không đổi; chuyển khoản chỉ sửa số tiền, ngày và ghi chú."
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
             (.tooManyActions, .tooManyActions),
             (.invalidDraft, .invalidDraft),
             (.invalidEdit, .invalidEdit):
            return true
        default:
            return false
        }
    }
}

/// The local ledger tools the AM Finance AI agent is allowed to call.
///
/// Three entry points, all gated on `AIAgentPermission`:
///
/// - `lookup` — a bounded read inside the granted date window. It fetches
///   at most `scanLimit` newest rows in-window, filters in memory (text
///   folding cannot live in a fetch predicate) and returns at most
///   `resultLimit` matches newest-first with a `truncated` honesty flag.
///   Rows come back as `AIAgentLookupMatch` — a displayable preview plus
///   a local-only precondition token. Nothing is serialized or sent.
///
/// - `apply` — the single write path: a user-confirmed batch of mixed
///   `AIAgentLedgerAction`s (re-categorize, add, edit, delete).
///   Everything validates first (permission, window, clean context,
///   snapshot freshness, eligibility, drafts, no-ops), then one
///   `saveAndCheck` commit lands the whole batch; a failed commit rolls
///   back only this operation's writes. Kind, business, rental links
///   and external provenance are never touched.
///
/// - `validate` — the same preflight `apply` runs, minus the writes:
///   `AIAgentChatSession` dry-runs a proposed batch through it before
///   the confirmation card is offered.
@MainActor
struct AIAgentLedgerTools {

    /// App-controlled caps the model cannot raise — instance-overridable
    /// for tests only.
    nonisolated static let resultLimit = 50
    /// The bounded scan slice: the newest rows inside the window a
    /// single lookup inspects. Deliberately not the whole ledger.
    nonisolated static let scanLimit = 2_000
    /// The widest window a permission may grant — ~12 months.
    nonisolated static let maxWindow: TimeInterval = 366 * 86_400
    /// The most actions one confirmed `apply` batch may carry.
    nonisolated static let actionLimit = 30

    var resultLimit = Self.resultLimit
    var scanLimit = Self.scanLimit
    var actionLimit = Self.actionLimit

    /// Commit seam — `LedgerBalanceStore.saveAndCheck` in production so
    /// the fingerprint check runs inline after the save; tests inject a
    /// thrower to prove a failed commit leaves no partial writes.
    var saveAndCheck: @MainActor (ModelContext) throws -> Void

    /// The tombstone store `delete` actions record imported external ids
    /// into — `WalletSyncStateStore` in production, in-memory in tests
    /// so a deleted synced row can be proven never to re-import.
    var tombstones: any WalletSyncStateStoring

    init(
        resultLimit: Int? = nil,
        scanLimit: Int? = nil,
        actionLimit: Int? = nil,
        tombstones: (any WalletSyncStateStoring)? = nil,
        saveAndCheck: (@MainActor (ModelContext) throws -> Void)? = nil
    ) {
        if let resultLimit { self.resultLimit = resultLimit }
        if let scanLimit { self.scanLimit = scanLimit }
        if let actionLimit { self.actionLimit = actionLimit }
        self.tombstones = tombstones ?? WalletSyncStateStore()
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

    // MARK: - Apply actions (the single write path)

    /// Applies one user-confirmed batch of mixed actions atomically:
    /// re-categorizes, inserts, in-place edits and deletions in a single
    /// commit. Everything validates first — permission, window, clean
    /// context, batch size, snapshot freshness, per-action eligibility,
    /// draft sanity, no-ops — then one `saveAndCheck` lands it all.
    /// Any refusal writes nothing; a failed commit rolls the batch's
    /// writes back. Per-action failures surface as
    /// `AIAgentApplyError.action(index, reason)`; batch-level failures
    /// as `.batch(reason)`.
    ///
    /// Match-carrying actions re-resolve their row through the
    /// effective lookup window — the grant itself, or `lookupWindow`
    /// verified inside it — and must still match their
    /// `BillSplitOriginal` snapshot field by field. `add` rows are
    /// ordinary manual rows (no provenance, never pending review) and
    /// are not bound to the window.
    @discardableResult
    func apply(
        _ actions: [AIAgentLedgerAction],
        permission: AIAgentPermission,
        in context: ModelContext,
        lookupWindow: DateInterval? = nil
    ) throws -> AIAgentApplySummary {
        do {
            let resolved = try resolveBatch(
                actions, permission: permission,
                in: context, lookupWindow: lookupWindow)
            var summary = AIAgentApplySummary()
            for (index, action) in resolved.enumerated() {
                do {
                    try perform(action, into: &summary, in: context)
                } catch let error as AIAgentError {
                    // Validated actions cannot realistically fail — if
                    // one somehow does, undo the partial batch rather
                    // than leave half of it behind.
                    context.rollback()
                    throw AIAgentApplyError.action(index, error)
                }
            }
            try commit(context)
            return summary
        } catch let error as AIAgentApplyError {
            throw error
        } catch let error as AIAgentError {
            throw AIAgentApplyError.batch(error)
        }
    }

    /// Runs exactly the validation phase of `apply` — permission,
    /// window, clean context, batch size, snapshot freshness,
    /// per-action eligibility, draft sanity, no-ops — without
    /// mutating or saving anything. Throws the same
    /// `AIAgentApplyError` shape `apply` throws, so a dry-run refusal
    /// reports the same indexed reason the confirmed batch would.
    func validate(
        _ actions: [AIAgentLedgerAction],
        permission: AIAgentPermission,
        in context: ModelContext,
        lookupWindow: DateInterval? = nil
    ) throws {
        _ = try resolveBatch(
            actions, permission: permission,
            in: context, lookupWindow: lookupWindow)
    }

    /// The whole-batch validation `apply` and `validate` share —
    /// every check that must pass before any write, bound per action
    /// to its live row. Only `AIAgentApplyError` escapes: indexed
    /// `.action` for per-action failures, `.batch` for everything else.
    private func resolveBatch(
        _ actions: [AIAgentLedgerAction],
        permission: AIAgentPermission,
        in context: ModelContext,
        lookupWindow: DateInterval?
    ) throws -> [ResolvedAction] {
        do {
            guard permission.access.canProposeActions
            else { throw AIAgentError.permissionDenied }
            let window = try checked(permission.window)
            if context.hasChanges { throw AIAgentError.contextHasChanges }
            guard !actions.isEmpty else { throw AIAgentError.emptyBatch }
            guard actions.count <= actionLimit
            else { throw AIAgentError.tooManyActions }

            // Re-resolve targets through the effective lookup window —
            // the grant itself, or the narrowed interval verified
            // inside it — keeping the same bounded slice semantics the
            // lookup used.
            let scanWindow = try narrowed(lookupWindow, within: window)
            var rowsByID: [UUID: LedgerTransaction] = [:]
            if actions.contains(where: \.targetsARow) {
                rowsByID = Dictionary(
                    try fetchWindow(scanWindow, in: context)
                        .map { ($0.id, $0) },
                    uniquingKeysWith: { a, _ in a })
            }

            // Whole-batch validation before any mutation — a refusal
            // here leaves the context exactly as it entered.
            var seen = Set<UUID>()
            var resolved: [ResolvedAction] = []
            resolved.reserveCapacity(actions.count)
            for (index, action) in actions.enumerated() {
                do {
                    resolved.append(try resolve(
                        action, window: window, rowsByID: rowsByID,
                        seen: &seen, in: context))
                } catch let error as AIAgentError {
                    throw AIAgentApplyError.action(index, error)
                }
            }
            return resolved
        } catch let error as AIAgentApplyError {
            throw error
        } catch let error as AIAgentError {
            throw AIAgentApplyError.batch(error)
        }
    }

    /// A validated action bound to its live row — produced only after
    /// the whole batch checked out; `perform` mutates without
    /// re-validating.
    private enum ResolvedAction {
        case setCategory(LedgerTransaction, LedgerCategory)
        case add(TransactionDraft)
        case edit(LedgerTransaction, TransactionDraft)
        case delete(LedgerTransaction)
    }

    /// Validates one action into its bound form — no mutation. Throws
    /// the bare `AIAgentError`; the caller pairs it with the index.
    private func resolve(
        _ action: AIAgentLedgerAction,
        window: DateInterval,
        rowsByID: [UUID: LedgerTransaction],
        seen: inout Set<UUID>,
        in context: ModelContext
    ) throws -> ResolvedAction {
        switch action {
        case .setCategory(let match, let category):
            try requireLive(category, in: context)
            let row = try resolveRow(
                match, window: window, rowsByID: rowsByID, seen: &seen)
            guard Self.canEditCategory(of: row)
            else { throw AIAgentError.transactionNotEligible }
            guard category.kind == Self.categoryKind(of: row.kind)
            else { throw AIAgentError.invalidCategory }
            // Re-categorizing a pending-review row onto the category it
            // already carries is a real edit — it confirms the
            // classification. Only a clean same-category row is a no-op.
            let noOp = row.category?.id == category.id && !row.needsReview
            guard !noOp else { throw AIAgentError.noOpEdit }
            return .setCategory(row, category)

        case .add(let draft):
            try requireValidDraft(draft, in: context)
            return .add(draft)

        case .edit(let match, let draft):
            let row = try resolveRow(
                match, window: window, rowsByID: rowsByID, seen: &seen)
            // Rental-linked rows belong to the rentals flow; a
            // non-transfer row carrying a destination is malformed —
            // editing it would silently lose the link.
            guard row.rentalLease == nil, row.rentalPeriod == nil,
                  row.kind == .transfer || row.toAccount == nil
            else { throw AIAgentError.transactionNotEligible }
            try requireEditSurface(draft, for: row, in: context)
            // Re-saving identical fields on a pending-review row still
            // clears the flag — a real edit. Only a clean identical
            // draft is a no-op.
            let noOp = Self.draftEqualsRow(draft, row) && !row.needsReview
            guard !noOp else { throw AIAgentError.noOpEdit }
            return .edit(row, draft)

        case .delete(let match):
            let row = try resolveRow(
                match, window: window, rowsByID: rowsByID, seen: &seen)
            // The manual delete accepts every row; the agent stays away
            // from rental-linked rows so a month cannot silently lose
            // its rent.
            guard row.rentalLease == nil, row.rentalPeriod == nil
            else { throw AIAgentError.transactionNotEligible }
            return .delete(row)
        }
    }

    /// The live row a lookup-issued match still points at — re-verified
    /// field by field, inside the granted window, never targeted twice
    /// in one batch.
    private func resolveRow(
        _ match: AIAgentLookupMatch,
        window: DateInterval,
        rowsByID: [UUID: LedgerTransaction],
        seen: inout Set<UUID>
    ) throws -> LedgerTransaction {
        let snapshot = match.original
        guard seen.insert(snapshot.id).inserted
        else { throw AIAgentError.duplicateTransaction }
        guard window.contains(snapshot.date)
        else { throw AIAgentError.rowOutsideWindow }
        guard let row = rowsByID[snapshot.id], snapshot.matches(row)
        else { throw AIAgentError.staleTransaction }
        return row
    }

    /// A picked category must be live and on this context — the manual
    /// pickers never offer archived or foreign rows.
    private func requireLive(
        _ category: LedgerCategory, in context: ModelContext
    ) throws {
        guard category.modelContext === context, !category.isArchived
        else { throw AIAgentError.invalidCategory }
    }

    /// A picked account must be live and on this context — the manual
    /// pickers never offer archived rows.
    private func requireUsable(
        _ account: Account?, in context: ModelContext
    ) throws {
        guard let account else { return }
        guard account.modelContext === context, !account.isArchived
        else { throw AIAgentError.invalidDraft }
    }

    /// `TransactionDraft` sanity both `add` and `edit` need: the manual
    /// editor's own validation plus live, on-this-context references.
    /// A wrong-kind category maps to `.invalidCategory` like the
    /// `setCategory` path — every other missing piece is `.invalidDraft`.
    private func requireValidDraft(
        _ draft: TransactionDraft, in context: ModelContext
    ) throws {
        if let error = draft.validate().first {
            throw error == .categoryKindMismatch
                ? AIAgentError.invalidCategory : AIAgentError.invalidDraft
        }
        try requireUsable(draft.account, in: context)
        try requireUsable(draft.toAccount, in: context)
        if let business = draft.business,
           business.modelContext !== context || business.isArchived {
            throw AIAgentError.invalidDraft
        }
        if let category = draft.category {
            try requireLive(category, in: context)
        }
    }

    /// The edit surface: kind never changes; income/expense rows may
    /// move amount, date, note, source account and category (business
    /// stays as it was); transfers only amount, date and note. Field
    /// shape is checked before draft sanity so an out-of-surface change
    /// always reads as `.invalidEdit`, never as a generic draft error.
    private func requireEditSurface(
        _ draft: TransactionDraft,
        for row: LedgerTransaction,
        in context: ModelContext
    ) throws {
        guard draft.kind == row.kind
        else { throw AIAgentError.invalidEdit }
        switch row.kind {
        case .transfer:
            guard draft.account?.id == row.account?.id,
                  draft.toAccount?.id == row.toAccount?.id,
                  draft.category == nil, draft.business == nil
            else { throw AIAgentError.invalidEdit }
        case .income, .expense:
            guard draft.toAccount == nil,
                  draft.business?.id == row.business?.id
            else { throw AIAgentError.invalidEdit }
        }
        try requireValidDraft(draft, in: context)
    }

    /// Mutates one validated action — the only reachable failure is a
    /// draft the model layer turns down anyway, mapped to a draft/edit
    /// error and never swallowed.
    private func perform(
        _ action: ResolvedAction,
        into summary: inout AIAgentApplySummary,
        in context: ModelContext
    ) throws {
        switch action {
        case .setCategory(let row, let category):
            row.category = category
            row.needsReview = false
            row.updatedAt = .now
            summary.categorized += 1
        case .add(let draft):
            do {
                let row = try draft.insert(into: context)
                summary.added += 1
                summary.insertedIDs.append(row.id)
            } catch {
                throw AIAgentError.invalidDraft
            }
        case .edit(let row, let draft):
            do {
                try draft.apply(to: row)
            } catch {
                throw AIAgentError.invalidEdit
            }
            summary.edited += 1
        case .delete(let row):
            LedgerTransactionDeletion.delete(
                row, in: context, tombstones: tombstones)
            summary.deleted += 1
        }
    }

    /// Every editable field equal — the confirmed edit would change
    /// nothing.
    nonisolated static func draftEqualsRow(
        _ draft: TransactionDraft, _ row: LedgerTransaction
    ) -> Bool {
        draft.kind == row.kind
            && draft.amount == row.amount
            && draft.date == row.date
            && draft.note == row.note
            && draft.account?.id == row.account?.id
            && draft.toAccount?.id == row.toAccount?.id
            && draft.category?.id == row.category?.id
            && draft.business?.id == row.business?.id
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
