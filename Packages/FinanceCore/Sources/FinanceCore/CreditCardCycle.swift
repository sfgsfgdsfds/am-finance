import Foundation

/// Statement-cycle math for one credit card.
///
/// `statementDay` is the day of month the statement closes (1...31); in
/// shorter months the closing falls on the last day of the month.
/// `graceDays` is the number of days after the closing date until payment
/// is due (15, 25, …).
///
/// Every method takes an explicit `Calendar` — callers pass a Gregorian
/// calendar in the card's time zone (Asia/Ho_Chi_Minh); there is no
/// global default. All lookups work at day granularity: the time of day
/// inside a `Date` never changes which cycle it belongs to.
public struct CreditCardCycleConfig: Equatable, Sendable {

    /// Day of month the statement closes, clamped to 1...31.
    public let statementDay: Int
    /// Days between the closing date and the payment due date, clamped
    /// to ≥ 0.
    public let graceDays: Int

    public init(statementDay: Int, graceDays: Int) {
        self.statementDay = min(31, max(1, statementDay))
        self.graceDays = max(0, graceDays)
    }

    // MARK: - Cycle lookup

    /// First closing date on or after `date`'s calendar day. The result
    /// is that day's start of day, so when `date` itself is a closing
    /// day the result may precede it by a few hours.
    public func nextClosingDate(onOrAfter date: Date, calendar: Calendar) -> Date {
        let day = calendar.startOfDay(for: date)
        let closing = closingDate(inMonthOf: day, calendar: calendar)
        guard closing < day else { return closing }
        let nextMonth = calendar.date(byAdding: .month, value: 1,
                                      to: firstOfMonth(day, calendar: calendar))!
        return closingDate(inMonthOf: nextMonth, calendar: calendar)
    }

    /// The cycle whose [start, end] day range contains `date`'s calendar
    /// day.
    public func cycle(containing date: Date, calendar: Calendar) -> CreditCardCycle {
        cycle(endingOn: nextClosingDate(onOrAfter: date, calendar: calendar),
              calendar: calendar)
    }

    /// The cycle immediately before `cycle` — it ends the day before
    /// `cycle.start`.
    public func previousCycle(before cycle: CreditCardCycle,
                              calendar: Calendar) -> CreditCardCycle {
        let previousEnd = calendar.date(byAdding: .day, value: -1, to: cycle.start)!
        return self.cycle(endingOn: previousEnd, calendar: calendar)
    }

    /// The cycle immediately after `cycle` — it starts the day after
    /// `cycle.end`.
    public func nextCycle(after cycle: CreditCardCycle,
                          calendar: Calendar) -> CreditCardCycle {
        let nextStart = calendar.date(byAdding: .day, value: 1, to: cycle.end)!
        return self.cycle(containing: nextStart, calendar: calendar)
    }

    /// The most recent statement cycle that already closed before
    /// `date`'s calendar day — the card's current bill.
    public func lastClosedCycle(asOf date: Date, calendar: Calendar) -> CreditCardCycle {
        previousCycle(before: cycle(containing: date, calendar: calendar),
                      calendar: calendar)
    }

    /// Due date of the last closed statement — the deadline the
    /// cardholder is currently paying toward. It lies in the past when
    /// that bill is overdue.
    public func currentDueDate(asOf date: Date, calendar: Calendar) -> Date {
        lastClosedCycle(asOf: date, calendar: calendar).dueDate
    }

    /// First payment due date on or after `date`'s calendar day: the
    /// current bill's due date while it is still upcoming, otherwise the
    /// open cycle's due date.
    public func nextDueDate(onOrAfter date: Date, calendar: Calendar) -> Date {
        let due = currentDueDate(asOf: date, calendar: calendar)
        if due >= calendar.startOfDay(for: date) { return due }
        return cycle(containing: date, calendar: calendar).dueDate
    }

    /// Whole days from `date`'s calendar day until the current bill's
    /// due date — negative when that date has passed (overdue).
    public func daysUntilDue(from date: Date, calendar: Calendar) -> Int {
        let due = currentDueDate(asOf: date, calendar: calendar)
        let day = calendar.startOfDay(for: date)
        return calendar.dateComponents([.day], from: day, to: due).day ?? 0
    }

    // MARK: - Statement amounts

