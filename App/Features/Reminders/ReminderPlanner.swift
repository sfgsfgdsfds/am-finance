import Foundation
import FinanceCore

/// One notification the planner wants on the queue: a stable identifier
/// (so a reschedule replaces rather than duplicates), the absolute fire
/// instant and the Vietnamese title/body.
struct ReminderPlannedNotification: Equatable, Identifiable, Sendable {
    /// Stable across runs — encodes what the notification reminds about:
    /// account + day offset, rule + occurrence day, or budget + month.
    let id: String
    /// Absolute fire instant — strictly after `now` when planned.
    let fireDate: Date
    let title: String
    let body: String
    /// Non-nil for budget warnings — lets the scheduler record which
    /// budgets already warned this month.
    let budgetID: UUID?
}

/// Turns the app's upcoming money events into concrete local-notification
/// plans. Pure: lightweight inputs in, planned notifications out — every
/// rule (stable identifiers, no past fire dates, per-type switches, the
/// 60 cap, one warning per budget per month) is testable without
/// SwiftData or UserNotifications.
enum ReminderPlanner {

    /// Every identifier the planner mints starts with this prefix, so the
    /// scheduler removes exactly its own pending requests.
    static let identifierPrefix = "amfinance.reminder."
    /// iOS keeps at most 64 pending notification requests per app — the
    /// plan stays under it so unrelated requests still fit.
    static let maximumPlanned = 60

    /// A debt payment still due — a card statement or a loan installment.
    struct Debt: Equatable, Sendable {
        var accountID: UUID
        /// Account display name ("Thẻ VPBank").
        var name: String
        var kind: DebtsUpcomingKind
        /// Amount still to pay (đồng); non-positive means paid in full
        /// and produces nothing.
        var amount: Int64
        var dueDate: Date
    }

    /// The next occurrence of a remind-only recurring rule.
    struct Recurring: Equatable, Sendable {
        var ruleID: UUID
        var title: String
        var kind: TransactionKind
        var amount: Int64
        /// The occurrence's calendar day.
        var date: Date
    }

    /// A room whose covering lease still has rent to collect — built by
    /// `gather` out of `RentalSnapshot` month evaluations.
    struct RentDue: Equatable, Sendable {
        /// One month of unpaid rent, evaluated by `RentalSnapshot`.
        struct Month: Equatable, Sendable {
            /// First day of the month the rent belongs to.
            var start: Date
            /// The clamped due date inside the month.
            var dueDate: Date
            /// Rent still to collect (đồng > 0).
            var remaining: Int64
        }
        var leaseID: UUID
        /// Room display name ("Phòng 101").
        var roomName: String
        /// Tenant on the covering lease — shown in the body.
        var tenantName: String
        /// Unpaid months, oldest first: the current month, then the next
        /// one when the same lease covers it and it isn't collected yet.
        var months: [Month]
    }

    /// A budget at warning or exceeded status for the current month.
    struct BudgetAlert: Equatable, Sendable {
        var budgetID: UUID
        var name: String
        var amountSpent: Int64
        var monthlyLimit: Int64
        var isExceeded: Bool
    }

    /// Everything `plan` reads — built by `gather` (SwiftData) or by hand.
    struct Input: Equatable, Sendable {
        var debts: [Debt] = []
        var recurring: [Recurring] = []
        var budgets: [BudgetAlert] = []
        var rents: [RentDue] = []
        /// Budgets whose warning already went out this month — suppressed
        /// so each budget warns at most once per month.
        var warnedBudgetIDs: Set<UUID> = []
        var settings = ReminderSettings.default
        var now = Date.now
        var calendar = AppCalendar.vietnam
    }

    // MARK: - Plan

    /// Produces the notification queue: enabled inputs become one request
    /// each, sorted by fire date (id breaks ties), past instants dropped,
    /// capped at `maximumPlanned` keeping the soonest.
    static func plan(_ input: Input) -> [ReminderPlannedNotification] {
        let settings = input.settings.sanitized()
        guard settings.isEnabled else { return [] }

        var items = debtItems(input, settings: settings)
        items += recurringItems(input, settings: settings)
        items += budgetItems(input, settings: settings)
        items += rentItems(input, settings: settings)

        items.sort { ($0.fireDate, $0.id) < ($1.fireDate, $1.id) }
        var seen = Set<String>()
        items.removeAll { !seen.insert($0.id).inserted }
        return Array(items.prefix(maximumPlanned))
    }

    // MARK: - Debts

