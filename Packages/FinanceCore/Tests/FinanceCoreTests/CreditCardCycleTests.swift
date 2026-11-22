import Foundation
import Testing
@testable import FinanceCore

// All helpers are private so nothing collides with other test files.

private let cal: Calendar = {
    var c = Calendar(identifier: .gregorian)
    c.timeZone = TimeZone(identifier: "Asia/Ho_Chi_Minh")!
    return c
}()

/// Start-of-day (or a given time) in the test calendar.
private func ymd(_ year: Int, _ month: Int, _ day: Int,
                 hour: Int = 0, minute: Int = 0) -> Date {
    cal.date(from: DateComponents(year: year, month: month, day: day,
                                  hour: hour, minute: minute))!
}

struct CreditCardCycleLookupTests {
    let config = CreditCardCycleConfig(statementDay: 20, graceDays: 15)

    @Test func cycleContainingDate() {
        let c = config.cycle(containing: ymd(2026, 7, 18), calendar: cal)
        #expect(c.start == ymd(2026, 6, 21))
        #expect(c.end == ymd(2026, 7, 20))
        #expect(c.dueDate == ymd(2026, 8, 4))  // Jul 20 + 15 days
    }

    @Test func cycleOnBoundaries() {
        let onStart = config.cycle(containing: ymd(2026, 6, 21), calendar: cal)
        #expect(onStart.start == ymd(2026, 6, 21))
        #expect(onStart.end == ymd(2026, 7, 20))

        let onEnd = config.cycle(containing: ymd(2026, 7, 20), calendar: cal)
        #expect(onEnd.start == ymd(2026, 6, 21))
        #expect(onEnd.end == ymd(2026, 7, 20))

        let dayAfter = config.cycle(containing: ymd(2026, 7, 21), calendar: cal)
        #expect(dayAfter.start == ymd(2026, 7, 21))
        #expect(dayAfter.end == ymd(2026, 8, 20))
    }

