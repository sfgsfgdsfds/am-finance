import Foundation
import FinanceCore

/// Everything `CreditCardDetailView` renders, computed in one pure builder:
/// debt and limit numbers, the last closed statement, the open cycle and all
/// Vietnamese labels — so the whole screen is testable without SwiftUI or
/// SwiftData. All inputs are plain values (`openingBalance` signed đồng,
/// `entries` signed card deltas, `config`, `limit`, `now`, `calendar`).
struct CreditCardOverview: Equatable {

    /// Debt currently carried on the card (đồng ≥ 0).
    let debt: Int64
    /// Amount the card is in credit (đồng ≥ 0) — the user overpaid.
    let creditBalance: Int64
    let creditLimit: Int64?
    /// `creditLimit - debt` clamped at 0; nil when the card has no limit.
    let availableCredit: Int64?
    /// `debt / creditLimit`; 0 when there is no limit, can exceed 1.
    let utilization: Double
    let utilizationLevel: CreditCardUtilizationLevel
    /// Utilization as a rounded percent label, e.g. "42%".
    let utilizationText: String

    let lastStatement: CreditCardStatementInfo
    let openCycle: CreditCardOpenCycleInfo

    /// Builds the overview. `openingBalance` is the account's signed balance
    /// (negative = debt); FinanceCore works in debt terms, so it is negated
    /// into `balanceBefore`.
    static func build(
        openingBalance: Int64,
        entries: [CreditCardEntry],
        config: CreditCardCycleConfig,
        creditLimit: Int64?,
        now: Date,
        calendar: Calendar = AppCalendar.vietnam
    ) -> CreditCardOverview {
        let balanceBefore = negate(openingBalance)
        let debt = CreditCardCycleConfig.currentDebt(
            entries: entries, balanceBefore: balanceBefore
        )
        let rawDebt = entries.reduce(balanceBefore) { $0 - $1.delta }
        let creditBalance = max(0, negate(rawDebt))
        let limit = creditLimit.flatMap { $0 > 0 ? $0 : nil }
        let utilization = CreditCardCycleConfig.utilization(
            entries: entries, balanceBefore: balanceBefore, creditLimit: limit
        )

        let lastCycle = config.lastClosedCycle(asOf: now, calendar: calendar)
        let statement = config.statement(
            for: lastCycle, entries: entries,
            balanceBefore: balanceBefore, asOf: now, calendar: calendar
        )
        let daysUntilDue = config.daysUntilDue(from: now, calendar: calendar)

        let openCycle = config.cycle(containing: now, calendar: calendar)
        let openStatement = config.statement(
            for: openCycle, entries: entries,
            balanceBefore: balanceBefore, asOf: now, calendar: calendar
        )
        let daysUntilClosing = calendar.dateComponents(
            [.day], from: calendar.startOfDay(for: now), to: openCycle.end
        ).day ?? 0

        return CreditCardOverview(
            debt: debt,
            creditBalance: creditBalance,
            creditLimit: limit,
            availableCredit: limit.map { max(0, $0 - debt) },
            utilization: utilization,
            utilizationLevel: CreditCardUtilizationLevel(utilization),
            utilizationText: "\(Int((utilization * 100).rounded()))%",
            lastStatement: CreditCardStatementInfo(
                cycle: lastCycle,
                periodText: periodText(lastCycle, calendar: calendar),
                balance: statement.balance,
                paidSinceClosing: statement.balance - statement.amountDue,
                amountDue: statement.amountDue,
                minimumPayment: statement.minimumPayment(percent: 5, floor: 50_000),
                paidInFull: statement.paidInFull,
                dueDate: lastCycle.dueDate,
                dueDateText: full(lastCycle.dueDate, calendar: calendar),
                daysUntilDue: daysUntilDue,
                isOverdue: daysUntilDue < 0 && !statement.paidInFull,
                dueStatusText: dueStatusText(daysUntilDue: daysUntilDue)
            ),
            openCycle: CreditCardOpenCycleInfo(
                cycle: openCycle,
                periodText: periodText(openCycle, calendar: calendar),
                spending: openStatement.spending,
                closingDate: openCycle.end,
                closingDateText: full(openCycle.end, calendar: calendar),
                daysUntilClosing: max(0, daysUntilClosing),
                closingStatusText: countdownText(days: max(0, daysUntilClosing))
            )
        )
    }

