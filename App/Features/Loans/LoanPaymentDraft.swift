import Foundation
import SwiftData
import FinanceCore

/// Form state for "Ghi nhận trả nợ": the principal part (a transfer into
/// the loan account) and the interest part (an expense out of the paying
/// account). Prefilled from the plan's next installment but both editable —
/// the bank's real numbers usually differ by a few đồng.
struct LoanPaymentDraft {
    /// Which amount the shared keypad edits.
    enum Part: String, CaseIterable {
        case principal
        case interest

        var displayName: String {
            switch self {
            case .principal: return "Gốc"
            case .interest: return "Lãi"
            }
        }
    }

    var principal: Int64
    var interest: Int64
    var date: Date
    /// Asset account the money leaves from.
    var payingAccount: Account?
    /// Installment this payment settles — only used in the notes.
    var installmentIndex: Int

    init(plan: LoanPlan?, date: Date = .now) {
        let next = plan?.nextInstallment
        principal = next?.principal ?? 0
        interest = next?.interest ?? 0
        installmentIndex = next?.index ?? 1
        self.date = date
        payingAccount = nil
    }

    /// Name of the seeded expense category the interest is booked under.
    static let interestCategoryName = "Lãi vay & phí"

    static func principalNote(loanName: String, installment index: Int) -> String {
        "Trả gốc \(loanName) kỳ \(index)"
    }

    static func interestNote(loanName: String, installment index: Int) -> String {
        "Lãi vay \(loanName) kỳ \(index)"
    }

    var total: Int64 { principal + interest }

    var isValid: Bool {
        payingAccount != nil && (principal > 0 || interest > 0)
    }

    /// Inserts the transfer (principal) and the expense (interest) rows in
    /// one go; a zero part is skipped. The caller saves the context.
    /// `interestCategory` is the seeded "Lãi vay & phí" looked up by name —
    /// nil when the user deleted it.
    @discardableResult
    func insert(
        into context: ModelContext,
        loan: Account,
        interestCategory: LedgerCategory?
    ) -> Bool {
        guard isValid, let paying = payingAccount, paying.id != loan.id else { return false }
        if principal > 0 {
            context.insert(LedgerTransaction(
                kind: .transfer,
                amount: principal,
                date: date,
                note: Self.principalNote(loanName: loan.name, installment: installmentIndex),
                account: paying,
                toAccount: loan
            ))
        }
        if interest > 0 {
            context.insert(LedgerTransaction(
                kind: .expense,
                amount: interest,
                date: date,
                note: Self.interestNote(loanName: loan.name, installment: installmentIndex),
                account: paying,
                category: interestCategory
            ))
        }
        return true
    }
}

/// Form state for "Trả gốc trước hạn": a single transfer into the loan
/// account. No schedule bookkeeping is needed — `LoanPlan` infers the new
/// progress from the smaller remaining debt the next time it is built.
struct LoanPrepaymentDraft {
    var amount: Int64
    var date: Date
    var payingAccount: Account?

    init(amount: Int64 = 0, date: Date = .now) {
        self.amount = amount
        self.date = date
    }

    static func note(loanName: String) -> String {
        "Trả gốc trước hạn \(loanName)"
    }

    var isValid: Bool { payingAccount != nil && amount > 0 }

    /// Inserts the transfer row; the caller saves the context.
    @discardableResult
    func insert(into context: ModelContext, loan: Account) -> Bool {
        guard isValid, let paying = payingAccount, paying.id != loan.id else { return false }
        context.insert(LedgerTransaction(
            kind: .transfer,
            amount: amount,
            date: date,
            note: Self.note(loanName: loan.name),
            account: paying,
            toAccount: loan
        ))
        return true
    }
}
