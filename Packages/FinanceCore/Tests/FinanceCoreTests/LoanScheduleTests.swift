import Foundation
import Testing
@testable import FinanceCore

private func loanCal() -> Calendar {
    var c = Calendar(identifier: .gregorian)
    c.timeZone = TimeZone(identifier: "UTC")!
    return c
}

private func loanDate(_ y: Int, _ m: Int, _ d: Int, _ cal: Calendar) -> Date {
    cal.date(from: DateComponents(year: y, month: m, day: d))!
}

private func makeSchedule(
    principal: Int64,
    months: Int,
    start: Date,
    paymentDay: Int = 20,
    method: LoanMethod,
    basis: LoanInterestBasis,
    rates: [(Int, Double)],
    prepayments: [(Int, Int64)] = [],
    calendar: Calendar
) throws -> LoanSchedule {
    try LoanTerms(
        principal: principal,
        termMonths: months,
        startDate: start,
        paymentDay: paymentDay,
        method: method,
        basis: basis,
        ratePeriods: rates.map { LoanRatePeriod(fromInstallment: $0.0, annualRatePercent: $0.1) },
        prepayments: prepayments.map { LoanPrepayment(afterInstallment: $0.0, amount: $0.1) }
    ).schedule(calendar: calendar)
}

struct LoanEqualPrincipalTests {
    private let cal = loanCal()

    // 120tr over 12 months at 12%/yr: principal 10tr/month, interest
    // 1.2tr, 1.1tr, ..., 0.1tr; total interest 7.8tr.
    @Test func decliningBalanceFlatRate() throws {
        let s = try makeSchedule(
            principal: 120_000_000, months: 12,
            start: loanDate(2025, 1, 15, cal),
            method: .equalPrincipal, basis: .monthly,
            rates: [(1, 12)], calendar: cal
        )
        #expect(s.installments.count == 12)
        #expect(s.installments[0].dueDate == loanDate(2025, 2, 20, cal))
        #expect(s.installments[11].dueDate == loanDate(2026, 1, 20, cal))
        for i in s.installments.indices {
            let inst = s.installments[i]
            #expect(inst.index == i + 1)
            #expect(inst.principal == 10_000_000)
            #expect(inst.interest == Int64(12 - i) * 100_000)
            #expect(inst.total == inst.principal + inst.interest)
            #expect(inst.remainingBalance == Int64(11 - i) * 10_000_000)
        }
        #expect(s.totalInterest == 7_800_000)
        #expect(s.totalPaid == 127_800_000)
        #expect(s.payoffDate == loanDate(2026, 1, 20, cal))
    }

    // Principal that does not divide evenly: equal parts for all but the
    // last installment, which clears the remainder exactly.
    @Test func lastInstallmentClearsRemainder() throws {
        let s = try makeSchedule(
            principal: 100_000_001, months: 12,
            start: loanDate(2025, 1, 15, cal),
            method: .equalPrincipal, basis: .monthly,
            rates: [(1, 12)], calendar: cal
        )
        for i in 0..<11 {
            #expect(s.installments[i].principal == 8_333_333)
        }
        #expect(s.installments[11].principal == 8_333_338)
        #expect(s.installments.reduce(0) { $0 + $1.principal } == 100_000_001)
        #expect(s.installments[11].remainingBalance == 0)
    }
}

struct LoanAnnuityTests {
    private let cal = loanCal()

    // 120tr over 12 months at 12%/yr, r = 1%/period.
    // Annuity payment P = B·r / (1 − (1+r)^−n) = 10,661,855 đ.
    @Test func levelPayments() throws {
        let s = try makeSchedule(
            principal: 120_000_000, months: 12,
            start: loanDate(2025, 1, 15, cal),
            method: .annuity, basis: .monthly,
            rates: [(1, 12)], calendar: cal
        )
        #expect(s.installments.count == 12)
        let first = s.installments[0].total
        #expect(first == 10_661_855)
        for inst in s.installments.dropLast() {
            #expect(inst.total == first)
        }
        #expect(s.installments[0].interest == 1_200_000)
        #expect(s.installments[0].principal == first - 1_200_000)
        // Last installment clears the balance exactly, so its total may
        // differ from the level payment by a few đồng.
        #expect(abs(s.installments[11].total - first) < 100)
        #expect(s.installments.reduce(0) { $0 + $1.principal } == 120_000_000)
        #expect(s.installments[11].remainingBalance == 0)
    }

