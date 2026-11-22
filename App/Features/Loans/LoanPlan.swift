import Foundation
import FinanceCore

/// Repayment state of one loan account: the planned schedule from
/// `LoanTerms` plus how far along the loan actually is.
///
/// The ledger is the source of truth for what is still owed, so progress is
/// *inferred* rather than tracked per installment: the paid count is the
/// largest k whose planned remaining balance is still >= the real remaining
/// debt. Recording an extra principal payment lowers the real debt and the
/// inference adapts the schedule on the next read.
struct LoanPlan {
    /// Planned schedule built from the account's loan fields and rate
    /// changes — what the bank should see when nothing is early or late.
    let schedule: LoanSchedule
    /// Debt still owed according to the ledger (`max(0, -balance)`).
    let remainingDebt: Int64
    /// Installments inferred paid, in `0...schedule.installments.count`.
    let paidInstallmentCount: Int

    init(schedule: LoanSchedule, remainingDebt: Int64) {
        self.schedule = schedule
        self.remainingDebt = max(0, remainingDebt)
        self.paidInstallmentCount = Self.inferPaidCount(
            schedule: schedule, debt: self.remainingDebt
        )
    }

    /// Builds the plan for an account, or nil when its loan fields are too
    /// incomplete to compute a schedule — the view then offers to fill them.
    init?(account: Account, basis: LoanInterestBasis, calendar: Calendar) {
        guard let terms = Self.terms(for: account, basis: basis),
              let schedule = try? terms.schedule(calendar: calendar)
        else { return nil }
        self.init(schedule: schedule, remainingDebt: -account.balance)
    }

    // MARK: - Terms

    /// `LoanTerms` for an account, or nil when its loan fields are too
    /// incomplete to plan a schedule. Rate periods are the account's base
    /// rate covering installment 1 plus every `LoanRateChange`.
    static func terms(for account: Account, basis: LoanInterestBasis) -> LoanTerms? {
        guard account.kind == .loan,
              let principal = account.loanPrincipal, principal > 0,
              let termMonths = account.loanTermMonths, termMonths > 0,
              let startDate = account.loanStartDate,
              let paymentDay = account.loanPaymentDay, (1...31).contains(paymentDay),
              let rate = account.loanAnnualRatePercent, rate.isFinite, rate >= 0,
              let methodRaw = account.loanMethodRaw,
              let method = LoanMethod(rawValue: methodRaw)
        else { return nil }

        var periods = [LoanRatePeriod(fromInstallment: 1, annualRatePercent: rate)]
        for change in account.loanRateChanges ?? [] {
            periods.append(LoanRatePeriod(
                fromInstallment: max(1, change.fromInstallment),
                annualRatePercent: change.annualRatePercent
            ))
        }
        return LoanTerms(
            principal: principal,
            termMonths: termMonths,
            startDate: startDate,
            paymentDay: paymentDay,
            method: method,
            basis: basis,
            ratePeriods: periods
        )
    }

    /// Largest paid count whose planned remaining balance still covers the
    /// real debt. Planned balances fall monotonically, so the first count
    /// that drops below the debt ends the search.
    static func inferPaidCount(schedule: LoanSchedule, debt: Int64) -> Int {
        var paid = 0
        for count in 1...schedule.installments.count {
            guard schedule.balance(afterInstallmentsPaid: count) >= debt else { break }
            paid = count
        }
        return paid
    }

    // MARK: - Derived values

    var principal: Int64 { schedule.terms.principal }

    /// Principal actually repaid so far, from the ledger's point of view.
    var principalRepaid: Int64 { max(0, min(principal, principal - remainingDebt)) }

    /// 0...1 fraction of the principal repaid — drives the progress bar.
    var progressFraction: Double {
        guard principal > 0 else { return 0 }
        return Double(principalRepaid) / Double(principal)
    }

    var isFullyRepaid: Bool { remainingDebt <= 0 }

    /// First installment not yet paid; nil once the schedule is done.
    var nextInstallment: LoanInstallment? {
        guard paidInstallmentCount < schedule.installments.count else { return nil }
        return schedule.installments[paidInstallmentCount]
    }

    /// Due date of the last scheduled installment.
    var payoffDate: Date? { schedule.payoffDate }

