import Foundation
import SwiftData
import FinanceCore

/// One friend sharing a bill — either an existing personal receivable
/// account or a new person the service creates inside the same save.
enum BillSplitParticipant {
    /// An active `.receivable` account with `business == nil` — personal
    /// clients only.
    case existing(Account)
    /// A person name. Trimmed on use; an empty name fails validation and
    /// a name folding to an existing personal receivable binds to that
    /// account instead of creating a duplicate.
    case newPerson(String)
}

/// The mutable state of a `LedgerTransaction` captured when a split or
/// repayment confirmation was displayed. The service re-checks every
/// field before mutating, so a stale confirm — or a repeated submission
/// after the first one already changed the row — fails instead of
/// applying twice. Never captures provenance: identity fields like
/// `externalID` are verified for equality, never rewritten.
struct BillSplitOriginal: Equatable, Sendable {
    var id: UUID
    var kind: TransactionKind
    var amount: Int64
    var date: Date
    var note: String
    var accountID: UUID?
    var toAccountID: UUID?
    var categoryID: UUID?
    var businessID: UUID?
    var rentalLeaseID: UUID?
    var rentalPeriod: Date?
    var needsReview: Bool
    var externalSource: String?
    var externalID: String?
    var updatedAt: Date

    /// Snapshots `transaction` as it is right now.
    init(of transaction: LedgerTransaction) {
        id = transaction.id
        kind = transaction.kind
        amount = transaction.amount
        date = transaction.date
        note = transaction.note
        accountID = transaction.account?.id
        toAccountID = transaction.toAccount?.id
        categoryID = transaction.category?.id
        businessID = transaction.business?.id
        rentalLeaseID = transaction.rentalLease?.id
        rentalPeriod = transaction.rentalPeriod
        needsReview = transaction.needsReview
        externalSource = transaction.externalSource
        externalID = transaction.externalID
        updatedAt = transaction.updatedAt
    }

    /// True when `transaction` is still exactly the snapshotted row.
    func matches(_ transaction: LedgerTransaction) -> Bool {
        transaction.id == id
            && transaction.kind == kind
            && transaction.amount == amount
            && transaction.date == date
            && transaction.note == note
            && transaction.account?.id == accountID
            && transaction.toAccount?.id == toAccountID
            && transaction.category?.id == categoryID
            && transaction.business?.id == businessID
            && transaction.rentalLease?.id == rentalLeaseID
            && transaction.rentalPeriod == rentalPeriod
            && transaction.needsReview == needsReview
            && transaction.externalSource == externalSource
            && transaction.externalID == externalID
            && transaction.updatedAt == updatedAt
    }
}

/// What one split posted: the personal-share expense (created or shrunk
/// in place) plus one `payer -> receivable` transfer advance per friend,
/// in participant order.
struct BillSplitResult {
    /// The personal-share expense — its amount is `plan.ownShare`. For
    /// `splitExistingExpense` this is the original row, mutated.
    var expense: LedgerTransaction
    /// One `ReceivableActions.advance` row per participant, same order.
    /// Transfers carry no category, no business and no import provenance.
    var advances: [LedgerTransaction]
    /// The receivable each advance landed on — same order as `advances`.
    var receivables: [Account]
    /// Subset of `receivables` this call created (`newPerson` entries
    /// whose name matched no existing personal receivable).
    var createdAccounts: [Account]
    /// The applied equal-split plan.
    var plan: BillSplit.Plan
}

