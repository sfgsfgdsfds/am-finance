import Foundation
import FinanceCore

/// The single income/expense `LedgerTransaction` that reconciles an
/// account's stored balance with the real-world amount the user confirms
/// ("Điều chỉnh số dư"). Pure math — the view supplies the signed balances.
enum AccountBalanceAdjustment {

    /// What to insert so `current` becomes `target`: an income for the
    /// missing amount or an expense for the excess. Nil when no adjustment
    /// is needed.
    static func adjustment(current: Int64, target: Int64) -> (kind: TransactionKind, amount: Int64)? {
        let delta = target - current
        if delta > 0 { return (.income, delta) }
        if delta < 0 { return (.expense, -delta) }
        return nil
    }

    /// The signed target balance behind the non-negative number typed on the
    /// keypad: for liabilities the user enters the actual debt ("Dư nợ thực
    /// tế"), which is a negative balance.
    static func signedTarget(typed: Int64, kind: AccountKind) -> Int64 {
        kind.isLiability ? -max(0, typed) : max(0, typed)
    }
}
