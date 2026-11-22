import Foundation

/// How a bank loan is repaid.
public enum LoanMethod: String, Sendable, CaseIterable {
    /// Equal principal each installment, interest on the declining
    /// balance — the usual Vietnamese "dư nợ giảm dần".
    case equalPrincipal
    /// Equal total payment each installment (annuity).
    case annuity

    public var displayName: String {
        switch self {
        case .equalPrincipal: return "Dư nợ giảm dần"
        case .annuity: return "Trả đều hàng kỳ"
        }
    }
}

/// How the annual rate is converted into a per-installment rate.
public enum LoanInterestBasis: String, Sendable, CaseIterable {
    /// One twelfth of the annual rate per installment.
    case monthly
    /// Actual day count of the period over a fixed 365-day year.
    case actual365

    public var displayName: String {
        switch self {
        case .monthly: return "Theo tháng (lãi năm chia 12)"
        case .actual365: return "Theo ngày thực tế (365 ngày/năm)"
        }
    }
}

public enum LoanScheduleError: Error, Equatable, Sendable {
    case invalidPrincipal
    case invalidTermMonths
    case invalidPaymentDay
    case missingInitialRatePeriod
    case invalidAnnualRate
    case dateOverflow
}

extension LoanScheduleError: LocalizedError {
    public var errorDescription: String? {
        switch self {
        case .invalidPrincipal: return "Số tiền gốc phải lớn hơn 0."
        case .invalidTermMonths: return "Kỳ hạn phải lớn hơn 0 tháng."
        case .invalidPaymentDay: return "Ngày trả hàng tháng phải từ 1 đến 31."
        case .missingInitialRatePeriod: return "Thiếu lãi suất áp dụng từ kỳ 1."
        case .invalidAnnualRate: return "Lãi suất năm không hợp lệ."
        case .dateOverflow: return "Không tính được ngày đến hạn."
        }
    }
}

/// A stretch of installments sharing one annual rate. Chain periods to
/// model a promotional rate followed by a floating rate; the first
/// period must cover installment 1.
public struct LoanRatePeriod: Equatable, Sendable {
    /// First installment (1-based) the rate applies to. Values below 1
    /// are treated as covering installment 1.
    public var fromInstallment: Int
    /// Nominal annual rate in percent — `12.0` means 12%/year.
    public var annualRatePercent: Double

    public init(fromInstallment: Int, annualRatePercent: Double) {
        self.fromInstallment = fromInstallment
        self.annualRatePercent = annualRatePercent
    }
}

/// Extra principal repaid right after a given installment. The rest of
/// the schedule is recomputed keeping the original end date.
public struct LoanPrepayment: Equatable, Sendable {
    /// The extra amount is applied right after this installment (1-based).
    public var afterInstallment: Int
    /// Extra principal in đồng. If it reaches the remaining balance the
    /// loan ends early and any excess is ignored.
    public var amount: Int64

    public init(afterInstallment: Int, amount: Int64) {
        self.afterInstallment = afterInstallment
        self.amount = amount
    }
}

/// One scheduled payment.
public struct LoanInstallment: Equatable, Sendable {
    /// 1-based position in the schedule.
    public let index: Int
    public let dueDate: Date
    /// Principal part of the payment, in đồng.
    public let principal: Int64
    /// Interest part of the payment, in đồng, rounded half-up.
    public let interest: Int64
    /// `principal + interest`.
    public var total: Int64 { principal + interest }
    /// Balance after this installment, including any extra principal
    /// applied at this point.
    public let remainingBalance: Int64

    public init(index: Int, dueDate: Date, principal: Int64, interest: Int64, remainingBalance: Int64) {
        self.index = index
        self.dueDate = dueDate
        self.principal = principal
        self.interest = interest
        self.remainingBalance = remainingBalance
    }
}

/// Inputs describing a bank loan. `schedule(calendar:)` builds the
/// repayment schedule.
public struct LoanTerms: Equatable, Sendable {
    /// Amount disbursed, in đồng. Must be positive.
    public var principal: Int64
    /// Number of monthly installments. Must be positive.
    public var termMonths: Int
    /// Disbursement date.
    public var startDate: Date
    /// Day of month installments fall due (1...31); in shorter months it
    /// clamps to the last day of the month.
    public var paymentDay: Int
    public var method: LoanMethod
    public var basis: LoanInterestBasis
    /// At least one period covering installment 1 is required.
    public var ratePeriods: [LoanRatePeriod]
    /// Extra principal repayments; each keeps the original end date.
    public var prepayments: [LoanPrepayment]

    public init(
        principal: Int64,
        termMonths: Int,
        startDate: Date,
        paymentDay: Int,
        method: LoanMethod,
        basis: LoanInterestBasis,
        ratePeriods: [LoanRatePeriod],
        prepayments: [LoanPrepayment] = []
    ) {
        self.principal = principal
        self.termMonths = termMonths
        self.startDate = startDate
        self.paymentDay = paymentDay
        self.method = method
        self.basis = basis
        self.ratePeriods = ratePeriods
        self.prepayments = prepayments
    }

