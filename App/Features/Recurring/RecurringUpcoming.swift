import Foundation
import FinanceCore

/// Pure schedule maths behind `RecurringListView`: which occurrences fall
/// inside a window across lightweight rule values, expected-income and
/// -expense totals for that window, the next occurrence per rule and
/// finished detection. `Input` is a value-type mirror of the stored
/// `RecurringRule`, so every function here is testable without SwiftData.
enum RecurringUpcoming {

    /// Everything upcoming maths needs from a rule, as a value.
    struct Input: Equatable, Sendable {
        var id: UUID
        var title: String
        var kind: TransactionKind
        /// Positive đồng magnitude.
        var amount: Int64
        var frequency: RecurrenceFrequency
        /// Every N units of `frequency`; must be ≥ 1.
        var interval: Int
        var startDate: Date
        var endDate: Date?
        var maximumOccurrences: Int?
        /// Row badge, taken from the rule's category.
        var icon: String
        var colorHex: String
        var autoCreate: Bool
        var isActive: Bool

        init(
            id: UUID = UUID(),
            title: String,
            kind: TransactionKind,
            amount: Int64,
            frequency: RecurrenceFrequency,
            interval: Int = 1,
            startDate: Date,
            endDate: Date? = nil,
            maximumOccurrences: Int? = nil,
            icon: String = "",
            colorHex: String = "",
            autoCreate: Bool = true,
            isActive: Bool = true
        ) {
            self.id = id
            self.title = title
            self.kind = kind
            self.amount = amount
            self.frequency = frequency
            self.interval = interval
            self.startDate = startDate
            self.endDate = endDate
            self.maximumOccurrences = maximumOccurrences
            self.icon = icon
            self.colorHex = colorHex
            self.autoCreate = autoCreate
            self.isActive = isActive
        }

        /// The FinanceCore schedule — nil for inconsistent stored fields
        /// (interval < 1, end before start, invalid maximum).
        func schedule(calendar: Calendar) -> RecurrenceRule? {
            try? RecurrenceRule(
                frequency: frequency,
                interval: interval,
                startDate: startDate,
                endDate: endDate,
                maximumOccurrences: maximumOccurrences,
                calendar: calendar
            )
        }
    }

    /// One due date inside the upcoming window.
    struct Occurrence: Equatable, Identifiable, Sendable {
        let ruleID: UUID
        let title: String
        let kind: TransactionKind
        let amount: Int64
        let icon: String
        let colorHex: String
        /// The occurrence's calendar day (start-of-day in the calendar).
        let date: Date
        /// Whole days from today — 0 means "Hôm nay".
        let daysUntil: Int
        /// "Hôm nay" / "Còn n ngày".
        let statusText: String

        var id: String { "\(ruleID.uuidString)@\(date.timeIntervalSince1970)" }
    }

    /// Expected money movement across the window. Transfers are excluded:
    /// moving money between own accounts is neither income nor expense.
    struct Totals: Equatable, Sendable {
        var income: Int64 = 0
        var expense: Int64 = 0
        /// income − expense; negative means more is going out than in.
        var net: Int64 {
            let (net, overflow) = income.subtractingReportingOverflow(expense)
            return overflow ? (income < 0 ? .max : .min) : net
        }
    }

    /// The upcoming window: every calendar day from `now`'s day through
    /// `days` days later, both ends included — `daysUntil` runs 0...`days`.
    static func window(days: Int, now: Date, calendar: Calendar) -> ClosedRange<Date> {
        let today = calendar.startOfDay(for: now)
        let end = calendar.date(byAdding: .day, value: days, to: today) ?? today
        return today...end
    }

