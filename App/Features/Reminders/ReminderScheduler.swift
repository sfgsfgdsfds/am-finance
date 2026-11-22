import Foundation
import SwiftData
import UserNotifications
import FinanceCore

/// The app's own copy of `UNAuthorizationStatus` so the scheduler's
/// protocol — and its tests — never touch UserNotifications.
enum ReminderAuthorizationStatus: String, Sendable {
    case notDetermined
    case denied
    case authorized
    case provisional
    case ephemeral

    /// The status can actually deliver a notification.
    var canDeliver: Bool {
        self == .authorized || self == .provisional || self == .ephemeral
    }
}

extension ReminderAuthorizationStatus {
    init(from status: UNAuthorizationStatus) {
        switch status {
        case .notDetermined: self = .notDetermined
        case .denied: self = .denied
        case .authorized: self = .authorized
        case .provisional: self = .provisional
        case .ephemeral: self = .ephemeral
        @unknown default: self = .notDetermined
        }
    }
}

/// What `ReminderScheduler` needs from a notification center — the real
/// implementation wraps `UNUserNotificationCenter`, tests use a fake.
protocol ReminderNotificationCentering: Sendable {
    func authorizationStatus() async -> ReminderAuthorizationStatus
    func requestAuthorization() async throws -> Bool
    /// Identifiers of requests still pending delivery.
    func pendingRequestIdentifiers() async -> [String]
    func removePendingRequests(withIdentifiers identifiers: [String])
    /// One-shot local notification at `notification.fireDate`.
    func schedule(
        _ notification: ReminderPlannedNotification, calendar: Calendar
    ) async throws
    /// One-shot local notification `seconds` from now ("Gửi thử").
    func scheduleTest(
        identifier: String, title: String, body: String,
        inSeconds seconds: TimeInterval
    ) async throws
}

/// `UNUserNotificationCenter` behind `ReminderNotificationCentering`.
/// The center is a shared system object predating strict concurrency —
/// its methods are safe to call from any actor, hence `@unchecked Sendable`.
struct ReminderUserNotificationCenter: ReminderNotificationCentering, @unchecked Sendable {
    private let center: UNUserNotificationCenter

    init(center: UNUserNotificationCenter = .current()) {
        self.center = center
    }

    func authorizationStatus() async -> ReminderAuthorizationStatus {
        ReminderAuthorizationStatus(
            from: await center.notificationSettings().authorizationStatus)
    }

    func requestAuthorization() async throws -> Bool {
        try await center.requestAuthorization(options: [.alert, .sound, .badge])
    }

    func pendingRequestIdentifiers() async -> [String] {
        await center.pendingNotificationRequests().map(\.identifier)
    }

    func removePendingRequests(withIdentifiers identifiers: [String]) {
        center.removePendingNotificationRequests(withIdentifiers: identifiers)
    }

    func schedule(
        _ notification: ReminderPlannedNotification, calendar: Calendar
    ) async throws {
        var components = calendar.dateComponents(
            [.year, .month, .day, .hour, .minute], from: notification.fireDate)
        components.timeZone = calendar.timeZone
        let trigger = UNCalendarNotificationTrigger(
            dateMatching: components, repeats: false)
        try await add(
            identifier: notification.id,
            title: notification.title,
            body: notification.body,
            trigger: trigger)
    }

    func scheduleTest(
        identifier: String, title: String, body: String,
        inSeconds seconds: TimeInterval
    ) async throws {
        let trigger = UNTimeIntervalNotificationTrigger(
            timeInterval: max(1, seconds), repeats: false)
        try await add(
            identifier: identifier, title: title, body: body, trigger: trigger)
    }

    private func add(
        identifier: String, title: String, body: String,
        trigger: UNNotificationTrigger
    ) async throws {
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        content.sound = .default
        try await center.add(UNNotificationRequest(
            identifier: identifier, content: content, trigger: trigger))
    }
}

/// Rebuilds the reminder queue from SwiftData: gathers upcoming debts,
/// remind-only occurrences and budget alerts through the same builders
/// the screens use, removes our pending requests and schedules the plan.
/// Safe to call often — on every app-active or after a save. All `let`
/// members and stateless, hence `@unchecked Sendable` for the
/// UserDefaults-holding stores inside.
struct ReminderScheduler: @unchecked Sendable {
    /// Identifier of the "Gửi thử" notification — deliberately outside the
    /// planner prefix so a reschedule never cancels it.
    static let testIdentifier = "amfinance.test-notification"

    let center: any ReminderNotificationCentering
    let settingsStore: ReminderSettingsStore
    let basisStore: LoanInterestBasisStore
    let calendar: Calendar