    // Zero rate: payment is just principal / months, no interest.
    @Test func zeroRate() throws {
        let s = try makeSchedule(
            principal: 120_000_000, months: 12,
            start: loanDate(2025, 1, 15, cal),
            method: .annuity, basis: .monthly,
            rates: [(1, 0)], calendar: cal
        )
        #expect(s.installments.allSatisfy { $0.interest == 0 })
        #expect(s.installments.allSatisfy { $0.principal == 10_000_000 && $0.total == 10_000_000 })
        #expect(s.totalInterest == 0)
        #expect(s.totalPaid == 120_000_000)
    }
}

struct LoanRateChangeTests {
    private let cal = loanCal()

    // 240tr over 24 months: 12% for installments 1-12, 18% from 13.
    @Test func equalPrincipalRateChange() throws {
        let s = try makeSchedule(
            principal: 240_000_000, months: 24,
            start: loanDate(2025, 1, 15, cal),
            method: .equalPrincipal, basis: .monthly,
            rates: [(1, 12), (13, 18)], calendar: cal
        )
        #expect(s.installments.count == 24)
        #expect(s.installments.allSatisfy { $0.principal == 10_000_000 })
        // Before installment 12 the balance is 130tr → 1.3tr at 1%/month.
        #expect(s.installments[11].interest == 1_300_000)
        // Before installment 13 the balance is 120tr → 1.8tr at 1.5%/month.
        #expect(s.installments[12].interest == 1_800_000)
        #expect(s.installments.reduce(0) { $0 + $1.principal } == 240_000_000)
        #expect(s.installments[23].remainingBalance == 0)
    }

    // Same rate change under annuity: the payment is recomputed on the
    // remaining balance when the rate changes at installment 13.
    @Test func annuityRateChange() throws {
        let s = try makeSchedule(
            principal: 240_000_000, months: 24,
            start: loanDate(2025, 1, 15, cal),
            method: .annuity, basis: .monthly,
            rates: [(1, 12), (13, 18)], calendar: cal
        )
        #expect(s.installments.count == 24)
        let phaseOne = s.installments[0].total
        for inst in s.installments[0..<12] {
            #expect(inst.total == phaseOne)
        }
        let phaseTwo = s.installments[12].total
        #expect(phaseTwo != phaseOne)
        for inst in s.installments[12..<23] {
            #expect(inst.total == phaseTwo)
        }
        // Installment 13 interest is on the actual remaining balance at
        // the new 1.5%/month rate.
        let balanceAfter12 = s.balance(afterInstallmentsPaid: 12)
        #expect(s.installments[12].interest
                == Int64((Double(balanceAfter12) * 0.015).rounded(.toNearestOrAwayFromZero)))
        #expect(s.installments.reduce(0) { $0 + $1.principal } == 240_000_000)
        #expect(s.installments[23].remainingBalance == 0)
    }
}

struct LoanActual365Tests {
    private let cal = loanCal()

    // 365tr at 7.3%/yr actual/365 → 73,000 đ/day on the full balance.
    // Periods from the 15th to the 15th: 31, 28, 31, 30, 31 days.
    @Test func realDayCounts() throws {
        let s = try makeSchedule(
            principal: 365_000_000, months: 5,
            start: loanDate(2025, 1, 15, cal), paymentDay: 15,
            method: .equalPrincipal, basis: .actual365,
            rates: [(1, 7.3)], calendar: cal
        )
        #expect(s.installments.map(\.principal) == Array(repeating: 73_000_000, count: 5))
        #expect(s.installments.map(\.interest) == [
            2_263_000,  // 365tr × 0.02%/day × 31 days (Jan15→Feb15)
            1_635_200,  // 292tr × 0.02%/day × 28 days (Feb15→Mar15)
            1_357_800,  // 219tr × 0.02%/day × 31 days (Mar15→Apr15)
            876_000,    // 146tr × 0.02%/day × 30 days (Apr15→May15)
            452_600,    // 73tr  × 0.02%/day × 31 days (May15→Jun15)
        ])
        #expect(s.totalInterest == 6_584_600)
    }

    // Identical loan disbursed a month later: same principal and rate,
    // only the day count differs (31 vs 28 days for the first period).
    @Test func shorterPeriodsCostLess() throws {
        let jan = try makeSchedule(
            principal: 365_000_000, months: 5,
            start: loanDate(2025, 1, 15, cal), paymentDay: 15,
            method: .equalPrincipal, basis: .actual365,
            rates: [(1, 7.3)], calendar: cal
        )
        let feb = try makeSchedule(
            principal: 365_000_000, months: 5,
            start: loanDate(2025, 2, 15, cal), paymentDay: 15,
            method: .equalPrincipal, basis: .actual365,
            rates: [(1, 7.3)], calendar: cal
        )
        #expect(jan.installments[0].interest == 73_000 * 31)
        #expect(feb.installments[0].interest == 73_000 * 28)
    }
}