    /// Totals for `cycle`, built from `entries` and the card's debt
    /// `balanceBefore` — đồng owed before the first entry (negative when
    /// the card was in credit).
    ///
    /// `balance` counts every entry dated up to and including the
    /// closing day; `spending`/`payments` only entries inside the cycle.
    /// `amountDue` is `balance` reduced by payments and refunds dated
    /// after `cycle.end` up to `asOf`'s calendar day, never below 0.
    public func statement(for cycle: CreditCardCycle,
                          entries: [CreditCardEntry],
                          balanceBefore: Int64,
                          asOf: Date,
                          calendar: Calendar) -> CreditCardStatement {
        let asOfDay = calendar.startOfDay(for: asOf)
        var spending: Int64 = 0
        var payments: Int64 = 0
        var debt = balanceBefore
        var paidAfterClose: Int64 = 0
        for entry in entries {
            let day = calendar.startOfDay(for: entry.date)
            if day <= cycle.end {
                debt = Self.saturatingAdd(debt, Self.saturatingNegate(entry.delta))
                guard day >= cycle.start else { continue }
                if entry.delta < 0 {
                    spending = Self.saturatingAdd(spending, Self.saturatingNegate(entry.delta))
                } else if entry.delta > 0 {
                    payments = Self.saturatingAdd(payments, entry.delta)
                }
            } else if day <= asOfDay, entry.delta > 0 {
                paidAfterClose = Self.saturatingAdd(paidAfterClose, entry.delta)
            }
        }
        let balance = max(0, debt)
        let credit = max(0, Self.saturatingNegate(debt))
        let amountDue = paidAfterClose >= balance ? 0 : balance - paidAfterClose
        return CreditCardStatement(
            cycle: cycle,
            spending: spending,
            payments: payments,
            balance: balance,
            credit: credit,
            amountDue: amountDue,
            paidInFull: amountDue == 0
        )
    }

    /// Statement for the most recently closed cycle as of `date` — the
    /// bill the cardholder is currently paying.
    public func currentStatement(asOf date: Date,
                                 entries: [CreditCardEntry],
                                 balanceBefore: Int64,
                                 calendar: Calendar) -> CreditCardStatement {
        statement(for: lastClosedCycle(asOf: date, calendar: calendar),
                  entries: entries, balanceBefore: balanceBefore,
                  asOf: date, calendar: calendar)
    }

    // MARK: - Account-wide amounts

    /// Debt currently carried on the card: `balanceBefore` minus all
    /// entry deltas, clamped at 0 (a card in credit owes nothing).
    /// Saturates at Int64 extremes rather than overflowing.
    public static func currentDebt(entries: [CreditCardEntry],
                                   balanceBefore: Int64) -> Int64 {
        var debt = balanceBefore
        for entry in entries {
            debt = saturatingAdd(debt, saturatingNegate(entry.delta))
        }
        return max(0, debt)
    }

    /// `currentDebt / creditLimit`. Returns 0 when the card has no limit
    /// (`nil` or ≤ 0) or is in credit; can exceed 1 when over the limit.
    public static func utilization(entries: [CreditCardEntry],
                                   balanceBefore: Int64,
                                   creditLimit: Int64?) -> Double {
        guard let limit = creditLimit, limit > 0 else { return 0 }
        return Double(currentDebt(entries: entries, balanceBefore: balanceBefore)) / Double(limit)
    }

    /// Minimum payment on `amountDue`: `percent` (whole percent — 5
    /// means 5%) of it rounded up to whole đồng, raised to at least
    /// `floor`, and never more than `amountDue` itself. 0 when nothing
    /// is due.
    public static func minimumPayment(amountDue: Int64,
                                      percent: Int,
                                      floor: Int64) -> Int64 {
        guard amountDue > 0 else { return 0 }
        let (product, overflow) =
            amountDue.multipliedReportingOverflow(by: Int64(max(0, percent)))
        // An overflowing percent is far above 100%, so the percent term
        // exceeds amountDue and the cap applies anyway.
        let percentDue = overflow
            ? amountDue
            : product / 100 + (product % 100 == 0 ? 0 : 1)
        return min(amountDue, max(max(0, floor), percentDue))
    }

    // MARK: - Private calendar helpers

    /// First day of the month containing `date`, at start of day.
    private func firstOfMonth(_ date: Date, calendar: Calendar) -> Date {
        var comps = calendar.dateComponents([.year, .month], from: date)
        comps.day = 1
        return calendar.date(from: comps)!
    }