    /// "Còn 5 ngày", "Hôm nay", "Quá hạn 3 ngày" — the countdown shown next
    /// to the statement due date.
    static func dueStatusText(daysUntilDue days: Int) -> String {
        if days < 0 { return "Quá hạn \(-days) ngày" }
        return countdownText(days: days)
    }

    /// "Còn n ngày" / "Hôm nay" countdown shared by due and closing dates.
    static func countdownText(days: Int) -> String {
        days == 0 ? "Hôm nay" : "Còn \(days) ngày"
    }

    /// "21/05 – 20/06/2026": short start, full end so a year boundary is
    /// never ambiguous.
    private static func periodText(_ cycle: CreditCardCycle, calendar: Calendar) -> String {
        "\(AppDateFormat.shortDate(cycle.start, calendar: calendar)) – \(full(cycle.end, calendar: calendar))"
    }

    /// "dd/MM/yyyy" in the caller's calendar.
    private static func full(_ date: Date, calendar: Calendar) -> String {
        let formatter = DateFormatter()
        formatter.calendar = calendar
        formatter.timeZone = calendar.timeZone
        formatter.locale = calendar.locale
        formatter.dateFormat = "dd/MM/yyyy"
        return formatter.string(from: date)
    }

    private static func negate(_ value: Int64) -> Int64 {
        value == .min ? .max : -value
    }
}

/// Numbers and labels for the last closed statement — the bill the user is
/// currently paying toward.
struct CreditCardStatementInfo: Equatable {
    let cycle: CreditCardCycle
    /// "21/05 – 20/06/2026".
    let periodText: String
    /// Debt at closing (đồng ≥ 0).
    let balance: Int64
    /// Payments/refunds dated after closing, capped at `balance` (đồng ≥ 0).
    let paidSinceClosing: Int64
    /// What still must be paid (đồng ≥ 0).
    let amountDue: Int64
    /// Estimated minimum payment (5%, floor 50.000 ₫).
    let minimumPayment: Int64
    let paidInFull: Bool
    let dueDate: Date
    /// "dd/MM/yyyy".
    let dueDateText: String
    /// Days until the due date; negative when overdue.
    let daysUntilDue: Int
    /// Past due and still owing — the label turns the expense color.
    let isOverdue: Bool
    /// "Còn 5 ngày" / "Hôm nay" / "Quá hạn 3 ngày".
    let dueStatusText: String
}

/// Numbers and labels for the statement cycle still open.
struct CreditCardOpenCycleInfo: Equatable {
    let cycle: CreditCardCycle
    /// "21/06 – 20/07/2026".
    let periodText: String
    /// Purchases and fees dated inside the cycle so far (đồng ≥ 0).
    let spending: Int64
    let closingDate: Date
    /// "dd/MM/yyyy".
    let closingDateText: String
    let daysUntilClosing: Int
    /// "Còn 5 ngày" / "Hôm nay".
    let closingStatusText: String
}

/// Utilization buckets driving the header bar color: neutral below 50%,
/// a caution band at 50–70%, warning color from 70%.
enum CreditCardUtilizationLevel: Equatable, Sendable {
    case low
    case medium
    case high

    init(_ utilization: Double) {
        switch utilization {
        case ..<0.5: self = .low
        case ..<0.7: self = .medium
        default: self = .high
        }
    }
}

extension Account {
    /// The card's movements as FinanceCore entries: the signed delta of every
    /// transaction the account participates in, as source or as transfer
    /// destination — negative for spending (debt grows), positive for
    /// payments and refunds.
    var creditCardEntries: [CreditCardEntry] {
        var seen = Set<UUID>()
        var entries: [CreditCardEntry] = []
        for transaction in (transactions ?? []) + (incomingTransfers ?? []) {
            guard seen.insert(transaction.id).inserted else { continue }
            let role: LedgerMath.Role = transaction.account === self ? .source : .destination
            let delta = LedgerMath.delta(
                kind: transaction.kind, amount: transaction.amount, role: role
            )
            if delta != 0 {
                entries.append(CreditCardEntry(date: transaction.date, delta: delta))
            }
        }
        return entries
    }

    /// Statement-cycle config from the card's fields; nil while either
    /// `statementDay` or `graceDays` is unset.
    var creditCardCycleConfig: CreditCardCycleConfig? {
        guard let statementDay, let graceDays else { return nil }
        return CreditCardCycleConfig(statementDay: statementDay, graceDays: graceDays)
    }
}