/// Every validation failure the bill-split and assign-repayment flows
/// can produce — each case carries a Vietnamese message the UI can show
/// verbatim.
enum BillSplitError: LocalizedError {
    /// Bill total must be a positive đồng magnitude.
    case nonPositiveTotal
    /// Fewer than two people to split between.
    case tooFewParticipants
    /// The party is larger than `BillSplit.maxParticipants`.
    case tooManyParticipants
    /// `total < participants` would produce a zero share.
    case shareWouldBeZero
    /// The payer cannot fund advances (wrong kind or archived).
    case invalidPayer
    /// A `newPerson` name is empty after trimming.
    case emptyParticipantName
    /// Two participants resolved to the same receivable account.
    case duplicateParticipant
    /// An `existing` participant is not an active personal receivable,
    /// or lives on another context.
    case invalidParticipant
    /// The supplied category is archived, wrong kind or from another
    /// context — nil is always fine (the row keeps or gains no
    /// category).
    case invalidCategory
    /// The row cannot be split / assigned — wrong kind, business- or
    /// rent-linked, missing account, or on another context.
    case transactionNotEligible
    /// The row changed since the confirmation snapshot was taken —
    /// includes a repeated submission of an already-applied split.
    case staleTransaction
    /// The context already holds unsaved writes; a rollback on failure
    /// would eat them, so the operation refuses to start.
    case contextHasChanges
    /// The assign-repayment target is not an active personal receivable.
    case invalidReceivable
    /// The recorded income is more than the client still owes — the
    /// assign flow never creates prepaid credit.
    case repaymentExceedsOutstanding
    /// The single commit failed; every operation write was rolled back.
    case saveFailed(any Error)

    var errorDescription: String? {
        switch self {
        case .nonPositiveTotal:
            return "Tổng hoá đơn phải lớn hơn 0."
        case .tooFewParticipants:
            return "Chia bill cần ít nhất 2 người (gồm bạn)."
        case .tooManyParticipants:
            return "Số người chia quá lớn (tối đa \(BillSplit.maxParticipants))."
        case .shareWouldBeZero:
            return "Số tiền quá nhỏ để chia đều — mỗi người phải được ít nhất 1 ₫."
        case .invalidPayer:
            return "Tài khoản trả không hợp lệ — chọn tiền mặt, ngân hàng, ví điện tử hoặc thẻ tín dụng."
        case .emptyParticipantName:
            return "Tên người chia không được để trống."
        case .duplicateParticipant:
            return "Hai người chia trỏ về cùng một tài khoản phải thu."
        case .invalidParticipant:
            return "Người chia phải là một tài khoản phải thu cá nhân còn hoạt động."
        case .invalidCategory:
            return "Danh mục không hợp lệ — hãy chọn một danh mục chi."
        case .transactionNotEligible:
            return "Giao dịch này không đủ điều kiện — chỉ khoản chi/thu cá nhân mới dùng được."
        case .staleTransaction:
            return "Giao dịch đã thay đổi — hãy mở lại màn hình xác nhận."
        case .contextHasChanges:
            return "Có thay đổi chưa lưu — hãy lưu hoặc huỷ trước khi chia bill."
        case .invalidReceivable:
            return "Khoản phải thu không hợp lệ — chọn một khách cá nhân còn hoạt động."
        case .repaymentExceedsOutstanding:
            return "Số tiền hoàn vượt quá khoản khách đang nợ."
        case .saveFailed(let error):
            return "Không lưu được: \(error.localizedDescription)"
        }
    }
}

extension BillSplitError: Equatable {
    /// Case equality — two `saveFailed`s compare equal regardless of the
    /// wrapped error, so tests can match the specific case.
    static func == (lhs: BillSplitError, rhs: BillSplitError) -> Bool {
        switch (lhs, rhs) {
        case (.nonPositiveTotal, .nonPositiveTotal),
             (.tooFewParticipants, .tooFewParticipants),
             (.tooManyParticipants, .tooManyParticipants),
             (.shareWouldBeZero, .shareWouldBeZero),
             (.invalidPayer, .invalidPayer),
             (.emptyParticipantName, .emptyParticipantName),
             (.duplicateParticipant, .duplicateParticipant),
             (.invalidParticipant, .invalidParticipant),
             (.invalidCategory, .invalidCategory),
             (.transactionNotEligible, .transactionNotEligible),
             (.staleTransaction, .staleTransaction),
             (.contextHasChanges, .contextHasChanges),
             (.invalidReceivable, .invalidReceivable),
             (.repaymentExceedsOutstanding, .repaymentExceedsOutstanding),
             (.saveFailed, .saveFailed):
            return true
        default:
            return false
        }
    }
}