    /// Builds the repayment schedule.
    ///
    /// Due-date rule: installments fall due on `paymentDay` each month,
    /// clamped to the last day of shorter months. The first due date is
    /// the first clamped payment day on or after `startDate + 1 month`
    /// (compared at day granularity) — i.e. the first payment day
    /// strictly after disbursement that is at least about one calendar
    /// month away.
    public func schedule(calendar: Calendar) throws -> LoanSchedule {
        try LoanSchedule(terms: self, calendar: calendar)
    }
}

/// A fully computed repayment schedule.
public struct LoanSchedule: Equatable, Sendable {
    public let terms: LoanTerms
    public let installments: [LoanInstallment]
    /// Sum of all installment interest parts.
    public let totalInterest: Int64
    /// Sum of all installment totals plus applied extra principal.
    public let totalPaid: Int64
    /// Extra principal actually applied (≤ the requested amounts).
    public let extraPrincipalPaid: Int64

    /// Due date of the last installment — earlier than the original end
    /// when a prepayment cleared the loan.
    public var payoffDate: Date? { installments.last?.dueDate }

    public init(terms: LoanTerms, calendar: Calendar) throws {
        guard terms.principal > 0 else { throw LoanScheduleError.invalidPrincipal }
        guard terms.termMonths > 0 else { throw LoanScheduleError.invalidTermMonths }
        guard (1...31).contains(terms.paymentDay) else {
            throw LoanScheduleError.invalidPaymentDay
        }

        // Rate periods: dedupe (a later entry wins on a tie), sorted by start.
        var seen = Set<Int>()
        var deduped: [LoanRatePeriod] = []
        for p in terms.ratePeriods.reversed() where seen.insert(p.fromInstallment).inserted {
            deduped.append(p)
        }
        let periods = deduped.sorted { $0.fromInstallment < $1.fromInstallment }
        guard let first = periods.first, first.fromInstallment <= 1 else {
            throw LoanScheduleError.missingInitialRatePeriod
        }
        for p in periods where !p.annualRatePercent.isFinite || p.annualRatePercent < 0 {
            throw LoanScheduleError.invalidAnnualRate
        }
        let starts = periods.map { max(1, $0.fromInstallment) }
        func annualRate(forInstallment i: Int) -> Double {
            periods[starts.lastIndex(where: { $0 <= i }) ?? 0].annualRatePercent
        }

        // Due dates (see LoanTerms.schedule for the first-due-date rule).
        let start = calendar.startOfDay(for: terms.startDate)
        guard let anchor = calendar.date(byAdding: .month, value: 1, to: start),
              let firstDue = Self.paymentDate(onOrAfter: anchor, paymentDay: terms.paymentDay, calendar: calendar)
        else { throw LoanScheduleError.dateOverflow }
        var dueDates = [Date]()
        dueDates.reserveCapacity(terms.termMonths)
        var cursor = Self.totalMonths(of: firstDue, calendar: calendar)
        for _ in 0..<terms.termMonths {
            guard let d = Self.clampedPaymentDate(
                totalMonths: cursor, paymentDay: terms.paymentDay, calendar: calendar
            ) else { throw LoanScheduleError.dateOverflow }
            dueDates.append(d)
            cursor += 1
        }

        // Per-installment period rate, as a decimal (0.01 = 1%/period).
        var dayCounts = [Int]()
        if terms.basis == .actual365 {
            dayCounts.reserveCapacity(terms.termMonths)
            for (i, due) in dueDates.enumerated() {
                let from = i == 0 ? start : dueDates[i - 1]
                dayCounts.append(calendar.dateComponents([.day], from: from, to: due).day ?? 0)
            }
        }
        func periodRate(forInstallment i: Int) -> Double {
            let annual = annualRate(forInstallment: i) / 100
            switch terms.basis {
            case .monthly: return annual / 12
            case .actual365: return annual * Double(dayCounts[i - 1]) / 365
            }
        }

        // Extra principal, grouped by the installment it follows.
        var prepaySums = [Int: Int64]()
        for p in terms.prepayments where p.afterInstallment >= 1 && p.amount > 0 {
            let (sum, overflow) = (prepaySums[p.afterInstallment] ?? 0)
                .addingReportingOverflow(p.amount)
            prepaySums[p.afterInstallment] = overflow ? .max : sum
        }

        var installments = [LoanInstallment]()
        installments.reserveCapacity(terms.termMonths)
        var balance = terms.principal
        var extraPaid: Int64 = 0
        var equalPrincipalPart = terms.principal / Int64(terms.termMonths)
        var payment: Int64 = 0
        var recomputePayment = true

        var i = 1
        while i <= terms.termMonths, balance > 0 {
            let interest = Self.dong(Double(balance) * periodRate(forInstallment: i))
            let principalPart: Int64
            switch terms.method {
            case .equalPrincipal:
                principalPart = i == terms.termMonths ? balance : min(equalPrincipalPart, balance)
            case .annuity:
                // The payment is recomputed on the remaining balance over
                // the remaining term whenever the rate changes or extra
                // principal was just applied.
                if recomputePayment
                    || annualRate(forInstallment: i) != annualRate(forInstallment: i - 1) {
                    payment = Self.annuityPayment(
                        balance: balance, firstInstallment: i,
                        lastInstallment: terms.termMonths
                    ) { periodRate(forInstallment: $0) }
                }
                principalPart = i == terms.termMonths ? balance : min(max(payment - interest, 0), balance)
            }
            recomputePayment = false
            balance -= principalPart

            // Extra principal scheduled right after this installment.
            var applied: Int64 = 0
            if let extra = prepaySums[i], balance > 0 {
                applied = min(extra, balance)
                balance -= applied
                extraPaid += applied
            }
            installments.append(LoanInstallment(
                index: i, dueDate: dueDates[i - 1],
                principal: principalPart, interest: interest,
                remainingBalance: balance
            ))
            if applied > 0, balance > 0 {
                switch terms.method {
                case .equalPrincipal:
                    // `balance > 0` here implies i < termMonths.
                    equalPrincipalPart = balance / Int64(terms.termMonths - i)
                case .annuity:
                    recomputePayment = true
                }
            }
            i += 1
        }

        self.terms = terms
        self.installments = installments
        self.totalInterest = installments.reduce(0) { $0 + $1.interest }
        self.totalPaid = installments.reduce(0) { $0 + $1.total } + extraPaid
        self.extraPrincipalPaid = extraPaid
    }

