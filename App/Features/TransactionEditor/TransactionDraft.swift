import Foundation
import SwiftData
import FinanceCore

/// Mutable, view-independent state behind `TransactionEditorView`. Built
/// either from defaults (create mode) or from an existing `LedgerTransaction`
/// (edit mode), checked with `validate()`, then persisted with
/// `insert(into:)` or `apply(to:)`.
struct TransactionDraft {
    var kind: TransactionKind
    /// Positive đồng magnitude — the sign on each account comes from `LedgerMath`.
    var amount: Int64
    /// Source account: money leaves it for expense/transfer, arrives for income.
    var account: Account?
    /// Destination account — transfers only.
    var toAccount: Account?
    var category: LedgerCategory?
    /// nil means personal ("Cá nhân"); transfers never carry a business.
    var business: Business?
    var date: Date
    var note: String

    /// Create mode: a blank draft of `kind`, dated now, optionally with an
    /// account preselected.
    init(kind: TransactionKind = .expense, account: Account? = nil) {
        self.kind = kind
        self.amount = 0
        self.account = account
        self.date = .now
        self.note = ""
    }

    /// Edit mode: every field pre-filled from an existing transaction.
    init(transaction: LedgerTransaction) {
        self.init(kind: transaction.kind, account: transaction.account)
        self.amount = transaction.amount
        self.toAccount = transaction.toAccount
        self.category = transaction.category
        self.business = transaction.business
        self.date = transaction.date
        self.note = transaction.note
    }

    /// The category kind a transaction kind pairs with; transfers use none.
    static func categoryKind(for kind: TransactionKind) -> CategoryKind? {
        switch kind {
        case .expense: return .expense
        case .income: return .income
        case .transfer: return nil
        }
    }

    /// Switch the draft's kind, dropping fields that no longer apply:
    /// transfers carry neither category nor business, expense/income carry no
    /// destination account, and a category of the wrong kind is cleared.
    mutating func setKind(_ newKind: TransactionKind) {
        guard newKind != kind else { return }
        kind = newKind
        if newKind == .transfer {
            category = nil
            business = nil
        } else {
            toAccount = nil
            if let category, category.kind != Self.categoryKind(for: newKind) {
                self.category = nil
            }
        }
    }

    /// Everything the form must satisfy before saving: a positive amount, a
    /// source account, a transfer destination that differs from the source,
    /// and a category matching the transaction kind.
    func validate() -> [TransactionDraftError] {
        var errors: [TransactionDraftError] = []
        if amount <= 0 { errors.append(.missingAmount) }
        if account == nil { errors.append(.missingAccount) }
        if kind == .transfer {
            if toAccount == nil {
                errors.append(.missingDestination)
            } else if toAccount?.id == account?.id {
                errors.append(.sameSourceAndDestination)
            }
        } else if let category, category.kind != Self.categoryKind(for: kind) {
            errors.append(.categoryKindMismatch)
        }
        return errors
    }

    var isValid: Bool { validate().isEmpty }

    /// Create a new transaction and insert it into the context. Throws the
    /// first validation error when the draft is incomplete.
    @discardableResult
    func insert(into context: ModelContext) throws -> LedgerTransaction {
        if let error = validate().first { throw error }
        let transaction = LedgerTransaction(
            kind: kind,
            amount: amount,
            date: date,
            note: note,
            account: account,
            toAccount: normalizedToAccount,
            category: normalizedCategory,
            business: normalizedBusiness,
            needsReview: false
        )
        transaction.updatedAt = .now
        context.insert(transaction)
        return transaction
    }

    /// Write the draft back onto an existing transaction. Clears
    /// `needsReview` and stamps `updatedAt`.
    func apply(to transaction: LedgerTransaction) throws {
        if let error = validate().first { throw error }
        transaction.kind = kind
        transaction.amount = amount
        transaction.date = date
        transaction.note = note
        transaction.account = account
        transaction.toAccount = normalizedToAccount
        transaction.category = normalizedCategory
        transaction.business = normalizedBusiness
        transaction.needsReview = false
        transaction.updatedAt = .now
    }

    private var normalizedToAccount: Account? { kind == .transfer ? toAccount : nil }
    private var normalizedCategory: LedgerCategory? { kind == .transfer ? nil : category }
    private var normalizedBusiness: Business? { kind == .transfer ? nil : business }
}

/// Why a `TransactionDraft` cannot be saved yet.
enum TransactionDraftError: Error, Equatable {
    /// Amount is zero or negative — đồng magnitudes must be positive.
    case missingAmount
    /// No source account picked.
    case missingAccount
    /// A transfer with no destination account.
    case missingDestination
    /// A transfer whose destination is also its source.
    case sameSourceAndDestination
    /// A category whose kind does not match the transaction kind.
    case categoryKindMismatch
}