    init(
        center: any ReminderNotificationCentering = ReminderUserNotificationCenter(),
        settingsStore: ReminderSettingsStore = ReminderSettingsStore(),
        basisStore: LoanInterestBasisStore = LoanInterestBasisStore(),
        calendar: Calendar = AppCalendar.vietnam
    ) {
        self.center = center
        self.settingsStore = settingsStore
        self.basisStore = basisStore
        self.calendar = calendar
    }

    func authorizationStatus() async -> ReminderAuthorizationStatus {
        await center.authorizationStatus()
    }

    func requestAuthorization() async throws -> Bool {
        try await center.requestAuthorization()
    }

    /// Gathers, plans, then swaps the pending queue — returns the plan so
    /// the settings screen can preview it. When permission is denied the
    /// queue is still cleaned but nothing new is added.
    @MainActor
    @discardableResult
    func reschedule(
        context modelContext: ModelContext, now: Date = .now
    ) async -> [ReminderPlannedNotification] {
        let settings = settingsStore.load().sanitized()
        let month = ReminderPlanner.monthKey(of: now, calendar: calendar)
        let pendingBefore = await center.pendingRequestIdentifiers()

        // A warning still pending gets replaced; a warning already
        // delivered stays suppressed for the rest of the month.
        let pendingSet = Set(pendingBefore)
        let warned = settingsStore
            .loadBudgetWarningLog()
            .budgetIDs(forMonthOf: now, calendar: calendar)
        let suppressed = warned.filter {
            !pendingSet.contains(
                ReminderPlanner.budgetIdentifier(budgetID: $0, monthKey: month))
        }

        let input = ReminderPlanner.Input.gather(
            from: modelContext,
            basisStore: basisStore,
            warnedBudgetIDs: suppressed,
            settings: settings,
            now: now,
            calendar: calendar
        )
        let planned = ReminderPlanner.plan(input)

        let ours = pendingBefore.filter {
            $0.hasPrefix(ReminderPlanner.identifierPrefix)
        }
        if !ours.isEmpty {
            center.removePendingRequests(withIdentifiers: ours)
        }

        guard await center.authorizationStatus() != .denied else { return planned }

        for item in planned {
            try? await center.schedule(item, calendar: calendar)
        }

        // Record the budgets just warned so each warns once per month.
        let warnedNow = Set(planned.compactMap(\.budgetID))
        if !warnedNow.isEmpty {
            var ids = warned
            ids.formUnion(warnedNow)
            settingsStore.saveBudgetWarningLog(
                ReminderBudgetWarningLog(monthKey: month, budgetIDs: ids))
        }
        return planned
    }

    /// "Gửi thử thông báo" — fires five seconds from now.
    func sendTestNotification() async throws {
        try await center.scheduleTest(
            identifier: Self.testIdentifier,
            title: "Nhắc nhở AM Finance",
            body: "Đây là thông báo thử — mọi thứ đã sẵn sàng.",
            inSeconds: 5
        )
    }
}

extension ReminderPlanner.Input {
    /// Fetches the store and maps it through the same builders the debts,
    /// recurring and budgets screens use: card statements and loan
    /// installments via `DebtsUpcomingMapper`, remind-only rules via
    /// `RecurringUpcoming`, this month's budgets via `BudgetsSnapshot`.
    /// A failed fetch yields an empty slice, never a throw.
    @MainActor
    static func gather(
        from context: ModelContext,
        basisStore: LoanInterestBasisStore,
        warnedBudgetIDs: Set<UUID>,
        settings: ReminderSettings,
        now: Date,
        calendar: Calendar
    ) -> ReminderPlanner.Input {
        let accounts = (try? context.fetch(FetchDescriptor<Account>())) ?? []
        let rules = (try? context.fetch(FetchDescriptor<RecurringRule>())) ?? []
        let budgets = (try? context.fetch(FetchDescriptor<Budget>())) ?? []
        let categories = (try? context.fetch(FetchDescriptor<LedgerCategory>())) ?? []
        let units = (try? context.fetch(FetchDescriptor<RentalUnit>())) ?? []

        // This month's expenses — the same predicate `BudgetsView` uses.
        let interval = ReportSummary.monthInterval(
            containing: now, calendar: calendar)
        let start = interval.start
        let end = interval.end
        let expenseRaw = TransactionKind.expense.rawValue
        let transactions = (try? context.fetch(FetchDescriptor<LedgerTransaction>(
            predicate: #Predicate {
                $0.date >= start && $0.date < end && $0.kindRaw == expenseRaw
            }
        ))) ?? []