    /// Balance after `count` installments were paid, including extra
    /// principal applied at that point. `count <= 0` gives the original
    /// principal; a count past the end of the schedule gives 0.
    public func balance(afterInstallmentsPaid count: Int) -> Int64 {
        if count <= 0 { return terms.principal }
        return count < installments.count ? installments[count - 1].remainingBalance : 0
    }

    /// First installment due on or after `date`, compared at day
    /// granularity. Nil once every due date is past.
    public func nextInstallment(dueOnOrAfter date: Date, calendar: Calendar) -> LoanInstallment? {
        installments.first {
            calendar.compare($0.dueDate, to: date, toGranularity: .day) != .orderedAscending
        }
    }

    // MARK: - Private helpers

    /// Round half-up (away from zero) to whole đồng, clamped to Int64.
    private static func dong(_ x: Double) -> Int64 {
        guard x.isFinite else { return 0 }
        let r = x.rounded(.toNearestOrAwayFromZero)
        if r >= Double(Int64.max) { return .max }
        if r <= Double(Int64.min) { return .min }
        return Int64(r)
    }

    /// Level payment that amortizes `balance` over installments
    /// `firstInstallment...lastInstallment`, honoring each future
    /// installment's own rate (later rate periods may still start within
    /// the window).
    private static func annuityPayment(
        balance: Int64, firstInstallment: Int, lastInstallment: Int,
        periodRate: (Int) -> Double
    ) -> Int64 {
        var factor = 1.0
        var discountSum = 0.0
        for j in firstInstallment...lastInstallment {
            factor /= 1 + periodRate(j)
            discountSum += factor
        }
        return dong(Double(balance) / discountSum)
    }

    /// Absolute month index (year * 12 + month - 1) for month arithmetic
    /// that never wraps at year boundaries.
    private static func totalMonths(of date: Date, calendar: Calendar) -> Int {
        let c = calendar.dateComponents([.year, .month], from: date)
        return (c.year ?? 0) * 12 + (c.month ?? 1) - 1
    }

    /// The payment day clamped to the length of the given absolute month.
    private static func clampedPaymentDate(
        totalMonths m: Int, paymentDay: Int, calendar: Calendar
    ) -> Date? {
        let year = m / 12
        let month = m % 12 + 1
        guard let firstOfMonth = calendar.date(from: DateComponents(year: year, month: month, day: 1)),
              let dayCount = calendar.range(of: .day, in: .month, for: firstOfMonth)?.count
        else { return nil }
        return calendar.date(from: DateComponents(
            year: year, month: month, day: min(paymentDay, dayCount)
        ))
    }

    /// First clamped payment day on or after `anchor` (day granularity).
    private static func paymentDate(
        onOrAfter anchor: Date, paymentDay: Int, calendar: Calendar
    ) -> Date? {
        let base = totalMonths(of: anchor, calendar: calendar)
        for offset in 0..<3 {
            guard let candidate = clampedPaymentDate(
                totalMonths: base + offset, paymentDay: paymentDay, calendar: calendar
            ) else { continue }
            if calendar.compare(candidate, to: anchor, toGranularity: .day) != .orderedAscending {
                return candidate
            }
        }
        return nil
    }
}
