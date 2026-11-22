/// Domain vocabulary shared by the app and the FinanceCore logic package.

/// Kinds of account the ledger can hold.
public enum AccountKind: String, Codable, CaseIterable, Sendable {
    case cash
    case bank
    case eWallet
    case receivable
    case creditCard
    case loan

    /// Liabilities are money I owe: card debt and loans. A negative balance
    /// on a liability account is normal — it is the amount outstanding.
    /// A receivable is the opposite: money a client owes me, so it sits
    /// with the assets and carries a positive balance while unpaid.
    public var isLiability: Bool {
        self == .creditCard || self == .loan
    }

    /// Vietnamese label for the UI.
    public var displayName: String {
        switch self {
        case .cash: return "Tiền mặt"
        case .bank: return "Ngân hàng"
        case .eWallet: return "Ví điện tử"
        case .receivable: return "Phải thu"
        case .creditCard: return "Thẻ tín dụng"
        case .loan: return "Khoản vay"
        }
    }

    /// SF Symbol used when an account has no custom icon.
    public var defaultSymbol: String {
        switch self {
        case .cash: return "banknote.fill"
        case .bank: return "building.columns.fill"
        case .eWallet: return "wallet.pass.fill"
        case .receivable: return "person.badge.clock.fill"
        case .creditCard: return "creditcard.fill"
        case .loan: return "doc.text.fill"
        }
    }
}

/// Kinds of movement between accounts.
public enum TransactionKind: String, Codable, CaseIterable, Sendable {
    case expense
    case income
    case transfer

    /// Vietnamese label for the UI.
    public var displayName: String {
        switch self {
        case .expense: return "Chi"
        case .income: return "Thu"
        case .transfer: return "Chuyển khoản"
        }
    }
}

/// Whether a category classifies money out or money in.
public enum CategoryKind: String, Codable, CaseIterable, Sendable {
    case expense
    case income
}

/// Signed ledger arithmetic.
///
/// Sign convention:
/// - Every account holds a *signed* balance: positive is money I own,
///   negative is money I owe. Net worth is the sum of all account balances.
/// - A transaction's `amount` is always a positive magnitude.
/// - `expense`: the source account goes DOWN by `amount`. A purchase on a
///   credit card is an expense whose source is the card, so the card balance
///   goes more negative — the debt grows.
/// - `income`: the source account goes UP by `amount` — for income the
///   "source" is the account that receives the money.
/// - `transfer`: the source goes DOWN and the destination goes UP by
///   `amount`. Paying a card bill is a transfer from a bank account to the
///   card; repaying a loan is a transfer into the loan account.
/// - A loan account starts with a negative opening balance (the principal
///   owed); repayments push it back towards zero.
public enum LedgerMath {

    /// Which side of a transaction an account sits on. `destination` only
    /// has an effect for transfers.
    public enum Role: String, Codable, CaseIterable, Sendable {
        case source
        case destination
    }

    /// The signed change a transaction applies to an account, given the
    /// account's role in it. A role that does not apply (e.g. the
    /// destination of an expense) contributes 0.
    public static func delta(kind: TransactionKind, amount: Int64, role: Role) -> Int64 {
        switch (kind, role) {
        case (.expense, .source), (.transfer, .source):
            return -amount
        case (.income, .source), (.transfer, .destination):
            return amount
        case (.expense, .destination), (.income, .destination):
            return 0
        }
    }

    /// Opening balance plus a list of signed deltas.
    public static func balance(opening: Int64, deltas: [Int64]) -> Int64 {
        deltas.reduce(opening, +)
    }
}