    /// Every active rule's occurrences inside `window`, chronological;
    /// same-day ties break by title then id so the list is stable. Paused
    /// rules and rules whose stored fields form no valid schedule are
    /// skipped; remind-only (`autoCreate == false`) rules still count —
    /// their occurrences are the reminders.
    static func occurrences(
        in rules: [Input],
        window: ClosedRange<Date>,
        now: Date,
        calendar: Calendar
    ) -> [Occurrence] {
        let today = calendar.startOfDay(for: now)
        var items: [Occurrence] = []
        for input in rules where input.isActive {
            guard let schedule = input.schedule(calendar: calendar),
                  let dates = try? schedule.occurrences(in: window, calendar: calendar)
            else { continue }
            for date in dates {
                let days = calendar.dateComponents(
                    [.day], from: today, to: date
                ).day ?? 0
                items.append(Occurrence(
                    ruleID: input.id,
                    title: input.title,
                    kind: input.kind,
                    amount: input.amount,
                    icon: input.icon,
                    colorHex: input.colorHex,
                    date: date,
                    daysUntil: days,
                    statusText: CreditCardOverview.countdownText(days: days)
                ))
            }
        }
        items.sort {
            ($0.date, $0.title, $0.ruleID.uuidString)
                < ($1.date, $1.title, $1.ruleID.uuidString)
        }
        return items
    }

    /// Expected income and expense inside `window` across all active
    /// rules — what the header card means by "Dự kiến 30 ngày tới".
    static func totals(
        in rules: [Input],
        window: ClosedRange<Date>,
        now: Date,
        calendar: Calendar
    ) -> Totals {
        var totals = Totals()
        for occurrence in occurrences(in: rules, window: window, now: now, calendar: calendar) {
            let amount = max(0, occurrence.amount)
            switch occurrence.kind {
            case .income: totals.income = saturatingAdd(totals.income, amount)
            case .expense: totals.expense = saturatingAdd(totals.expense, amount)
            case .transfer: break
            }
        }
        return totals
    }

    /// The first occurrence on or after `now`'s day — an occurrence due
    /// today still counts. Nil once the schedule has ended (end date
    /// passed or `maximumOccurrences` reached) or the fields are invalid.
    static func nextOccurrence(
        of input: Input, asOf now: Date, calendar: Calendar
    ) -> Date? {
        guard let schedule = input.schedule(calendar: calendar),
              let yesterday = calendar.date(byAdding: .day, value: -1, to: now)
        else { return nil }
        return try? schedule.nextOccurrence(after: yesterday, calendar: calendar)
    }

    /// `[ruleID: next occurrence]` — the sort-key source for the active
    /// section so it is computed once per render, not once per row pair.
    static func nextOccurrences(
        of rules: [Input], asOf now: Date, calendar: Calendar
    ) -> [UUID: Date] {
        var map: [UUID: Date] = [:]
        for input in rules {
            if let next = nextOccurrence(of: input, asOf: now, calendar: calendar) {
                map[input.id] = next
            }
        }
        return map
    }

    /// A rule is finished when no occurrence remains on or after today —
    /// its end date passed or its occurrence count ran out. Pausing is
    /// the stored `isActive` flag; finished is computed from the schedule.
    static func isFinished(_ input: Input, asOf now: Date, calendar: Calendar) -> Bool {
        nextOccurrence(of: input, asOf: now, calendar: calendar) == nil
    }

    private static func saturatingAdd(_ a: Int64, _ b: Int64) -> Int64 {
        let (result, overflow) = a.addingReportingOverflow(b)
        return overflow ? .max : result
    }
}

extension RecurringUpcoming.Input {
    /// Maps a stored rule to its lightweight value; the row badge comes
    /// from its category (nil stays empty — views substitute a kind
    /// fallback).
    init(rule: RecurringRule) {
        self.init(
            id: rule.id,
            title: rule.title,
            kind: rule.kind,
            amount: rule.amount,
            frequency: rule.frequency,
            interval: rule.interval,
            startDate: rule.startDate,
            endDate: rule.endDate,
            maximumOccurrences: rule.maximumOccurrences,
            icon: rule.category?.icon ?? "",
            colorHex: rule.category?.colorHex ?? "",
            autoCreate: rule.autoCreate,
            isActive: rule.isActive
        )
    }
}
