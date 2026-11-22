import Foundation
import FinanceCore

/// Editable form state for `AccountEditView`: plain values so validation and
/// the model mapping can be unit-tested without SwiftData or SwiftUI.
///
/// `openingBalance` is the positive magnitude the user types on the keypad.
/// For liability kinds (credit card, loan) it is the current debt — "Dư nợ
/// hiện tại" — and is stored as a negative `openingBalance` on the model.
struct AccountDraft: Equatable {
    var name = ""
    var kind = AccountKind.cash
    /// Positive đồng typed on the keypad; see `signedOpeningBalance`.
    var openingBalance: Int64 = 0
    var icon = ""
    var colorHex = ""
    var note = ""

    // Credit-card fields (kind == .creditCard). A limit of 0 means none.
    var creditLimit: Int64 = 0
    var statementDay = 15
    var graceDays = 15

    // Loan fields (kind == .loan).
    var loanPrincipal: Int64 = 0
    var loanAnnualRatePercent: Double = 0
    var loanTermMonths = 0
    var loanStartDate = Date.now
    var loanPaymentDay = 1
    var loanMethod = LoanMethod.equalPrincipal

    init() {
        icon = kind.defaultSymbol
        colorHex = "0A84FF"
    }

    /// Form state prefilled from an existing account. A liability's stored
    /// negative opening balance comes back as a positive debt amount.
    init(account: Account) {
        self.init()
        name = account.name
        kind = account.kind
        openingBalance = account.kind.isLiability
            ? max(0, -account.openingBalance)
            : max(0, account.openingBalance)
        icon = account.icon
        colorHex = account.colorHex
        note = account.note
        creditLimit = account.creditLimit ?? 0
        statementDay = account.statementDay ?? 15
        graceDays = account.graceDays ?? 15
        loanPrincipal = account.loanPrincipal ?? 0
        loanAnnualRatePercent = account.loanAnnualRatePercent ?? 0
        loanTermMonths = account.loanTermMonths ?? 0
        loanStartDate = account.loanStartDate ?? .now
        loanPaymentDay = account.loanPaymentDay ?? 1
        loanMethod = LoanMethod(rawValue: account.loanMethodRaw ?? "") ?? .equalPrincipal
    }

    /// The opening balance as it is stored on the model: the typed debt is
    /// negated for liabilities, passed through as-is for assets.
    var signedOpeningBalance: Int64 {
        kind.isLiability ? -max(0, openingBalance) : openingBalance
    }

    /// First problem found, or nil when the draft can be saved.
    func validate() -> AccountDraftError? {
        if name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return .missingName
        }
        switch kind {
        case .creditCard:
            if !(1...31).contains(statementDay) { return .invalidStatementDay }
        case .loan:
            if loanPrincipal <= 0 { return .invalidLoanPrincipal }
            if loanTermMonths <= 0 { return .invalidLoanTerm }
            if !loanAnnualRatePercent.isFinite || loanAnnualRatePercent <= 0 {
                return .invalidLoanRate
            }
            if !(1...31).contains(loanPaymentDay) { return .invalidLoanPaymentDay }
        case .cash, .bank, .eWallet:
            break
        }
        return nil
    }

    /// Writes every field onto a model. Irrelevant kind-specific fields are
    /// cleared so a stale credit limit never survives on a cash account.
    func apply(to account: Account) {
        account.name = name.trimmingCharacters(in: .whitespacesAndNewlines)
        account.kind = kind
        account.openingBalance = signedOpeningBalance
        account.icon = icon
        account.colorHex = colorHex
        account.note = note

        account.creditLimit = kind == .creditCard && creditLimit > 0 ? creditLimit : nil
        account.statementDay = kind == .creditCard ? statementDay : nil
        account.graceDays = kind == .creditCard ? graceDays : nil

        account.loanPrincipal = kind == .loan ? loanPrincipal : nil
        account.loanAnnualRatePercent = kind == .loan ? loanAnnualRatePercent : nil
        account.loanTermMonths = kind == .loan ? loanTermMonths : nil
        account.loanStartDate = kind == .loan ? loanStartDate : nil
        account.loanPaymentDay = kind == .loan ? loanPaymentDay : nil
        account.loanMethodRaw = kind == .loan ? loanMethod.rawValue : nil
    }

    /// Statement-cycle config for a credit-card draft — powers the
    /// "Sao kê tiếp theo" / "Hạn thanh toán" previews in the form.
    var creditCardCycleConfig: CreditCardCycleConfig {
        CreditCardCycleConfig(statementDay: statementDay, graceDays: graceDays)
    }
}

/// Why a draft cannot be saved; each case carries a Vietnamese message.
enum AccountDraftError: Error, Equatable {
    case missingName
    case invalidStatementDay
    case invalidLoanPrincipal
    case invalidLoanTerm
    case invalidLoanRate
    case invalidLoanPaymentDay
}

extension AccountDraftError: LocalizedError {
    var errorDescription: String? {
        switch self {
        case .missingName: return "Vui lòng nhập tên tài khoản."
        case .invalidStatementDay: return "Ngày chốt sao kê phải từ 1 đến 31."
        case .invalidLoanPrincipal: return "Số tiền vay gốc phải lớn hơn 0."
        case .invalidLoanTerm: return "Kỳ hạn phải lớn hơn 0 tháng."
        case .invalidLoanRate: return "Lãi suất phải lớn hơn 0."
        case .invalidLoanPaymentDay: return "Ngày trả hằng tháng phải từ 1 đến 31."
        }
    }
}