    /// Closing date in the month containing `date`: `statementDay`, or
    /// the last day of the month when the month is shorter.
    private func closingDate(inMonthOf date: Date, calendar: Calendar) -> Date {
        var comps = calendar.dateComponents([.year, .month], from: date)
        comps.day = 1
        let first = calendar.date(from: comps)!
        let daysInMonth = calendar.range(of: .day, in: .month, for: first)!.count
        comps.day = min(statementDay, daysInMonth)
        return calendar.date(from: comps)!
    }

    /// The cycle ending on `closing`, which must be an actual closing
    /// date produced by `closingDate(inMonthOf:calendar:)`.
    private func cycle(endingOn closing: Date, calendar: Calendar) -> CreditCardCycle {
        let monthBefore = calendar.date(byAdding: .day, value: -1,
                                        to: firstOfMonth(closing, calendar: calendar))!
        let previousClosing = closingDate(inMonthOf: monthBefore, calendar: calendar)
        let start = calendar.date(byAdding: .day, value: 1, to: previousClosing)!
        let dueDate = calendar.date(byAdding: .day, value: graceDays, to: closing)!
        return CreditCardCycle(start: start, end: closing, dueDate: dueDate)
    }

    // MARK: - Private saturating integer math

    private static func saturatingAdd(_ a: Int64, _ b: Int64) -> Int64 {
        let (result, overflow) = a.addingReportingOverflow(b)
        return overflow ? (a < 0 ? .min : .max) : result
    }

    private static func saturatingNegate(_ value: Int64) -> Int64 {
        value == .min ? .max : -value
    }
}

/// One statement cycle: the period between two consecutive closing
/// dates. `start` is the day after the previous closing date, `end` is
/// the closing day itself (inclusive), `dueDate` is the payment deadline
/// (`end` + graceDays). All three are start-of-day instants in the
/// calendar that produced them.
public struct CreditCardCycle: Equatable, Sendable {
    public let start: Date
    public let end: Date
    public let dueDate: Date

    public init(start: Date, end: Date, dueDate: Date) {
        self.start = start
        self.end = end
        self.dueDate = dueDate
    }

    /// True when `date`'s calendar day lies inside [start, end]. An
    /// entry at 23:30 on the closing day still belongs to this cycle.
    public func contains(_ date: Date, calendar: Calendar) -> Bool {
        let day = calendar.startOfDay(for: date)
        return day >= start && day <= end
    }
}

/// One movement on the card account. `delta` is signed đồng: negative
/// for purchases and fees (debt grows), positive for payments and
/// refunds (debt shrinks).
public struct CreditCardEntry: Equatable, Sendable {
    public let date: Date
    public let delta: Int64

    public init(date: Date, delta: Int64) {
        self.date = date
        self.delta = delta
    }
}

/// Totals for one statement cycle, built by
/// `CreditCardCycleConfig.statement(for:entries:balanceBefore:asOf:calendar:)`.
public struct CreditCardStatement: Equatable, Sendable {
    /// The cycle this statement covers.
    public let cycle: CreditCardCycle
    /// Purchases and fees dated inside the cycle (đồng, ≥ 0).
    public let spending: Int64
    /// Payments and refunds dated inside the cycle (đồng, ≥ 0).
    public let payments: Int64
    /// Debt owed at closing (đồng, ≥ 0).
    public let balance: Int64
    /// Amount the card is in credit at closing (đồng, ≥ 0).
    public let credit: Int64
    /// `balance` minus payments/refunds dated after `cycle.end` up to
    /// the `asOf` day given to the builder (đồng, ≥ 0).
    public let amountDue: Int64
    /// True when nothing remains to pay (`amountDue == 0`).
    public let paidInFull: Bool

    public init(cycle: CreditCardCycle, spending: Int64, payments: Int64,
                balance: Int64, credit: Int64, amountDue: Int64,
                paidInFull: Bool) {
        self.cycle = cycle
        self.spending = spending
        self.payments = payments
        self.balance = balance
        self.credit = credit
        self.amountDue = amountDue
        self.paidInFull = paidInFull
    }

    /// Minimum payment on `amountDue`: `percent` (whole percent) of it
    /// rounded up to whole đồng, at least `floor`, never above
    /// `amountDue`.
    public func minimumPayment(percent: Int, floor: Int64) -> Int64 {
        CreditCardCycleConfig.minimumPayment(amountDue: amountDue,
                                             percent: percent, floor: floor)
    }
}
