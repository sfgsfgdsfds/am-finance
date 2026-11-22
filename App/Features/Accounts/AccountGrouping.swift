import Foundation
import FinanceCore

/// One section of the accounts list: every non-archived account of a single
/// `AccountKind`, plus the running subtotal shown in the section header.
struct AccountSection {
    let kind: AccountKind
    let accounts: [Account]
    let subtotal: Int64
}

extension AccountSection: Equatable {
    static func == (lhs: AccountSection, rhs: AccountSection) -> Bool {
        lhs.kind == rhs.kind
            && lhs.subtotal == rhs.subtotal
            && lhs.accounts.map(\.id) == rhs.accounts.map(\.id)
    }
}

/// Grouping rules for `AccountsListView`. Pure functions over `[Account]` so
/// section order, subtotals and the archived split are unit-testable.
enum AccountGrouping {

    /// Non-archived accounts grouped by kind, in the fixed order
    /// cash, bank, eWallet, creditCard, loan. Kinds with no accounts are
    /// dropped; inside a section accounts sort by `sortOrder` then name.
    static func sections(from accounts: [Account]) -> [AccountSection] {
        AccountKind.allCases.compactMap { kind in
            let members = sorted(accounts.filter { !$0.isArchived && $0.kind == kind })
            guard !members.isEmpty else { return nil }
            return AccountSection(
                kind: kind,
                accounts: members,
                subtotal: members.reduce(0) { $0 + $1.balance }
            )
        }
    }

    /// Archived accounts for the collapsed "Đã lưu trữ" section.
    static func archived(from accounts: [Account]) -> [Account] {
        sorted(accounts.filter(\.isArchived))
    }

    /// An account may only be deleted while nothing references it — as a
    /// transaction source or as a transfer destination. The UI offers
    /// archiving instead when this returns false.
    static func canDelete(_ account: Account) -> Bool {
        (account.transactions ?? []).isEmpty
            && (account.incomingTransfers ?? []).isEmpty
    }

    private static func sorted(_ accounts: [Account]) -> [Account] {
        accounts.sorted { ($0.sortOrder, $0.name) < ($1.sortOrder, $1.name) }
    }
}
