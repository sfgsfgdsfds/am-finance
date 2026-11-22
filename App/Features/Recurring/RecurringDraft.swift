import Foundation
import SwiftData
import FinanceCore

/// How a recurring rule stops — the single "Kết thúc" picker in
/// `RecurringEditView`. `.date` maps to `endDate`, `.count` to
/// `maximumOccurrences`; `.never` clears both.
enum RecurringEndMode: String, CaseIterable, Equatable {
    case never
    case date
    case count

    /// Vietnamese label for the picker.
    var displayName: String {
        switch self {
        case .never: return "Không"
        case .date: return "Đến ngày"
        case .count: return "Số lần"
        }
    }
}

/// Mutable, view-independent state behind `RecurringEditView` — the
/// `TransactionDraft` analogue for `RecurringRule`. Built blank (create)
/// or from an existing rule (edit), checked with `validate()`, then
/// persisted with `insert(into:)` / `apply(to:)`. The schedule fields map
/// onto a FinanceCore `RecurrenceRule`.
struct RecurringDraft {
    var title: String = ""
    var kind: TransactionKind = .expense
    /// Positive đồng magnitude, like a transaction amount.
    var amount: Int64 = 0
    var account: Account?
    /// Destination account — transfers only.
    var toAccount: Account?
    var category: LedgerCategory?
    /// nil means personal ("Cá nhân"); transfers never carry a business.
    var business: Business?
    var frequency: RecurrenceFrequency = .monthly
    /// Every N units of `frequency`; must be ≥ 1.
    var interval: Int = 1
    /// First occurrence; for monthly/yearly also the day-of-month anchor.
    var startDate: Date = .now
    var endMode: RecurringEndMode = .never
    /// Used when `endMode == .date` — the last day an occurrence may fall.
    var endDate: Date = .now
    /// Used when `endMode == .count` — total occurrences ever produced.
    var endCount: Int = 12
    /// true: generate transactions when due; false: only remind.
    var autoCreate: Bool = true
    var note: String = ""

    /// Create mode: a blank monthly expense starting today.
    init() {}

    /// Edit mode: pre-fill every field from an existing rule. A rule that
    /// stores both an end date and a maximum maps to `.date` — the
    /// calendar bound is the one the user sees ticking down.
    init(rule: RecurringRule) {
        title = rule.title
        kind = rule.kind
        amount = rule.amount
        account = rule.account
        toAccount = rule.toAccount
        category = rule.category
        business = rule.business
        frequency = rule.frequency
        interval = rule.interval
        startDate = rule.startDate
        if let end = rule.endDate {
            endMode = .date
            endDate = end
        } else if let maximum = rule.maximumOccurrences {
            endMode = .count
            endCount = maximum
        }
        autoCreate = rule.autoCreate
        note = rule.note
    }

    /// Switch the draft's kind, dropping fields that no longer apply —
    /// same rules as `TransactionDraft.setKind`.
    mutating func setKind(_ newKind: TransactionKind) {
        guard newKind != kind else { return }
        kind = newKind
        if newKind == .transfer {
            category = nil
            business = nil
        } else {
            toAccount = nil
            if let category, category.kind != TransactionDraft.categoryKind(for: newKind) {
                self.category = nil
            }
        }
    }