/// Posts "chia bill" splits and receivable-repayment assignments.
///
/// Every entry point follows the same discipline: validate everything
/// first (including a `BillSplitOriginal` precondition where a row is
/// mutated in place), then write — new participant accounts, the
/// expense row and the advance transfers land in one `saveAndCheck`
/// commit through the container's `LedgerBalanceStore`. A failure
/// anywhere before the save leaves the context untouched; a failed save
/// rolls back only this operation's writes — safe because the service
/// refuses to run on a context that already holds pending edits.
@MainActor
struct BillSplitService {

    /// Commit seam — `LedgerBalanceStore.saveAndCheck` in production so
    /// the fingerprint check runs inline after the save; tests inject a
    /// thrower to prove a failed commit leaves no partial writes.
    var saveAndCheck: @MainActor (ModelContext) throws -> Void

    init(saveAndCheck: (@MainActor (ModelContext) throws -> Void)? = nil) {
        self.saveAndCheck = saveAndCheck ?? { context in
            try LedgerBalanceStores.shared(for: context.container)
                .saveAndCheck(context)
        }
    }

    // MARK: - New bill

    /// Posts a fresh split: one `.expense` for the payer's own share and
    /// one `.transfer` advance per friend onto their personal receivable
    /// account — `payer` is debited exactly `total` across the rows.
    ///
    /// `participants` is the friends list (self excluded); `category`
    /// may be nil for an unclassified expense; `note` is trimmed and
    /// shared by every posted row so the group reads as one bill.
    @discardableResult
    func splitNewBill(
        total: Int64,
        payer: Account,
        date: Date,
        category: LedgerCategory?,
        note: String,
        participants: [BillSplitParticipant],
        in context: ModelContext
    ) throws -> BillSplitResult {
        try requireClean(context)
        let plan = try plan(total: total, friends: participants.count)
        try requirePayer(payer, in: context)
        try requireExpenseCategory(category, in: context)
        let resolved = try resolveParticipants(participants, in: context)

        let trimmedNote = note.trimmingCharacters(in: .whitespacesAndNewlines)
        let expense = LedgerTransaction(
            kind: .expense, amount: plan.ownShare, date: date,
            note: trimmedNote, account: payer, category: category)
        expense.updatedAt = .now
        let advances = makeAdvances(
            plan: plan, payer: payer, date: date, note: trimmedNote,
            receivables: resolved.receivables)

        for account in resolved.created { context.insert(account) }
        context.insert(expense)
        for advance in advances { context.insert(advance) }
        try commit(context)
        return BillSplitResult(
            expense: expense, advances: advances,
            receivables: resolved.receivables,
            createdAccounts: resolved.created, plan: plan)
    }

    // MARK: - Existing expense

    /// Splits an already-recorded personal expense **in place**. The row
    /// keeps its id, `externalSource`/`externalID` and every other bit
    /// of provenance, its date, its payer and its note — only the amount
    /// shrinks to the payer's own share, an optional expense `category`
    /// is applied, `needsReview` clears and `updatedAt` is stamped.
    /// Friends' shares become `payer -> receivable` transfer advances on
    /// the same date.
    ///
    /// `expected` must be the snapshot taken when the confirmation was
    /// shown; a mismatch — including a repeated submission — fails with
    /// `.staleTransaction` and writes nothing.
    @discardableResult
    func splitExistingExpense(
        _ transaction: LedgerTransaction,
        expected: BillSplitOriginal,
        category: LedgerCategory?,
        participants: [BillSplitParticipant],
        in context: ModelContext
    ) throws -> BillSplitResult {
        try requireClean(context)
        let payer = try requireSplittableExpense(transaction, in: context)
        guard expected.matches(transaction)
        else { throw BillSplitError.staleTransaction }
        let plan = try plan(total: transaction.amount, friends: participants.count)
        try requireExpenseCategory(category, in: context)
        let resolved = try resolveParticipants(participants, in: context)

        let advances = makeAdvances(
            plan: plan, payer: payer, date: transaction.date,
            note: transaction.note, receivables: resolved.receivables)

        for account in resolved.created { context.insert(account) }
        for advance in advances { context.insert(advance) }
        if let category { transaction.category = category }
        transaction.amount = plan.ownShare
        transaction.needsReview = false
        transaction.updatedAt = .now
        try commit(context)
        return BillSplitResult(
            expense: transaction, advances: advances,
            receivables: resolved.receivables,
            createdAccounts: resolved.created, plan: plan)
    }

