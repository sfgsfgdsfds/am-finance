import Foundation
import FinanceCore

/// The four things the user can do on a client receivable, each producing
/// exactly one `LedgerTransaction` row — advances and repayments are
/// transfers so they never touch income/expense reports; a write-off is an
/// expense on the receivable account (a real business cost); the service
/// fee is an income row tagged with the client's business.
enum ReceivableActions {

    // MARK: - Row builders

    /// One transfer `payer` → `receivable`: the owner fronts ad spend (or
    /// any cost) for the client. Never an expense.
    static func advance(
        receivable: Account,
        from payer: Account,
        amount: Int64,
        date: Date,
        note: String
    ) -> LedgerTransaction {
        LedgerTransaction(
            kind: .transfer,
            amount: amount,
            date: date,
            note: note,
            account: payer,
            toAccount: receivable
        )
    }

    /// One transfer `receivable` → `receiver`: the client pays the owner
    /// back. Never income.
    static func repayment(
        receivable: Account,
        to receiver: Account,
        amount: Int64,
        date: Date,
        note: String
    ) -> LedgerTransaction {
        LedgerTransaction(
            kind: .transfer,
            amount: amount,
            date: date,
            note: note,
            account: receivable,
            toAccount: receiver
        )
    }

    /// One income row into `receiver` tagged with the client's business —
    /// the only part of the flow that is real revenue. `category` is the
    /// seeded "Doanh thu dịch vụ" row, nil when it is missing.
    static func serviceFee(
        receivable: Account,
        to receiver: Account,
        amount: Int64,
        date: Date,
        note: String,
        category: LedgerCategory?
    ) -> LedgerTransaction {
        LedgerTransaction(
            kind: .income,
            amount: amount,
            date: date,
            note: note,
            account: receiver,
            category: category,
            business: receivable.business
        )
    }

    /// One expense row sourced from `receivable`: the unpaid amount becomes
    /// a business cost and the receivable shrinks. `category` is the seeded
    /// "Chi khác" row, nil when it is missing.
    static func writeOff(
        receivable: Account,
        amount: Int64,
        date: Date,
        note: String,
        category: LedgerCategory?
    ) -> LedgerTransaction {
        LedgerTransaction(
            kind: .expense,
            amount: amount,
            date: date,
            note: note,
            account: receivable,
            category: category,
            business: receivable.business
        )
    }

    // MARK: - Account pickers

    /// Accounts an advance can be paid from: non-archived accounts holding
    /// real money or card capacity — cash, bank, eWallet, credit card.
    static func advancePayers(_ accounts: [Account], for receivable: Account) -> [Account] {
        accounts.filter { $0.id != receivable.id && canAdvance(from: $0) }
    }

    /// Accounts a repayment or service fee can land in: non-archived cash,
    /// bank or eWallet.
    static func receivers(_ accounts: [Account], for receivable: Account) -> [Account] {
        accounts.filter { $0.id != receivable.id && canReceive(into: $0) }
    }

    /// The per-account half of `advancePayers` — for callers validating a
    /// single already-picked payer.
    static func canAdvance(from account: Account) -> Bool {
        !account.isArchived
            && (account.kind == .cash || account.kind == .bank
                || account.kind == .eWallet || account.kind == .creditCard)
    }

    /// The per-account half of `receivers`.
    static func canReceive(into account: Account) -> Bool {
        !account.isArchived
            && (account.kind == .cash || account.kind == .bank
                || account.kind == .eWallet)
    }

    // MARK: - Seeded categories

    /// The income category a service fee is filed under.
    static let serviceFeeCategoryName = "Doanh thu dịch vụ"
    /// The expense category a write-off is filed under.
    static let writeOffCategoryName = "Chi khác"

    /// Finds a category by Vietnamese name and kind — the seeded rows are
    /// looked up by name so a user-renamed or deleted seed degrades to nil
    /// rather than trapping.
    static func category(
        named name: String,
        kind: CategoryKind,
        in categories: [LedgerCategory]
    ) -> LedgerCategory? {
        categories.first { $0.name == name && $0.kind == kind }
    }
}

/// Which action sheet `ReceivableDetailView` is presenting — each maps to
/// one `ReceivableActions` builder.
enum ReceivableSheetKind: Identifiable {
    case advance
    case repayment
    case serviceFee
    case writeOff

    var id: Int {
        switch self {
        case .advance: return 0
        case .repayment: return 1
        case .serviceFee: return 2
        case .writeOff: return 3
        }
    }

    /// Navigation title of the sheet.
    var title: String {
        switch self {
        case .advance: return "Ứng tiền cho khách"
        case .repayment: return "Khách hoàn tiền"
        case .serviceFee: return "Thu phí dịch vụ"
        case .writeOff: return "Xoá nợ"
        }
    }

    /// The counterparty picker's label; nil when the action has no second
    /// account (write-off).
    var counterpartyLabel: String? {
        switch self {
        case .advance: return "Trả từ"
        case .repayment, .serviceFee: return "Nhận vào"
        case .writeOff: return nil
        }
    }

    /// The note the sheet's field starts with.
    func defaultNote(clientName: String) -> String {
        switch self {
        case .advance: return "Ứng tiền cho \(clientName)"
        case .repayment: return "\(clientName) hoàn tiền"
        case .serviceFee: return "Phí dịch vụ \(clientName)"
        case .writeOff: return "Xoá nợ \(clientName)"
        }
    }
}