    var trimmedTitle: String {
        title.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// The stored `endDate` — only meaningful in `.date` mode.
    var resolvedEndDate: Date? { endMode == .date ? endDate : nil }
    /// The stored `maximumOccurrences` — only meaningful in `.count` mode.
    var resolvedMaximumOccurrences: Int? { endMode == .count ? endCount : nil }

    /// Everything the form must satisfy before saving: the transaction
    /// rules (positive amount, source account, distinct transfer
    /// destination, matching category) plus a non-empty title and the
    /// recurrence rules (interval ≥ 1, end not before start, count ≥ 1).
    func validate(calendar: Calendar = AppCalendar.vietnam) -> [RecurringDraftError] {
        var errors: [RecurringDraftError] = []
        if trimmedTitle.isEmpty { errors.append(.missingTitle) }
        if amount <= 0 { errors.append(.missingAmount) }
        if account == nil { errors.append(.missingAccount) }
        if kind == .transfer {
            if toAccount == nil {
                errors.append(.missingDestination)
            } else if toAccount?.id == account?.id {
                errors.append(.sameSourceAndDestination)
            }
        } else if let category, category.kind != TransactionDraft.categoryKind(for: kind) {
            errors.append(.categoryKindMismatch)
        }
        if interval < 1 { errors.append(.invalidInterval) }
        switch endMode {
        case .never:
            break
        case .date:
            if calendar.startOfDay(for: endDate) < calendar.startOfDay(for: startDate) {
                errors.append(.endBeforeStart)
            }
        case .count:
            if endCount < 1 { errors.append(.invalidEndCount) }
        }
        return errors
    }

    var isValid: Bool { validate().isEmpty }

    /// The FinanceCore schedule the draft describes — nil while the
    /// schedule fields are inconsistent.
    func schedule(calendar: Calendar) -> RecurrenceRule? {
        try? RecurrenceRule(
            frequency: frequency,
            interval: interval,
            startDate: startDate,
            endDate: resolvedEndDate,
            maximumOccurrences: resolvedMaximumOccurrences,
            calendar: calendar
        )
    }

    /// Up to `count` occurrences of the draft's schedule, starting with
    /// `startDate` itself — the live "3 ngày tới" preview in the edit
    /// form. Empty while the schedule is inconsistent; shorter when the
    /// end condition caps the sequence.
    func previewDates(
        count: Int = 3,
        calendar: Calendar = AppCalendar.vietnam
    ) -> [Date] {
        guard let schedule = schedule(calendar: calendar) else { return [] }
        var dates: [Date] = []
        // `nextOccurrence` is strictly after the argument's day, so the
        // cursor starts a day early to include `startDate` itself.
        var cursor = calendar.date(byAdding: .day, value: -1, to: startDate)
            ?? .distantPast
        while dates.count < count,
              let next = try? schedule.nextOccurrence(after: cursor, calendar: calendar) {
            dates.append(next)
            cursor = next
        }
        return dates
    }

    /// Create a new rule and insert it into the context. Throws the first
    /// validation error when the draft is incomplete.
    @discardableResult
    func insert(into context: ModelContext) throws -> RecurringRule {
        if let error = validate().first { throw error }
        let rule = RecurringRule(
            title: trimmedTitle,
            kind: kind,
            amount: amount,
            note: note,
            account: account,
            toAccount: normalizedToAccount,
            category: normalizedCategory,
            business: normalizedBusiness,
            frequency: frequency,
            interval: interval,
            startDate: startDate,
            endDate: resolvedEndDate,
            maximumOccurrences: resolvedMaximumOccurrences,
            autoCreate: autoCreate,
            isActive: true
        )
        context.insert(rule)
        return rule
    }

    /// Write the draft back onto an existing rule. `isActive` and
    /// `lastGeneratedDate` are left alone — pausing lives on the list and
    /// the generator owns its own progress marker.
    func apply(to rule: RecurringRule) throws {
        if let error = validate().first { throw error }
        rule.title = trimmedTitle
        rule.kind = kind
        rule.amount = amount
        rule.note = note
        rule.account = account
        rule.toAccount = normalizedToAccount
        rule.category = normalizedCategory
        rule.business = normalizedBusiness
        rule.frequency = frequency
        rule.interval = interval
        rule.startDate = startDate
        rule.endDate = resolvedEndDate
        rule.maximumOccurrences = resolvedMaximumOccurrences
        rule.autoCreate = autoCreate
    }

    private var normalizedToAccount: Account? { kind == .transfer ? toAccount : nil }
    private var normalizedCategory: LedgerCategory? { kind == .transfer ? nil : category }
    private var normalizedBusiness: Business? { kind == .transfer ? nil : business }
}

/// Why a `RecurringDraft` cannot be saved yet.
enum RecurringDraftError: Error, Equatable {
    /// The rule needs a name — it is all a reminder shows.
    case missingTitle
    /// Amount is zero or negative — đồng magnitudes must be positive.
    case missingAmount
    /// No source account picked.
    case missingAccount
    /// A transfer with no destination account.
    case missingDestination
    /// A transfer whose destination is also its source.
    case sameSourceAndDestination
    /// A category whose kind does not match the transaction kind.
    case categoryKindMismatch
    /// `interval` below 1.
    case invalidInterval
    /// The end date's calendar day lies before the start date's.
    case endBeforeStart
    /// The end count below 1.
    case invalidEndCount
}
