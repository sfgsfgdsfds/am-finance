import Foundation

/// User preferences for the reminder notifications — a plain value so the
/// planner, the scheduler and the settings screen share one shape.
/// Persisted by `ReminderSettingsStore` (UserDefaults); inject a suite to
/// test. Reminders are opt-in: the master switch defaults to off.
struct ReminderSettings: Equatable, Sendable {
    /// Master switch — off by default so nothing schedules until the
    /// owner turns reminders on (which also requests permission).
    var isEnabled = false
    /// Credit-card statement due dates.
    var creditCardDue = true
    /// Loan installments.
    var loanInstallment = true
    /// Remind-only recurring rules (`autoCreate == false`).
    var recurringItems = true
    /// Budgets at warning or exceeded status.
    var budgetWarnings = true
    /// Day offsets before a due date that fire a reminder — [3, 1, 0]
    /// means "3 days before", "the day before" and "on the day". Kept
    /// sorted descending, deduplicated, each in 0...30.
    var daysBeforeDue = [3, 1, 0]
    /// Hour of day (0...23) the notifications fire — default 9:00.
    var notificationHour = 9

    /// Reasonable out-of-the-box settings.
    static let `default` = ReminderSettings()

    /// The day offsets the settings screen offers as toggles.
    static let dayChoices = [7, 3, 1, 0]

    /// Repairs values that could come back from storage edits or older
    /// builds: hour clamped to 0...23, offsets deduplicated, clamped to
    /// 0...30 and sorted descending.
    func sanitized() -> ReminderSettings {
        var copy = self
        copy.notificationHour = min(23, max(0, notificationHour))
        var seen = Set<Int>()
        copy.daysBeforeDue = daysBeforeDue
            .filter { (0...30).contains($0) && seen.insert($0).inserted }
            .sorted(by: >)
        return copy
    }
}

/// Which budgets already produced a warning in one calendar month —
/// persisted so a warning fires at most once per budget per month, even
/// after it was delivered and the queue is rebuilt.
struct ReminderBudgetWarningLog: Equatable, Sendable {
    /// "yyyy-MM" month key (in the app calendar) the ids belong to.
    var monthKey: String
    var budgetIDs: Set<UUID>

    static let empty = ReminderBudgetWarningLog(monthKey: "", budgetIDs: [])

    /// The warned ids that apply to the month containing `date` — empty
    /// when the stored log belongs to an older month, so warnings resume
    /// with each new month.
    func budgetIDs(forMonthOf date: Date, calendar: Calendar) -> Set<UUID> {
        monthKey == ReminderPlanner.monthKey(of: date, calendar: calendar)
            ? budgetIDs
            : []
    }
}

/// UserDefaults persistence for `ReminderSettings` and the budget warning
/// log — the same split as `WalletLinkConfig`/`WalletLinkConfigStore`.
/// Inject a suite in tests. (`UserDefaults` is documented thread-safe,
/// hence `@unchecked Sendable`.)
final class ReminderSettingsStore: @unchecked Sendable {
    static let enabledKey = "reminders.enabled"
    static let creditCardDueKey = "reminders.creditCardDue"
    static let loanInstallmentKey = "reminders.loanInstallment"
    static let recurringItemsKey = "reminders.recurringItems"
    static let budgetWarningsKey = "reminders.budgetWarnings"
    static let daysBeforeDueKey = "reminders.daysBeforeDue"
    static let notificationHourKey = "reminders.notificationHour"
    static let warningLogMonthKey = "reminders.budgetWarningMonth"
    static let warningLogIDsKey = "reminders.budgetWarningIDs"

    let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    func load() -> ReminderSettings {
        var settings = ReminderSettings.default
        if let value = defaults.object(forKey: Self.enabledKey) as? Bool {
            settings.isEnabled = value
        }
        if let value = defaults.object(forKey: Self.creditCardDueKey) as? Bool {
            settings.creditCardDue = value
        }
        if let value = defaults.object(forKey: Self.loanInstallmentKey) as? Bool {
            settings.loanInstallment = value
        }
        if let value = defaults.object(forKey: Self.recurringItemsKey) as? Bool {
            settings.recurringItems = value
        }
        if let value = defaults.object(forKey: Self.budgetWarningsKey) as? Bool {
            settings.budgetWarnings = value
        }
        if let days = defaults.array(forKey: Self.daysBeforeDueKey) as? [Int] {
            settings.daysBeforeDue = days
        }
        if let hour = defaults.object(forKey: Self.notificationHourKey) as? Int {
            settings.notificationHour = hour
        }
        return settings.sanitized()
    }

    func save(_ settings: ReminderSettings) {
        let sanitized = settings.sanitized()
        defaults.set(sanitized.isEnabled, forKey: Self.enabledKey)
        defaults.set(sanitized.creditCardDue, forKey: Self.creditCardDueKey)
        defaults.set(sanitized.loanInstallment, forKey: Self.loanInstallmentKey)
        defaults.set(sanitized.recurringItems, forKey: Self.recurringItemsKey)
        defaults.set(sanitized.budgetWarnings, forKey: Self.budgetWarningsKey)
        defaults.set(sanitized.daysBeforeDue, forKey: Self.daysBeforeDueKey)
        defaults.set(sanitized.notificationHour, forKey: Self.notificationHourKey)
    }

    func loadBudgetWarningLog() -> ReminderBudgetWarningLog {
        let month = defaults.string(forKey: Self.warningLogMonthKey) ?? ""
        let ids = (defaults.stringArray(forKey: Self.warningLogIDsKey) ?? [])
            .compactMap { UUID(uuidString: $0) }
        return ReminderBudgetWarningLog(monthKey: month, budgetIDs: Set(ids))
    }

    func saveBudgetWarningLog(_ log: ReminderBudgetWarningLog) {
        defaults.set(log.monthKey, forKey: Self.warningLogMonthKey)
        defaults.set(
            log.budgetIDs.map(\.uuidString).sorted(),
            forKey: Self.warningLogIDsKey
        )
    }
}
