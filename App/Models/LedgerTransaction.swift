import Foundation
import SwiftData
import FinanceCore

/// One movement of money. `amount` is always a positive magnitude; the sign
/// applied to each account comes from `LedgerMath` and the account's role.
/// Named `LedgerTransaction` because `Transaction` clashes with SwiftUI.
@Model
final class LedgerTransaction {
    var id: UUID = UUID()
    var kindRaw: String = TransactionKind.expense.rawValue
    var amount: Int64 = 0
    var date: Date = Date.now
    var note: String = ""

    /// Source account: where money leaves (expense, transfer) or where it
    /// arrives (income). See `LedgerMath` for the sign convention.
    var account: Account?
    /// Destination account — transfers only.
    var toAccount: Account?
    var category: LedgerCategory?
    /// The income stream this belongs to; nil means personal.
    var business: Business?

    /// The rental lease this income row collects rent for; nil on every
    /// other transaction.
    var rentalLease: RentalLease?
    /// First day of the month this rent payment covers; nil when the row is
    /// not rent (including lease extras like utilities, which stay linked
    /// to the lease but never count toward a month's rent).
    var rentalPeriod: Date?

    var needsReview: Bool = false

    // External link fields (bank sync, imports).
    var externalSource: String?
    var externalID: String?

    var createdAt: Date = Date.now
    var updatedAt: Date = Date.now

    init(
        id: UUID = UUID(),
        kind: TransactionKind,
        amount: Int64,
        date: Date = .now,
        note: String = "",
        account: Account? = nil,
        toAccount: Account? = nil,
        category: LedgerCategory? = nil,
        business: Business? = nil,
        rentalLease: RentalLease? = nil,
        rentalPeriod: Date? = nil,
        needsReview: Bool = false
    ) {
        self.id = id
        self.kindRaw = kind.rawValue
        self.amount = amount
        self.date = date
        self.note = note
        self.account = account
        self.toAccount = toAccount
        self.category = category
        self.business = business
        self.rentalLease = rentalLease
        self.rentalPeriod = rentalPeriod
        self.needsReview = needsReview
    }

    var kind: TransactionKind {
        get { TransactionKind(rawValue: kindRaw) ?? .expense }
        set { kindRaw = newValue.rawValue }
    }
}
