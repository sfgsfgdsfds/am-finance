import Foundation
import FinanceCore

/// One day section of the transactions list: the rows of a single calendar
/// day in `AppCalendar.vietnam` plus that day's income and expense totals.
/// Transfers never count towards the totals.
struct TransactionListDaySection: Identifiable, Equatable {
    /// Start of day in the app calendar — also the section's identity.
    let day: Date
    var rows: [TransactionListRow]
    let incomeTotal: Int64
    let expenseTotal: Int64

    var id: Date { day }
}

/// Pure grouping and totalling for the transactions list. All day/month
/// boundaries come from the injected calendar — `AppCalendar.vietnam` in
/// the app, pinned in tests.
enum TransactionListGrouping {

    /// `[start, end)` of the calendar month containing `date` — the bounds
    /// used by the visible-month fetch predicate and the header totals.
    static func monthInterval(
        containing date: Date,
        calendar: Calendar = AppCalendar.vietnam
    ) -> (start: Date, end: Date) {
        let start = calendar.dateInterval(of: .month, for: date)?.start
            ?? calendar.startOfDay(for: date)
        let end = calendar.date(byAdding: .month, value: 1, to: start) ?? start
        return (start, end)
    }

    /// First day of the month `offset` months away from `date`'s month —
    /// what the previous/next month switcher jumps to.
    static func shiftingMonth(
        of date: Date,
        by offset: Int,
        calendar: Calendar = AppCalendar.vietnam
    ) -> Date {
        let start = monthInterval(containing: date, calendar: calendar).start
        return calendar.date(byAdding: .month, value: offset, to: start) ?? start
    }

    /// Sum of income amounts — transfers excluded.
    static func incomeTotal(of rows: [TransactionListRow]) -> Int64 {
        rows.reduce(0) { $0 + ($1.kind == .income ? $1.amount : 0) }
    }

    /// Sum of expense amounts — transfers excluded.
    static func expenseTotal(of rows: [TransactionListRow]) -> Int64 {
        rows.reduce(0) { $0 + ($1.kind == .expense ? $1.amount : 0) }
    }

    /// Income minus expense for the rows.
    static func netTotal(of rows: [TransactionListRow]) -> Int64 {
        incomeTotal(of: rows) - expenseTotal(of: rows)
    }

    /// Day buckets, newest day first, each day's rows newest first.
    static func sections(
        for rows: [TransactionListRow],
        calendar: Calendar = AppCalendar.vietnam
    ) -> [TransactionListDaySection] {
        var byDay: [Date: [TransactionListRow]] = [:]
        for row in rows {
            byDay[calendar.startOfDay(for: row.date), default: []].append(row)
        }
        return byDay
            .map { day, dayRows in
                TransactionListDaySection(
                    day: day,
                    rows: sortRows(dayRows),
                    incomeTotal: incomeTotal(of: dayRows),
                    expenseTotal: expenseTotal(of: dayRows)
                )
            }
            .sorted { $0.day > $1.day }
    }

    /// Newest first; id breaks ties so the order is deterministic.
    static func sortRows(_ rows: [TransactionListRow]) -> [TransactionListRow] {
        rows.sorted {
            if $0.date != $1.date { return $0.date > $1.date }
            return $0.id.uuidString > $1.id.uuidString
        }
    }
}
