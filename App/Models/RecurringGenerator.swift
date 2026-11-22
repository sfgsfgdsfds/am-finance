import Foundation
import SwiftData
import FinanceCore

/// Turns due occurrences of active, auto-creating `RecurringRule`s into real
/// `LedgerTransaction` rows. Runs on demand (e.g. at app launch) — it is not
/// wired anywhere yet.
///
/// For each rule the missed occurrences come from FinanceCore
/// `RecurrenceRule.missedOccurrences`: every occurrence on a day strictly
/// after `lastGeneratedDate`'s day up to `now`'s day. A rule that never ran
/// uses the day before its start as the baseline, so the start day itself is
/// due. Each run produces at most `perRunLimit` rows per rule and advances
/// `lastGeneratedDate` to the last produced occurrence, so a larger backlog
/// is picked up by the next run; when nothing was produced it advances to
/// `now` (never backwards). Running twice with the same `now` creates
/// nothing the second time.
enum RecurringGenerator {
    /// Safety cap on rows one run creates per rule.
    static let perRunLimit = 36

    /// Inserts one transaction per missed occurrence of every active
    /// autoCreate rule; returns how many rows were created.
    @discardableResult
    static func generateDueTransactions(
        in context: ModelContext,
        now: Date,
        calendar: Calendar = AppCalendar.vietnam
    ) throws -> Int {
        var created = 0
        // Predicate on the stored flags — an idle activation fetches only
        // the rules that could ever produce rows, not the whole table.
        let due = try context.fetch(FetchDescriptor<RecurringRule>(
            predicate: #Predicate { $0.isActive && $0.autoCreate }))
        for rule in due {
            guard let schedule = rule.recurrenceRule(calendar: calendar) else { continue }
            let baseline = rule.lastGeneratedDate
                ?? calendar.date(
                    byAdding: .day, value: -1,
                    to: calendar.startOfDay(for: rule.startDate))
                ?? rule.startDate
            let missed = try schedule.missedOccurrences(
                after: baseline, upTo: now,
                limit: perRunLimit, calendar: calendar
            )
            for date in missed {
                context.insert(LedgerTransaction(
                    kind: rule.kind,
                    amount: rule.amount,
                    date: date,
                    note: rule.note.isEmpty ? rule.title : rule.note,
                    account: rule.account,
                    toAccount: rule.toAccount,
                    category: rule.category,
                    business: rule.business
                ))
            }
            if let last = missed.last {
                rule.lastGeneratedDate = last
                created += missed.count
            } else if rule.lastGeneratedDate.map({ now > $0 }) ?? true {
                rule.lastGeneratedDate = now
            }
        }
        try context.save()
        return created
    }
}