    // MARK: - Assign repayment

    /// Turns an already-recorded personal income — typically a synced
    /// bank row the inbox never classified — into a receivable
    /// repayment. The row is converted **in place** to a
    /// `receivable -> original receiver` transfer through
    /// `WalletSyncTransfer.convert`: id, `externalSource`/`externalID`,
    /// amount, date and note all survive; category, business and
    /// `needsReview` clear and `updatedAt` is stamped.
    ///
    /// Stricter than the manual repayment sheet: the income amount must
    /// not exceed what the client still owes, so this flow can never
    /// create prepaid credit. `expected` guards stale and repeated
    /// submissions.
    @discardableResult
    func assignRepayment(
        _ transaction: LedgerTransaction,
        expected: BillSplitOriginal,
        to receivable: Account,
        in context: ModelContext
    ) throws -> LedgerTransaction {
        try requireClean(context)
        let receiver = try requireAssignableIncome(transaction, in: context)
        guard expected.matches(transaction)
        else { throw BillSplitError.staleTransaction }
        try requireReceivable(receivable, in: context)
        guard receiver.id != receivable.id
        else { throw BillSplitError.transactionNotEligible }
        let outstanding = LedgerBalanceStores.shared(for: context.container)
            .receivableSnapshot(of: receivable).outstanding
        guard transaction.amount <= outstanding
        else { throw BillSplitError.repaymentExceedsOutstanding }

        // Preconditions above make a refusal impossible — convert only
        // turns down transfers and same-account pairs.
        guard WalletSyncTransfer.convert(transaction, with: receivable)
        else { throw BillSplitError.transactionNotEligible }
        try commit(context)
        return transaction
    }

    // MARK: - Validation

    /// Wraps `BillSplit.plan` so package validation errors surface as
    /// the app's own localized error type.
    private func plan(total: Int64, friends: Int) throws -> BillSplit.Plan {
        do {
            return try BillSplit.plan(total: total, participants: friends + 1)
        } catch let error as BillSplit.Error {
            switch error {
            case .nonPositiveTotal: throw BillSplitError.nonPositiveTotal
            case .tooFewParticipants: throw BillSplitError.tooFewParticipants
            case .tooManyParticipants: throw BillSplitError.tooManyParticipants
            case .shareWouldBeZero: throw BillSplitError.shareWouldBeZero
            }
        }
    }

    /// Refuses to run on a context with pending edits: a rollback after
    /// a failed save would eat the user's unrelated pending changes too.
    private func requireClean(_ context: ModelContext) throws {
        if context.hasChanges { throw BillSplitError.contextHasChanges }
    }

    /// `payer` funds the expense and every advance — it must satisfy the
    /// receivable advance-payer rule and live on this context.
    private func requirePayer(_ payer: Account, in context: ModelContext) throws {
        guard payer.modelContext === context,
              ReceivableActions.canAdvance(from: payer)
        else { throw BillSplitError.invalidPayer }
    }

    private func requireExpenseCategory(
        _ category: LedgerCategory?, in context: ModelContext
    ) throws {
        guard let category else { return }
        guard category.modelContext === context,
              category.kind == .expense, !category.isArchived
        else { throw BillSplitError.invalidCategory }
    }

    /// Eligible split source: a personal, unlinked expense sitting on an
    /// account that can fund advances — returned for the caller's
    /// advances. Business rows, rent rows, transfers and system-linked
    /// rows all belong to their own features and are never mutated here.
    private func requireSplittableExpense(
        _ transaction: LedgerTransaction, in context: ModelContext
    ) throws -> Account {
        guard transaction.modelContext === context,
              transaction.kind == .expense,
              transaction.business == nil,
              transaction.rentalLease == nil,
              transaction.rentalPeriod == nil,
              transaction.toAccount == nil,
              let payer = transaction.account,
              ReceivableActions.canAdvance(from: payer)
        else { throw BillSplitError.transactionNotEligible }
        return payer
    }