    @Test func statementDay31InFebruary() {
        let c31 = CreditCardCycleConfig(statementDay: 31, graceDays: 15)
        // Feb 2026 has 28 days: closing falls on the last day.
        let cycle = c31.cycle(containing: ymd(2026, 2, 10), calendar: cal)
        #expect(cycle.start == ymd(2026, 2, 1))   // day after Jan 31 close
        #expect(cycle.end == ymd(2026, 2, 28))
        #expect(cycle.dueDate == ymd(2026, 3, 15))
        #expect(c31.cycle(containing: ymd(2026, 2, 28), calendar: cal).end
                == ymd(2026, 2, 28))
        // Mar 1 opens the cycle that closes Mar 31.
        let next = c31.cycle(containing: ymd(2026, 3, 1), calendar: cal)
        #expect(next.start == ymd(2026, 3, 1))
        #expect(next.end == ymd(2026, 3, 31))
    }

    @Test func statementDay31In30DayMonth() {
        let c31 = CreditCardCycleConfig(statementDay: 31, graceDays: 15)
        let cycle = c31.cycle(containing: ymd(2026, 4, 15), calendar: cal)
        #expect(cycle.start == ymd(2026, 4, 1))   // day after Mar 31 close
        #expect(cycle.end == ymd(2026, 4, 30))
        #expect(cycle.dueDate == ymd(2026, 5, 15))
        // May 1 belongs to the cycle closing May 31.
        let next = c31.cycle(containing: ymd(2026, 5, 1), calendar: cal)
        #expect(next.start == ymd(2026, 5, 1))
        #expect(next.end == ymd(2026, 5, 31))
    }

    @Test func leapYearFebruary() {
        let c31 = CreditCardCycleConfig(statementDay: 31, graceDays: 15)
        // Feb 2024 has 29 days.
        let cycle = c31.cycle(containing: ymd(2024, 2, 15), calendar: cal)
        #expect(cycle.start == ymd(2024, 2, 1))
        #expect(cycle.end == ymd(2024, 2, 29))
        #expect(cycle.dueDate == ymd(2024, 3, 15))
        #expect(c31.cycle(containing: ymd(2024, 2, 29), calendar: cal).end
                == ymd(2024, 2, 29))
    }

    @Test func cycleCrossingNewYear() {
        let cycle = config.cycle(containing: ymd(2026, 1, 5), calendar: cal)
        #expect(cycle.start == ymd(2025, 12, 21))
        #expect(cycle.end == ymd(2026, 1, 20))
        #expect(cycle.dueDate == ymd(2026, 2, 4))

        let prev = config.previousCycle(before: cycle, calendar: cal)
        #expect(prev.start == ymd(2025, 11, 21))
        #expect(prev.end == ymd(2025, 12, 20))
    }

    @Test func previousAndNextCycle() {
        let cycle = config.cycle(containing: ymd(2026, 7, 10), calendar: cal)

        let prev = config.previousCycle(before: cycle, calendar: cal)
        #expect(prev.start == ymd(2026, 5, 21))
        #expect(prev.end == ymd(2026, 6, 20))
        #expect(prev.dueDate == ymd(2026, 7, 5))

        let next = config.nextCycle(after: cycle, calendar: cal)
        #expect(next.start == ymd(2026, 7, 21))
        #expect(next.end == ymd(2026, 8, 20))
        #expect(next.dueDate == ymd(2026, 9, 4))
    }

    @Test func nextClosingDateOnOrAfter() {
        #expect(config.nextClosingDate(onOrAfter: ymd(2026, 7, 1), calendar: cal)
                == ymd(2026, 7, 20))
        // A closing day maps to itself.
        #expect(config.nextClosingDate(onOrAfter: ymd(2026, 7, 20), calendar: cal)
                == ymd(2026, 7, 20))
        #expect(config.nextClosingDate(onOrAfter: ymd(2026, 7, 21), calendar: cal)
                == ymd(2026, 8, 20))

        let c31 = CreditCardCycleConfig(statementDay: 31, graceDays: 15)
        #expect(c31.nextClosingDate(onOrAfter: ymd(2026, 4, 10), calendar: cal)
                == ymd(2026, 4, 30))
        #expect(c31.nextClosingDate(onOrAfter: ymd(2026, 4, 30), calendar: cal)
                == ymd(2026, 4, 30))
        #expect(c31.nextClosingDate(onOrAfter: ymd(2026, 5, 1), calendar: cal)
                == ymd(2026, 5, 31))
    }

    @Test func daysUntilDue() {
        // statementDay 30 + graceDays 15 → the June statement (closed
        // Jun 30) is due Jul 15.
        let c30 = CreditCardCycleConfig(statementDay: 30, graceDays: 15)
        #expect(c30.currentDueDate(asOf: ymd(2026, 7, 10), calendar: cal)
                == ymd(2026, 7, 15))
        #expect(c30.daysUntilDue(from: ymd(2026, 7, 10), calendar: cal) == 5)
        #expect(c30.daysUntilDue(from: ymd(2026, 7, 15), calendar: cal) == 0)
        // Overdue once the due day has passed.
        #expect(c30.daysUntilDue(from: ymd(2026, 7, 18), calendar: cal) == -3)
        // After the July closing the current bill rolls forward: the
        // Jul 30 statement is due Aug 14.
        #expect(c30.currentDueDate(asOf: ymd(2026, 7, 31), calendar: cal)
                == ymd(2026, 8, 14))
        #expect(c30.daysUntilDue(from: ymd(2026, 7, 31), calendar: cal) == 14)
    }

    @Test func nextDueDateOnOrAfter() {
        let c30 = CreditCardCycleConfig(statementDay: 30, graceDays: 15)
        // While the current bill's due date is still upcoming it is next.
        #expect(c30.nextDueDate(onOrAfter: ymd(2026, 7, 10), calendar: cal)
                == ymd(2026, 7, 15))
        // Once it has passed, the open cycle's due date is next.
        #expect(c30.nextDueDate(onOrAfter: ymd(2026, 7, 16), calendar: cal)
                == ymd(2026, 8, 14))
    }
}

struct CreditCardStatementTests {
    let config = CreditCardCycleConfig(statementDay: 20, graceDays: 15)

