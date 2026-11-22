import Foundation
import SwiftData
import FinanceCore

/// An account in the ledger. Balances are signed — positive is money owned,
/// negative is money owed (see `LedgerMath`).
@Model
final class Account {
    var id: UUID = UUID()
    var name: String = ""
    var kindRaw: String = AccountKind.cash.rawValue
    var openingBalance: Int64 = 0
    var icon: String = ""
    var colorHex: String = ""
    var note: String = ""
    var sortOrder: Int = 0
    var isArchived: Bool = false
    var createdAt: Date = Date.now

    // Credit-card fields (kind == .creditCard).
    var creditLimit: Int64?
    var statementDay: Int?
    var graceDays: Int?

    // Loan fields (kind == .loan).
    // loanMethodRaw is "equalPrincipal" or "annuity".
    var loanPrincipal: Int64?
    var loanAnnualRatePercent: Double?
    var loanTermMonths: Int?
    var loanStartDate: Date?
    var loanPaymentDay: Int?
    var loanMethodRaw: String?

    // External bank/linking fields.
    var externalSource: String?
    var externalAccountID: String?

    /// The business a receivable account belongs to (kind == .receivable) —
    /// nil on every other kind and on personal clients.
    var business: Business?

    /// Transactions where this account is the source (see `LedgerMath`).
    @Relationship(deleteRule: .nullify, inverse: \LedgerTransaction.account)
    var transactions: [LedgerTransaction]? = []

    /// Transfers where this account is the destination.
    @Relationship(deleteRule: .nullify, inverse: \LedgerTransaction.toAccount)
    var incomingTransfers: [LedgerTransaction]? = []

    /// Rate changes for a loan account (see `LoanRateChange`). `.nullify`
    /// keeps the schema CloudKit-compatible — cascade deletes can't sync —
    /// so rows are deleted explicitly.
    @Relationship(deleteRule: .nullify, inverse: \LoanRateChange.account)
    var loanRateChanges: [LoanRateChange]? = []

    /// Recurring rules drawing from this account.
    @Relationship(deleteRule: .nullify, inverse: \RecurringRule.account)
    var recurringRules: [RecurringRule]? = []

    /// Recurring transfer rules paying into this account.
    @Relationship(deleteRule: .nullify, inverse: \RecurringRule.toAccount)
    var incomingRecurringRules: [RecurringRule]? = []

    init(
        id: UUID = UUID(),
        name: String,
        kind: AccountKind,
        openingBalance: Int64 = 0,
        icon: String? = nil,
        colorHex: String = "",
        note: String = "",
        sortOrder: Int = 0,
        isArchived: Bool = false
    ) {
        self.id = id
        self.name = name
        self.kindRaw = kind.rawValue
        self.openingBalance = openingBalance
        self.icon = icon ?? kind.defaultSymbol
        self.colorHex = colorHex
        self.note = note
        self.sortOrder = sortOrder
        self.isArchived = isArchived
    }

    var kind: AccountKind {
        get { AccountKind(rawValue: kindRaw) ?? .cash }
        set { kindRaw = newValue.rawValue }
    }

    /// Signed balance: opening balance plus the delta of every transaction
    /// this account participates in.
    var balance: Int64 {
        let deltas = (transactions ?? []).map {
            LedgerMath.delta(kind: $0.kind, amount: $0.amount, role: .source)
        } + (incomingTransfers ?? []).map {
            LedgerMath.delta(kind: $0.kind, amount: $0.amount, role: .destination)
        }
        return LedgerMath.balance(opening: openingBalance, deltas: deltas)
    }
}
