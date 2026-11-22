import Foundation
import FinanceCore

/// One dated movement on a receivable account: an advance (money out to the
/// client — a transfer in, an income row or the opening balance) or a
/// settlement (a repayment transfer out or a write-off expense).
struct ReceivableMovement: Equatable, Sendable {
    var date: Date
    /// Positive đồng magnitude.
    var amount: Int64

    init(date: Date, amount: Int64) {
        self.date = date
        self.amount = amount
    }
}

/// What one client receivable account looks like right now: how much is
/// still owed, how much was ever advanced and settled, and which advance is
/// the oldest still unpaid. Settlements consume advances oldest-first
/// (FIFO), so partial repayments age correctly.
///
/// Pure value type — `make(account:)` maps a live `Account` once so views
/// and tests share the same numbers.
struct ReceivableSnapshot: Equatable, Sendable {
    /// Still owed by the client (đồng ≥ 0).
    var outstanding: Int64
    /// Sum of every advance ever recorded (đồng ≥ 0).
    var totalAdvanced: Int64
    /// Sum of every settlement — repayments plus write-offs (đồng ≥ 0).
    var totalRepaid: Int64
    /// Date of the earliest advance not fully consumed by settlements;
    /// nil when nothing is owed.
    var oldestUnpaidDate: Date?

    /// True when the client owes nothing.
    var isSettled: Bool { outstanding == 0 }

    /// Builds the snapshot from dated movements. Order does not matter —
    /// advances are sorted by date before the FIFO pass.
    static func make(
        advances: [ReceivableMovement],
        settlements: [ReceivableMovement]
    ) -> ReceivableSnapshot {
        let ordered = advances
            .filter { $0.amount > 0 }
            .sorted { $0.date < $1.date }
        let totalAdvanced = ordered.reduce(Int64(0)) { $0 + $1.amount }
        let totalRepaid = settlements.reduce(Int64(0)) { $0 + max(0, $1.amount) }

        // FIFO: each đồng settled eats the oldest unpaid advance first.
        var unpaid = ordered.map(\.amount)
        var toSettle = totalRepaid
        for index in unpaid.indices where toSettle > 0 {
            let used = min(unpaid[index], toSettle)
            unpaid[index] -= used
            toSettle -= used
        }

        let outstanding = max(Int64(0), totalAdvanced - totalRepaid)
        let oldestUnpaid = zip(ordered, unpaid)
            .first { $0.1 > 0 }?
            .0.date
        return ReceivableSnapshot(
            outstanding: outstanding,
            totalAdvanced: totalAdvanced,
            totalRepaid: totalRepaid,
            oldestUnpaidDate: outstanding > 0 ? oldestUnpaid : nil
        )
    }

    /// Maps a live receivable `Account`. Advances are the positive opening
    /// balance (dated at `createdAt`), incoming transfers and income rows;
    /// settlements are outgoing transfers and expense rows (write-offs and
    /// balance adjustments down).
    static func make(account: Account) -> ReceivableSnapshot {
        var advances: [ReceivableMovement] = []
        var settlements: [ReceivableMovement] = []
        if account.openingBalance > 0 {
            advances.append(ReceivableMovement(
                date: account.createdAt, amount: account.openingBalance))
        }
        for transaction in account.incomingTransfers ?? [] {
            advances.append(ReceivableMovement(
                date: transaction.date, amount: transaction.amount))
        }
        for transaction in account.transactions ?? [] {
            let movement = ReceivableMovement(
                date: transaction.date, amount: transaction.amount)
            switch transaction.kind {
            case .income:
                advances.append(movement)
            case .expense, .transfer:
                settlements.append(movement)
            }
        }
        return make(advances: advances, settlements: settlements)
    }

    /// Whole days since the oldest unpaid advance; nil when settled.
    func oldestUnpaidAgeDays(
        now: Date,
        calendar: Calendar = AppCalendar.vietnam
    ) -> Int? {
        oldestUnpaidDate.map {
            calendar.dateComponents(
                [.day],
                from: calendar.startOfDay(for: $0),
                to: calendar.startOfDay(for: now)
            ).day ?? 0
        }
    }

    /// True when the oldest unpaid advance is more than `thresholdDays` old —
    /// drives the "Quá 30 ngày" tag.
    func isOverdue(
        now: Date,
        calendar: Calendar = AppCalendar.vietnam,
        thresholdDays: Int = 30
    ) -> Bool {
        (oldestUnpaidAgeDays(now: now, calendar: calendar) ?? 0) > thresholdDays
    }
}
