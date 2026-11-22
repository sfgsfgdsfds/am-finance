import Foundation
import FinanceCore

/// The optional predicates the user can combine on the transactions list.
/// `nil` / `.any` on an axis means "not filtering on it". Pure matching on
/// `TransactionListRow` so the logic is testable without a ModelContext.
struct TransactionListFilter: Equatable {

    /// Which income stream to keep: `.personal` is transactions with no
    /// business attached ("Cá nhân").
    enum BusinessFilter: Equatable {
        case any
        case personal
        case business(UUID)
    }

    var kind: TransactionKind?
    /// Matches the source account, and for transfers the destination too.
    var accountID: UUID?
    var categoryID: UUID?
    var business: BusinessFilter = .any
    var onlyNeedsReview = false

    init(
        kind: TransactionKind? = nil,
        accountID: UUID? = nil,
        categoryID: UUID? = nil,
        business: BusinessFilter = .any,
        onlyNeedsReview: Bool = false
    ) {
        self.kind = kind
        self.accountID = accountID
        self.categoryID = categoryID
        self.business = business
        self.onlyNeedsReview = onlyNeedsReview
    }

    var isActive: Bool {
        kind != nil || accountID != nil || categoryID != nil
            || business != .any || onlyNeedsReview
    }

    mutating func reset() {
        self = TransactionListFilter()
    }

    /// A row stays when every active axis matches (logical AND).
    func matches(_ row: TransactionListRow) -> Bool {
        if let kind, row.kind != kind { return false }
        if let accountID,
           row.accountID != accountID && row.toAccountID != accountID {
            return false
        }
        if let categoryID, row.categoryID != categoryID { return false }
        switch business {
        case .any:
            break
        case .personal:
            if row.businessID != nil { return false }
        case .business(let id):
            if row.businessID != id { return false }
        }
        if onlyNeedsReview && !row.needsReview { return false }
        return true
    }
}