        let names = Dictionary(
            uniqueKeysWithValues: accounts.map { ($0.id, $0.name) })
        let debts = DebtsUpcomingMapper
            .items(
                for: accounts, basisStore: basisStore,
                now: now, calendar: calendar)
            .compactMap { item -> ReminderPlanner.Debt? in
                guard let name = names[item.accountID] else { return nil }
                return ReminderPlanner.Debt(
                    accountID: item.accountID, name: name, kind: item.kind,
                    amount: item.amount, dueDate: item.dueDate)
            }

        // Remind-only rules (`autoCreate == false`) — one notification
        // for each rule's next occurrence.
        let recurring: [ReminderPlanner.Recurring] = rules.compactMap { rule in
            guard rule.isActive, !rule.autoCreate else { return nil }
            let input = RecurringUpcoming.Input(rule: rule)
            guard let next = RecurringUpcoming.nextOccurrence(
                of: input, asOf: now, calendar: calendar) else { return nil }
            return ReminderPlanner.Recurring(
                ruleID: rule.id, title: rule.title, kind: rule.kind,
                amount: rule.amount, date: next)
        }

        let snapshot = BudgetsSnapshot.make(
            limits: budgets.map {
                .init(
                    id: $0.id, categoryID: $0.category?.id,
                    monthlyLimit: $0.monthlyLimit, isActive: $0.isActive,
                    note: $0.note)
            },
            spends: transactions.map {
                .init(
                    categoryID: $0.category?.id, date: $0.date,
                    amount: $0.amount, isBusiness: $0.business != nil)
            },
            categories: Dictionary(uniqueKeysWithValues: categories.map {
                ($0.id, BudgetsSnapshot.Visual(
                    name: $0.name, icon: $0.icon, colorHex: $0.colorHex))
            }),
            month: now, now: now, calendar: calendar
        )
        let alerts = ([snapshot.overall] + snapshot.categories)
            .compactMap { $0 }
            .compactMap { row -> ReminderPlanner.BudgetAlert? in
                guard row.progress.status != .ok else { return nil }
                return ReminderPlanner.BudgetAlert(
                    budgetID: row.budgetID,
                    name: row.name,
                    amountSpent: row.progress.spent,
                    monthlyLimit: row.progress.limit.monthlyLimit,
                    isExceeded: row.progress.status == .exceeded)
            }

        // Rooms whose covering lease still owes rent this month — the
        // same `RentalSnapshot` evaluation the rentals board shows.
        let rents = rentDues(units: units, now: now, calendar: calendar)

        return ReminderPlanner.Input(
            debts: debts,
            recurring: recurring,
            budgets: alerts,
            rents: rents,
            warnedBudgetIDs: warnedBudgetIDs,
            settings: settings,
            now: now,
            calendar: calendar
        )
    }

    /// Maps each non-archived room through `RentalSnapshot`: an active
    /// covering lease with rent still to collect this month becomes a
    /// `RentDue` carrying the current month plus — when the same lease
    /// covers it and it isn't collected yet — the next month.
    @MainActor
    private static func rentDues(
        units: [RentalUnit], now: Date, calendar: Calendar
    ) -> [ReminderPlanner.RentDue] {
        let currentMonth = RentalSnapshot.monthStart(of: now, calendar: calendar)
        let nextMonth = calendar.date(
            byAdding: .month, value: 1, to: currentMonth)
        return units.compactMap { unit in
            guard !unit.isArchived else { return nil }
            let spans = RentalSnapshot.spans(of: unit)
            let payments = RentalSnapshot.payments(of: unit)
            let current = RentalSnapshot.make(
                spans: spans, payments: payments,
                month: currentMonth, calendar: calendar)
            guard let leaseID = current.leaseID,
                  let dueDate = current.dueDate,
                  current.remaining > 0,
                  spans.first(where: { $0.id == leaseID })?.isActive == true
            else { return nil }
            var months = [ReminderPlanner.RentDue.Month(
                start: currentMonth, dueDate: dueDate,
                remaining: current.remaining)]
            if let nextMonth {
                let next = RentalSnapshot.make(
                    spans: spans, payments: payments,
                    month: nextMonth, calendar: calendar)
                if next.leaseID == leaseID, next.remaining > 0,
                   let nextDue = next.dueDate {
                    months.append(ReminderPlanner.RentDue.Month(
                        start: nextMonth, dueDate: nextDue,
                        remaining: next.remaining))
                }
            }
            return ReminderPlanner.RentDue(
                leaseID: leaseID, roomName: unit.name,
                tenantName: current.tenantName ?? "", months: months)
        }
    }
}