struct LoanDueDateTests {
    private let cal = loanCal()

    // First due date is the first payment day at least ~1 month after
    // disbursement: Jan 5 + day 20 → Feb 20, not Jan 20.
    @Test func firstDueIsAtLeastOneMonthOut() throws {
        let s = try makeSchedule(
            principal: 10_000_000, months: 2,
            start: loanDate(2025, 1, 5, cal), paymentDay: 20,
            method: .equalPrincipal, basis: .monthly,
            rates: [(1, 12)], calendar: cal
        )
        #expect(s.installments[0].dueDate == loanDate(2025, 2, 20, cal))
    }

    // Payment day already passed relative to the 1-month anchor pushes
    // the first due date into the following month: Jan 20 + day 10 → Mar 10.
    @Test func paymentDayBeforeAnchorPushesTwoMonths() throws {
        let s = try makeSchedule(
            principal: 10_000_000, months: 2,
            start: loanDate(2025, 1, 20, cal), paymentDay: 10,
            method: .equalPrincipal, basis: .monthly,
            rates: [(1, 12)], calendar: cal
        )
        #expect(s.installments[0].dueDate == loanDate(2025, 3, 10, cal))
        #expect(s.installments[1].dueDate == loanDate(2025, 4, 10, cal))
    }

    // Payment day 31 clamps to the last day of short months.
    @Test func paymentDay31ClampsToMonthEnd() throws {
        let s = try makeSchedule(
            principal: 10_000_000, months: 4,
            start: loanDate(2025, 1, 10, cal), paymentDay: 31,
            method: .equalPrincipal, basis: .monthly,
            rates: [(1, 12)], calendar: cal
        )
        #expect(s.installments.map(\.dueDate) == [
            loanDate(2025, 2, 28, cal),
            loanDate(2025, 3, 31, cal),
            loanDate(2025, 4, 30, cal),
            loanDate(2025, 5, 31, cal),
        ])
    }
}

struct LoanPrepaymentTests {
    private let cal = loanCal()

    // 120tr/12mo/12% + 30tr extra after installment 4.
    // Balance 80tr − 30tr = 50tr over the remaining 8 installments →
    // 6,250,000 đ/month, which divides exactly.
    @Test func midScheduleRecompute() throws {
        let s = try makeSchedule(
            principal: 120_000_000, months: 12,
            start: loanDate(2025, 1, 15, cal),
            method: .equalPrincipal, basis: .monthly,
            rates: [(1, 12)],
            prepayments: [(4, 30_000_000)], calendar: cal
        )
        #expect(s.installments.count == 12)  // original end date kept
        // First four installments are untouched.
        for i in 0..<4 {
            #expect(s.installments[i].principal == 10_000_000)
            #expect(s.installments[i].interest == Int64(12 - i) * 100_000)
        }
        // Remaining balance right after installment 4 includes the extra.
        #expect(s.installments[3].remainingBalance == 50_000_000)
        for i in 4..<12 {
            #expect(s.installments[i].principal == 6_250_000)
        }
        #expect(s.installments.map(\.interest)[4...] == [
            500_000, 437_500, 375_000, 312_500, 250_000, 187_500, 125_000, 62_500,
        ])
        #expect(s.extraPrincipalPaid == 30_000_000)
        // Interest: 1.2+1.1+1.0+0.9tr before, then 2.25tr on the 50tr
        // balance declining by 6.25tr/month.
        #expect(s.totalInterest == 6_450_000)
        #expect(s.totalPaid == 126_450_000)
        #expect(s.payoffDate == loanDate(2026, 1, 20, cal))
    }

    // An extra payment that clears the loan ends the schedule early.
    @Test func clearingPrepaymentEndsEarly() throws {
        let s = try makeSchedule(
            principal: 120_000_000, months: 12,
            start: loanDate(2025, 1, 15, cal),
            method: .equalPrincipal, basis: .monthly,
            rates: [(1, 12)],
            prepayments: [(6, 60_000_000)], calendar: cal
        )
        #expect(s.installments.count == 6)
        #expect(s.installments[5].remainingBalance == 0)
        #expect(s.extraPrincipalPaid == 60_000_000)
        // Interest for 6 declining-balance months: 1.2+1.1+1.0+0.9+0.8+0.7.
        #expect(s.totalInterest == 5_700_000)
        #expect(s.totalPaid == 60_000_000 + 5_700_000 + 60_000_000)
        #expect(s.payoffDate == s.installments[5].dueDate)
        #expect(s.balance(afterInstallmentsPaid: 6) == 0)
    }

    // Under annuity the level payment is recomputed after the extra;
    // scheduled principal parts still sum to principal minus the extra.
    @Test func annuityPrepayment() throws {
        let s = try makeSchedule(
            principal: 120_000_000, months: 12,
            start: loanDate(2025, 1, 15, cal),
            method: .annuity, basis: .monthly,
            rates: [(1, 12)],
            prepayments: [(6, 50_000_000)], calendar: cal
        )
        #expect(s.installments.count == 12)
        #expect(s.extraPrincipalPaid == 50_000_000)
        #expect(s.installments.reduce(0) { $0 + $1.principal } == 70_000_000)
        let first = s.installments[0].total
        for inst in s.installments[0..<6] {
            #expect(inst.total == first)
        }
        let lowered = s.installments[6].total
        #expect(lowered != first)
        for inst in s.installments[6..<11] {
            #expect(inst.total == lowered)
        }
        #expect(s.installments[11].remainingBalance == 0)
    }
}

