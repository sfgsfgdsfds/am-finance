import Foundation

/// Card-payment rules. A card payment is **always a transfer** from an asset
/// account into the card — never an expense — so `makeTransfer` builds the
/// one `LedgerTransaction` shape the sheet is allowed to insert, and
/// `eligiblePayers` lists the accounts it may come from.
enum CreditCardPayment {

    /// One transfer of `amount` đồng from `source` into `card`, noted
    /// "Trả nợ thẻ <card name>". `amount` is the positive magnitude the user
    /// typed; `LedgerMath` applies the signs per side.
    static func makeTransfer(
        card: Account,
        from source: Account,
        amount: Int64,
        date: Date
    ) -> LedgerTransaction {
        LedgerTransaction(
            kind: .transfer,
            amount: amount,
            date: date,
            note: "Trả nợ thẻ \(card.name)",
            account: source,
            toAccount: card
        )
    }

    /// Accounts a payment can come from: not archived and not a liability —
    /// paying a card with another card or a loan is a cash-advance, which the
    /// app does not model here.
    static func eligiblePayers(_ accounts: [Account], paying card: Account) -> [Account] {
        accounts.filter {
            !$0.isArchived && !$0.kind.isLiability && $0.id != card.id
        }
    }
}

/// The amounts behind the payment sheet's quick chips and keypad pre-fill —
/// plain values so the mapping is testable. `nil` means "no statement data"
/// (card without a configured cycle) and the chip is hidden.
struct CreditCardPaymentPlan: Equatable {
    /// Full balance of the last closed statement — the "Dư nợ sao kê" chip.
    var statementBalance: Int64?
    /// Still due on the statement — the keypad pre-fill.
    var statementDue: Int64?
    /// Estimated minimum payment — the "Tối thiểu" chip.
    var minimumPayment: Int64?
    /// All debt on the card — the "Toàn bộ dư nợ" chip and fallback pre-fill.
    var totalDebt: Int64

    init(
        statementBalance: Int64? = nil,
        statementDue: Int64? = nil,
        minimumPayment: Int64? = nil,
        totalDebt: Int64
    ) {
        self.statementBalance = statementBalance
        self.statementDue = statementDue
        self.minimumPayment = minimumPayment
        self.totalDebt = totalDebt
    }

    /// What the keypad starts on: the statement's remaining due, else all debt.
    var prefill: Int64 {
        max(0, statementDue ?? totalDebt)
    }
}