    private static func debtItems(
        _ input: Input, settings: ReminderSettings
    ) -> [ReminderPlannedNotification] {
        guard settings.creditCardDue || settings.loanInstallment else { return [] }
        let calendar = input.calendar
        let today = calendar.startOfDay(for: input.now)
        var items: [ReminderPlannedNotification] = []
        for debt in input.debts where debt.amount > 0 {
            let enabled = debt.kind == .creditCard
                ? settings.creditCardDue
                : settings.loanInstallment
            guard enabled else { continue }
            let dueDay = calendar.startOfDay(for: debt.dueDate)
            let daysUntil = calendar.dateComponents(
                [.day], from: today, to: dueDay).day ?? 0
            items += notifications(
                for: debt, daysUntilDue: daysUntil, dueDay: dueDay,
                input: input, settings: settings)
        }
        return items
    }

    /// One notification per enabled day offset — "Còn n ngày" …
    /// "Hôm nay đến hạn". An overdue debt gets a single nag at the next
    /// notification hour instead (its offsets all lie in the past).
    private static func notifications(
        for debt: Debt, daysUntilDue: Int, dueDay: Date,
        input: Input, settings: ReminderSettings
    ) -> [ReminderPlannedNotification] {
        let calendar = input.calendar
        let tag = debt.kind == .creditCard ? "card" : "loan"
        let dueKey = dayKey(dueDay, calendar: calendar)
        let base = "\(debt.name): cần trả \(VND.format(debt.amount))"
        // No offsets chosen — no debt reminders at all.
        guard !settings.daysBeforeDue.isEmpty else { return [] }

        if daysUntilDue < 0 {
            guard let fire = nextHour(
                settings.notificationHour, after: input.now, calendar: calendar)
            else { return [] }
            return [ReminderPlannedNotification(
                id: "\(identifierPrefix)debt.\(tag)." +
                    "\(debt.accountID.uuidString).overdue.\(dueKey)",
                fireDate: fire,
                title: "Quá hạn \(-daysUntilDue) ngày",
                body: "\(base) · hạn " +
                    AppDateFormat.shortDate(dueDay, calendar: calendar),
                budgetID: nil)]
        }

        var items: [ReminderPlannedNotification] = []
        for offset in settings.daysBeforeDue {
            guard offset <= daysUntilDue,
                  let day = calendar.date(byAdding: .day, value: -offset, to: dueDay),
                  let fire = atHour(day, hour: settings.notificationHour,
                                    calendar: calendar),
                  fire > input.now else { continue }
            items.append(ReminderPlannedNotification(
                id: "\(identifierPrefix)debt.\(tag)." +
                    "\(debt.accountID.uuidString).\(dueKey).d\(offset)",
                fireDate: fire,
                title: offset == 0 ? "Hôm nay đến hạn" : "Còn \(offset) ngày",
                body: "\(base) trước " +
                    AppDateFormat.shortDate(dueDay, calendar: calendar),
                budgetID: nil))
        }
        return items
    }

    // MARK: - Recurring

    /// Remind-only occurrences fire on the day, at the notification hour —
    /// the days-before choices apply to debts only.
    private static func recurringItems(
        _ input: Input, settings: ReminderSettings
    ) -> [ReminderPlannedNotification] {
        guard settings.recurringItems else { return [] }
        var items: [ReminderPlannedNotification] = []
        for occurrence in input.recurring where occurrence.amount > 0 {
            guard let fire = atHour(
                      occurrence.date, hour: settings.notificationHour,
                      calendar: input.calendar),
                  fire > input.now else { continue }
            items.append(ReminderPlannedNotification(
                id: "\(identifierPrefix)recurring.\(occurrence.ruleID.uuidString)." +
                    dayKey(occurrence.date, calendar: input.calendar),
                fireDate: fire,
                title: occurrence.title,
                body: "\(kindLabel(for: occurrence.kind)) " +
                    "\(VND.format(occurrence.amount)) đến hạn hôm nay",
                budgetID: nil))
        }
        return items
    }

    // MARK: - Budgets

    /// One warning per budget per month, at the next notification hour —
    /// the month key in the identifier makes reschedules replace rather
    /// than duplicate, and the warning log suppresses re-delivery.
    private static func budgetItems(
        _ input: Input, settings: ReminderSettings
    ) -> [ReminderPlannedNotification] {
        guard settings.budgetWarnings,
              let fire = nextHour(
                  settings.notificationHour, after: input.now,
                  calendar: input.calendar)
        else { return [] }
        let month = monthKey(of: input.now, calendar: input.calendar)
        var seen = Set<UUID>()
        var items: [ReminderPlannedNotification] = []
        for alert in input.budgets {
            guard !input.warnedBudgetIDs.contains(alert.budgetID),
                  seen.insert(alert.budgetID).inserted else { continue }
            items.append(ReminderPlannedNotification(
                id: budgetIdentifier(budgetID: alert.budgetID, monthKey: month),
                fireDate: fire,
                title: alert.isExceeded ? "Ngân sách đã vượt" : "Ngân sách sắp hết",
                body: budgetBody(alert),
                budgetID: alert.budgetID))
        }
        return items
    }