struct LoanHelperTests {
    private let cal = loanCal()

    @Test func balanceNextInstallmentAndPayoff() throws {
        let s = try makeSchedule(
            principal: 120_000_000, months: 12,
            start: loanDate(2025, 1, 15, cal),
            method: .equalPrincipal, basis: .monthly,
            rates: [(1, 12)], calendar: cal
        )
        #expect(s.balance(afterInstallmentsPaid: 0) == 120_000_000)
        #expect(s.balance(afterInstallmentsPaid: 5) == 70_000_000)
        #expect(s.balance(afterInstallmentsPaid: 12) == 0)
        #expect(s.balance(afterInstallmentsPaid: 99) == 0)

        #expect(s.nextInstallment(dueOnOrAfter: loanDate(2025, 1, 15, cal), calendar: cal)?.index == 1)
        // An installment due today is still "next".
        #expect(s.nextInstallment(dueOnOrAfter: loanDate(2025, 2, 20, cal), calendar: cal)?.index == 1)
        #expect(s.nextInstallment(dueOnOrAfter: loanDate(2025, 2, 21, cal), calendar: cal)?.index == 2)
        #expect(s.nextInstallment(dueOnOrAfter: loanDate(2026, 2, 1, cal), calendar: cal) == nil)

        #expect(s.payoffDate == loanDate(2026, 1, 20, cal))
    }
}

struct LoanValidationTests {
    private let cal = loanCal()

    @Test func rejectsBadInputs() {
        let start = loanDate(2025, 1, 15, cal)
        #expect(throws: LoanScheduleError.invalidPrincipal) {
            try makeSchedule(principal: 0, months: 12, start: start,
                             method: .annuity, basis: .monthly,
                             rates: [(1, 12)], calendar: cal)
        }
        #expect(throws: LoanScheduleError.invalidTermMonths) {
            try makeSchedule(principal: 1_000_000, months: 0, start: start,
                             method: .annuity, basis: .monthly,
                             rates: [(1, 12)], calendar: cal)
        }
        for day in [0, 32] {
            #expect(throws: LoanScheduleError.invalidPaymentDay) {
                try makeSchedule(principal: 1_000_000, months: 12, start: start,
                                 paymentDay: day, method: .annuity, basis: .monthly,
                                 rates: [(1, 12)], calendar: cal)
            }
        }
        #expect(throws: LoanScheduleError.missingInitialRatePeriod) {
            try makeSchedule(principal: 1_000_000, months: 12, start: start,
                             method: .annuity, basis: .monthly,
                             rates: [], calendar: cal)
        }
        #expect(throws: LoanScheduleError.missingInitialRatePeriod) {
            try makeSchedule(principal: 1_000_000, months: 12, start: start,
                             method: .annuity, basis: .monthly,
                             rates: [(2, 12)], calendar: cal)
        }
        #expect(throws: LoanScheduleError.invalidAnnualRate) {
            try makeSchedule(principal: 1_000_000, months: 12, start: start,
                             method: .annuity, basis: .monthly,
                             rates: [(1, -1)], calendar: cal)
        }
    }
}