    @Test func spendingPaymentsAndBalance() {
        // June cycle: May 21 – Jun 20.
        let entries = [
            CreditCardEntry(date: ymd(2026, 5, 25), delta: -500_000),
            CreditCardEntry(date: ymd(2026, 6, 10), delta: -1_000_000),
            CreditCardEntry(date: ymd(2026, 6, 15), delta: 300_000),   // payment
            CreditCardEntry(date: ymd(2026, 6, 20), delta: -100_000),  // closing day
            CreditCardEntry(date: ymd(2026, 6, 21), delta: -50_000),   // next cycle
        ]
        let cycle = config.cycle(containing: ymd(2026, 6, 1), calendar: cal)
        let s = config.statement(for: cycle, entries: entries, balanceBefore: 0,
                                 asOf: ymd(2026, 6, 25), calendar: cal)
        #expect(s.spending == 1_600_000)
        #expect(s.payments == 300_000)
        #expect(s.balance == 1_300_000)
        #expect(s.credit == 0)
        #expect(s.amountDue == 1_300_000)
        #expect(!s.paidInFull)
    }

    @Test func entryExactlyOnClosingDate() {
        let entries = [CreditCardEntry(date: ymd(2026, 7, 20), delta: -200_000)]
        let cycle = config.cycle(containing: ymd(2026, 7, 20), calendar: cal)
        #expect(cycle.contains(ymd(2026, 7, 20), calendar: cal))
        let s = config.statement(for: cycle, entries: entries, balanceBefore: 0,
                                 asOf: ymd(2026, 7, 25), calendar: cal)
        #expect(s.spending == 200_000)
        #expect(s.balance == 200_000)
    }

    @Test func lateEntryOnClosingDayStaysInCycle() {
        // 23:30 local (Asia/Ho_Chi_Minh) on the closing day still counts.
        let entry = CreditCardEntry(date: ymd(2026, 7, 20, hour: 23, minute: 30),
                                    delta: -90_000)
        let cycle = config.cycle(containing: ymd(2026, 7, 20), calendar: cal)
        #expect(cycle.contains(entry.date, calendar: cal))
        let s = config.statement(for: cycle, entries: [entry], balanceBefore: 0,
                                 asOf: ymd(2026, 7, 25), calendar: cal)
        #expect(s.spending == 90_000)
        // One minute after midnight lands in the next cycle.
        #expect(!cycle.contains(ymd(2026, 7, 21, hour: 0, minute: 1), calendar: cal))
    }

    @Test func paymentAfterClosingReducesAmountDue() {
        let entries = [
            CreditCardEntry(date: ymd(2026, 6, 10), delta: -1_000_000),
            CreditCardEntry(date: ymd(2026, 7, 5), delta: 400_000),  // after Jun 20
        ]
        let s = config.currentStatement(asOf: ymd(2026, 7, 10), entries: entries,
                                        balanceBefore: 0, calendar: cal)
        #expect(s.cycle.start == ymd(2026, 5, 21))
        #expect(s.cycle.end == ymd(2026, 6, 20))
        #expect(s.balance == 1_000_000)
        #expect(s.amountDue == 600_000)
        #expect(!s.paidInFull)
    }

    @Test func paymentOnClosingDayStaysInStatement() {
        // A payment dated on the closing day is inside the statement,
        // not a post-closing payment.
        let entries = [
            CreditCardEntry(date: ymd(2026, 6, 10), delta: -1_000_000),
            CreditCardEntry(date: ymd(2026, 6, 20), delta: 250_000),
        ]
        let s = config.currentStatement(asOf: ymd(2026, 7, 10), entries: entries,
                                        balanceBefore: 0, calendar: cal)
        #expect(s.payments == 250_000)
        #expect(s.balance == 750_000)
        #expect(s.amountDue == 750_000)
    }

    @Test func overpaymentGivesZeroDue() {
        let entries = [
            CreditCardEntry(date: ymd(2026, 6, 10), delta: -1_000_000),
            CreditCardEntry(date: ymd(2026, 7, 5), delta: 1_500_000),
        ]
        let s = config.currentStatement(asOf: ymd(2026, 7, 10), entries: entries,
                                        balanceBefore: 0, calendar: cal)
        #expect(s.amountDue == 0)
        #expect(s.paidInFull)
    }