    private static func budgetBody(_ alert: BudgetAlert) -> String {
        if alert.isExceeded {
            let overshoot = max(0, alert.amountSpent - alert.monthlyLimit)
            return "\(alert.name): đã vượt hạn mức \(VND.format(overshoot))"
        }
        let remaining = max(0, alert.monthlyLimit - alert.amountSpent)
        return "\(alert.name): còn \(VND.format(remaining)) trước khi đạt hạn mức"
    }

    // MARK: - Rent collection

    /// "Thu tiền phòng": one notification on the payment day at the
    /// notification hour and — while the month is still unpaid — a nag
    /// three days after it. The oldest month is the current one; later
    /// months (the next, when the lease covers it) get the payment-day
    /// notification only. Both fire dates must still be ahead.
    private static func rentItems(
        _ input: Input, settings: ReminderSettings
    ) -> [ReminderPlannedNotification] {
        guard settings.rentCollection else { return [] }
        let calendar = input.calendar
        var items: [ReminderPlannedNotification] = []
        for rent in input.rents {
            let tenant = rent.tenantName.isEmpty ? "" : " · \(rent.tenantName)"
            for (index, month) in rent.months.enumerated()
            where month.remaining > 0 {
                let key = monthKey(of: month.start, calendar: calendar)
                let monthNumber = calendar.component(.month, from: month.start)
                let id = "\(identifierPrefix)rent." +
                    "\(rent.leaseID.uuidString).\(key)"
                if let fire = atHour(
                       month.dueDate, hour: settings.notificationHour,
                       calendar: calendar),
                   fire > input.now {
                    items.append(ReminderPlannedNotification(
                        id: "\(id).due",
                        fireDate: fire,
                        title: "Thu tiền phòng",
                        body: "\(rent.roomName): thu " +
                            "\(VND.format(month.remaining)) " +
                            "tiền tháng \(monthNumber)\(tenant)",
                        budgetID: nil))
                }
                // Only the current month nags — the next month's reminder
                // is just its payment day.
                guard index == 0,
                      let day = calendar.date(
                          byAdding: .day, value: 3, to: month.dueDate),
                      let fire = atHour(
                          day, hour: settings.notificationHour,
                          calendar: calendar),
                      fire > input.now else { continue }
                items.append(ReminderPlannedNotification(
                    id: "\(id).overdue",
                    fireDate: fire,
                    title: "Quá hạn 3 ngày",
                    body: "\(rent.roomName): còn " +
                        "\(VND.format(month.remaining)) " +
                        "tiền tháng \(monthNumber) chưa thu\(tenant)",
                    budgetID: nil))
            }
        }
        return items
    }

    // MARK: - Fire dates & keys

    /// Today at `hour` if still ahead, else tomorrow at `hour` — the next
    /// instant the notification may fire, used by overdue nags and budget
    /// warnings which have no "days before" schedule.
    static func nextHour(
        _ hour: Int, after now: Date, calendar: Calendar
    ) -> Date? {
        let today = calendar.startOfDay(for: now)
        if let fire = atHour(today, hour: hour, calendar: calendar), fire > now {
            return fire
        }
        guard let tomorrow = calendar.date(byAdding: .day, value: 1, to: today)
        else { return nil }
        return atHour(tomorrow, hour: hour, calendar: calendar)
    }

    /// `hour:00` on the calendar day containing `day`, or nil on the rare
    /// day that wall-clock time doesn't exist (DST — none in Vietnam).
    static func atHour(_ day: Date, hour: Int, calendar: Calendar) -> Date? {
        calendar.date(
            bySettingHour: hour, minute: 0, second: 0,
            of: calendar.startOfDay(for: day))
    }

    /// "yyyy-MM" month key — embedded in budget warning identifiers and
    /// the persisted log so each budget warns at most once per month.
    static func monthKey(of date: Date, calendar: Calendar) -> String {
        let components = calendar.dateComponents([.year, .month], from: date)
        return String(format: "%04d-%02d", components.year ?? 0, components.month ?? 0)
    }

    /// The identifier `budgetItems` mints — shared with the scheduler so
    /// it can recognize a still-pending warning in the queue.
    static func budgetIdentifier(budgetID: UUID, monthKey: String) -> String {
        "\(identifierPrefix)budget.\(budgetID.uuidString).\(monthKey)"
    }

    /// "yyyyMMdd" day key — embeds a due or occurrence day in identifiers.
    private static func dayKey(_ date: Date, calendar: Calendar) -> String {
        let components = calendar.dateComponents([.year, .month, .day], from: date)
        return String(
            format: "%04d%02d%02d",
            components.year ?? 0, components.month ?? 0, components.day ?? 0)
    }

    /// "Khoản chi/thu/chuyển" — the amount's role in a recurring body.
    private static func kindLabel(for kind: TransactionKind) -> String {
        switch kind {
        case .expense: return "Khoản chi"
        case .income: return "Khoản thu"
        case .transfer: return "Khoản chuyển"
        }
    }
}