    /// Eligible repayment source: a personal, unlinked income landing on
    /// a valid repayment receiver — returned for the caller's check —
    /// including synced rows still carrying their `externalID`, which
    /// the conversion preserves.
    private func requireAssignableIncome(
        _ transaction: LedgerTransaction, in context: ModelContext
    ) throws -> Account {
        guard transaction.modelContext === context,
              transaction.kind == .income,
              transaction.business == nil,
              transaction.rentalLease == nil,
              transaction.rentalPeriod == nil,
              transaction.toAccount == nil,
              let receiver = transaction.account,
              ReceivableActions.canReceive(into: receiver)
        else { throw BillSplitError.transactionNotEligible }
        return receiver
    }

    /// The receivable a repayment is assigned to — an active personal
    /// client account on this context.
    private func requireReceivable(
        _ receivable: Account, in context: ModelContext
    ) throws {
        guard receivable.modelContext === context,
              receivable.kind == .receivable,
              receivable.business == nil,
              !receivable.isArchived
        else { throw BillSplitError.invalidReceivable }
    }

    /// Resolves every participant to a distinct personal receivable.
    /// `existing` accounts are validated; `newPerson` names are trimmed,
    /// folded and either bound to a like-named active personal
    /// receivable or built as a new account — nothing is inserted yet,
    /// so a late failure still leaves the context untouched.
    private func resolveParticipants(
        _ participants: [BillSplitParticipant],
        in context: ModelContext
    ) throws -> (receivables: [Account], created: [Account]) {
        let accounts = (try? context.fetch(FetchDescriptor<Account>())) ?? []
        // Folded-name index of active personal receivables — a new
        // person named like an existing client binds to that account
        // instead of duplicating it.
        var byFoldedName: [String: Account] = [:]
        for account in accounts where account.kind == .receivable
            && account.business == nil && !account.isArchived {
            let key = SettingsNameNormalizer.fold(account.name)
            if byFoldedName[key] == nil { byFoldedName[key] = account }
        }

        var receivables: [Account] = []
        var created: [Account] = []
        var nextSort = (accounts.map(\.sortOrder).max() ?? -1) + 1
        var seen = Set<UUID>()
        for participant in participants {
            let receivable: Account
            switch participant {
            case .existing(let account):
                guard account.modelContext === context,
                      account.kind == .receivable,
                      account.business == nil,
                      !account.isArchived
                else { throw BillSplitError.invalidParticipant }
                receivable = account
            case .newPerson(let raw):
                let name = raw.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !name.isEmpty
                else { throw BillSplitError.emptyParticipantName }
                let key = SettingsNameNormalizer.fold(name)
                if let existing = byFoldedName[key] {
                    receivable = existing
                } else {
                    receivable = Account(
                        name: name, kind: .receivable, sortOrder: nextSort)
                    nextSort += 1
                    created.append(receivable)
                    byFoldedName[key] = receivable
                }
            }
            guard seen.insert(receivable.id).inserted
            else { throw BillSplitError.duplicateParticipant }
            receivables.append(receivable)
        }
        return (receivables, created)
    }

    /// One `ReceivableActions.advance` per friend — same payer and date
    /// as the bill, the friend's share, the shared note, and no
    /// category, business or import provenance.
    private func makeAdvances(
        plan: BillSplit.Plan,
        payer: Account,
        date: Date,
        note: String,
        receivables: [Account]
    ) -> [LedgerTransaction] {
        receivables.enumerated().map { index, receivable in
            ReceivableActions.advance(
                receivable: receivable, from: payer,
                amount: plan.share(at: index + 1),
                date: date, note: note)
        }
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
            throw BillSplitError.saveFailed(error)
        }
    }
}
