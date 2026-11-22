import Foundation

/// Aggregate totals over accounts. Balances are signed (see `LedgerMath`):
/// liabilities carry negative balances, so net worth is just a sum.
enum NetWorth {
    /// Sum of balances of non-archived asset accounts (cash, bank, eWallet).
    static func assets(_ accounts: [Account]) -> Int64 {
        sum(of: accounts) { !$0.kind.isLiability }
    }

    /// Sum of balances of non-archived liability accounts (cards, loans) —
    /// a negative number or zero.
    static func liabilities(_ accounts: [Account]) -> Int64 {
        sum(of: accounts) { $0.kind.isLiability }
    }

    /// Net worth: assets + liabilities, over non-archived accounts.
    static func total(_ accounts: [Account]) -> Int64 {
        sum(of: accounts) { _ in true }
    }

    private static func sum(of accounts: [Account], where include: (Account) -> Bool) -> Int64 {
        accounts.reduce(0) { $0 + ($1.isArchived || !include($1) ? 0 : $1.balance) }
    }
}