    @Test func cardInCredit() {
        let entries = [
            CreditCardEntry(date: ymd(2026, 6, 10), delta: -300_000),
            CreditCardEntry(date: ymd(2026, 6, 18), delta: 500_000),  // refund
        ]
        let cycle = config.cycle(containing: ymd(2026, 6, 15), calendar: cal)
        let s = config.statement(for: cycle, entries: entries, balanceBefore: 0,
                                 asOf: ymd(2026, 6, 25), calendar: cal)
        #expect(s.balance == 0)
        #expect(s.credit == 200_000)
        #expect(s.amountDue == 0)
        #expect(s.paidInFull)
    }

    @Test func balanceBeforeFirstEntryCarries() {
        // Debt from before the first entry rolls into the statement.
        let entries = [CreditCardEntry(date: ymd(2026, 6, 5), delta: -200_000)]
        let s = config.currentStatement(asOf: ymd(2026, 6, 25), entries: entries,
                                        balanceBefore: 1_000_000, calendar: cal)
        #expect(s.balance == 1_200_000)
        #expect(s.amountDue == 1_200_000)
    }

    @Test func minimumPaymentFloorPercentAndCap() {
        // Percent wins over floor.
        #expect(CreditCardCycleConfig.minimumPayment(
            amountDue: 2_000_000, percent: 5, floor: 50_000) == 100_000)
        // Floor wins over percent.
        #expect(CreditCardCycleConfig.minimumPayment(
            amountDue: 300_000, percent: 5, floor: 50_000) == 50_000)
        // Rounded up to whole đồng: 5% of 123_456 = 6172.8 → 6173.
        #expect(CreditCardCycleConfig.minimumPayment(
            amountDue: 123_456, percent: 5, floor: 0) == 6_173)
        // Never more than the amount due.
        #expect(CreditCardCycleConfig.minimumPayment(
            amountDue: 40_000, percent: 5, floor: 50_000) == 40_000)
        #expect(CreditCardCycleConfig.minimumPayment(
            amountDue: 100_000, percent: 100, floor: 0) == 100_000)
        #expect(CreditCardCycleConfig.minimumPayment(
            amountDue: 0, percent: 5, floor: 50_000) == 0)

        // Same computation through the statement value.
        let entries = [CreditCardEntry(date: ymd(2026, 6, 10), delta: -2_000_000)]
        let s = config.currentStatement(asOf: ymd(2026, 7, 1), entries: entries,
                                        balanceBefore: 0, calendar: cal)
        #expect(s.minimumPayment(percent: 5, floor: 50_000) == 100_000)
    }

    @Test func utilization() {
        let entries = [CreditCardEntry(date: ymd(2026, 6, 10), delta: -2_500_000)]
        #expect(CreditCardCycleConfig.utilization(
            entries: entries, balanceBefore: 0, creditLimit: 10_000_000) == 0.25)
        // No limit → 0.
        #expect(CreditCardCycleConfig.utilization(
            entries: entries, balanceBefore: 0, creditLimit: nil) == 0)
        #expect(CreditCardCycleConfig.utilization(
            entries: entries, balanceBefore: 0, creditLimit: 0) == 0)
        // Card in credit → no debt → 0.
        let refund = [CreditCardEntry(date: ymd(2026, 6, 10), delta: 500_000)]
        #expect(CreditCardCycleConfig.utilization(
            entries: refund, balanceBefore: 0, creditLimit: 10_000_000) == 0)
        // Over the limit → > 1.
        let big = [CreditCardEntry(date: ymd(2026, 6, 10), delta: -12_000_000)]
        #expect(CreditCardCycleConfig.utilization(
            entries: big, balanceBefore: 0, creditLimit: 10_000_000) == 1.2)
        // balanceBefore counts as debt too.
        #expect(CreditCardCycleConfig.utilization(
            entries: [], balanceBefore: 1_000_000, creditLimit: 10_000_000) == 0.1)
    }
}