    /// Annual rate in effect for a 1-based installment index — a later rate
    /// period wins on a tie, mirroring `LoanSchedule`.
    func annualRate(atInstallment index: Int) -> Double {
        var byStart: [Int: Double] = [:]
        for period in schedule.terms.ratePeriods {
            byStart[max(1, period.fromInstallment)] = period.annualRatePercent
        }
        let start = byStart.keys.filter { $0 <= index }.max() ?? 1
        return byStart[start] ?? 0
    }

    /// Rate the next unpaid installment will be charged at.
    var currentAnnualRate: Double {
        annualRate(atInstallment: nextInstallment?.index ?? schedule.installments.count)
    }

    /// Whole days until the next due date; negative when overdue, nil when
    /// every installment is inferred paid.
    func daysUntilNextDue(now: Date, calendar: Calendar) -> Int? {
        guard let due = nextInstallment?.dueDate else { return nil }
        return calendar.dateComponents(
            [.day],
            from: calendar.startOfDay(for: now),
            to: calendar.startOfDay(for: due)
        ).day
    }

    func isOverdue(now: Date, calendar: Calendar) -> Bool {
        (daysUntilNextDue(now: now, calendar: calendar) ?? 0) < 0
    }

    // MARK: - Rate-change validation

    /// First problem with a proposed rate change, or nil when it can save:
    /// the installment must sit inside `2...termMonths` (installment 1 keeps
    /// the base rate), the rate must be positive, and no other change may
    /// start at the same installment.
    static func validateRateChange(
        fromInstallment: Int,
        annualRatePercent: Double,
        termMonths: Int,
        existingInstallments: Set<Int>
    ) -> LoanRateChangeError? {
        guard fromInstallment >= 2, fromInstallment <= termMonths else {
            return .invalidInstallment
        }
        guard annualRatePercent.isFinite, annualRatePercent > 0 else {
            return .invalidRate
        }
        guard !existingInstallments.contains(fromInstallment) else {
            return .duplicateInstallment
        }
        return nil
    }
}

/// Why a rate change cannot be saved; each case carries a Vietnamese message.
enum LoanRateChangeError: Error, Equatable {
    case invalidInstallment
    case invalidRate
    case duplicateInstallment
}

extension LoanRateChangeError: LocalizedError {
    var errorDescription: String? {
        switch self {
        case .invalidInstallment:
            return "Kỳ áp dụng phải từ 2 đến kỳ cuối của khoản vay."
        case .invalidRate:
            return "Lãi suất mới phải lớn hơn 0."
        case .duplicateInstallment:
            return "Đã có lãi suất thay đổi từ kỳ này."
        }
    }
}

/// Per-account choice of `LoanInterestBasis`, kept in UserDefaults keyed by
/// account id so it survives relaunches. Defaults to `.actual365` — the way
/// Vietnamese banks actually charge interest on the day count.
struct LoanInterestBasisStore {
    private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    func basis(for accountID: UUID) -> LoanInterestBasis {
        guard let raw = defaults.string(forKey: Self.key(for: accountID)),
              let basis = LoanInterestBasis(rawValue: raw)
        else { return .actual365 }
        return basis
    }

    func set(_ basis: LoanInterestBasis, for accountID: UUID) {
        defaults.set(basis.rawValue, forKey: Self.key(for: accountID))
    }

    /// Drops every stored basis choice — the "Xoá tất cả" reset uses it.
    /// Keys are per-account, so the removal scans for the prefix.
    func removeAll() {
        for key in defaults.dictionaryRepresentation().keys
        where key.hasPrefix(Self.keyPrefix) {
            defaults.removeObject(forKey: key)
        }
    }

    private static let keyPrefix = "loanInterestBasis."

    private static func key(for accountID: UUID) -> String {
        "\(keyPrefix)\(accountID.uuidString)"
    }
}

/// "dd/MM/yyyy" dates on the app calendar for loan screens — due dates and
/// payoff dates cross year boundaries where `AppDateFormat.shortDate`
/// ("dd/MM") would mislead. Built from date components, so creating it is
/// cheap enough to call per schedule row.
enum LoanDateFormat {
    static func full(_ date: Date, calendar: Calendar = AppCalendar.vietnam) -> String {
        let components = calendar.dateComponents([.day, .month, .year], from: date)
        return String(
            format: "%02d/%02d/%04d",
            components.day ?? 0, components.month ?? 0, components.year ?? 0
        )
    }
}
