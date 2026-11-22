import Testing
import Foundation
import SwiftData
import FinanceCore
@testable import AMFinance

/// Records `ReminderNotificationCentering` calls and mirrors a real
/// center's pending queue: adds append, removes delete, and tests can
/// drop identifiers to simulate a delivered notification.
private final class ReminderFakeCenter: ReminderNotificationCentering, @unchecked Sendable {
    var status: ReminderAuthorizationStatus = .authorized
    var grantResult = true

    var pending: [String] = []
    var added: [ReminderPlannedNotification] = []
    var removed: [String] = []
    var testCalls: [(identifier: String, seconds: TimeInterval)] = []
    var authorizationCalls = 0

    func authorizationStatus() async -> ReminderAuthorizationStatus { status }

    func requestAuthorization() async throws -> Bool {
        authorizationCalls += 1
        if grantResult { status = .authorized }
        return grantResult
    }

    func pendingRequestIdentifiers() async -> [String] { pending }

    func removePendingRequests(withIdentifiers identifiers: [String]) {
        removed += identifiers
        let drop = Set(identifiers)
        pending.removeAll { drop.contains($0) }
    }

    func schedule(
        _ notification: ReminderPlannedNotification, calendar: Calendar
    ) async throws {
        added.append(notification)
        pending.append(notification.id)
    }

    func scheduleTest(
        identifier: String, title: String, body: String,
        inSeconds seconds: TimeInterval
    ) async throws {
        testCalls.append((identifier, seconds))
        pending.append(identifier)
    }
}

@MainActor
struct RemindersTests {

    private let calendar = AppCalendar.vietnam

    private func makeContext() throws -> ModelContext {
        ModelContext(try AppModelContainer.make(inMemory: true))
    }

    private func makeDefaults() -> UserDefaults {
        UserDefaults(suiteName: "RemindersTests.\(UUID().uuidString)")!
    }

    /// A moment in Asia/Ho_Chi_Minh.
    private func day(
        _ year: Int, _ month: Int, _ day: Int,
        _ hour: Int = 12, _ minute: Int = 0
    ) -> Date {
        calendar.date(from: DateComponents(
            year: year, month: month, day: day, hour: hour, minute: minute))!
    }

    private func enabledSettings(
        _ mutate: (inout ReminderSettings) -> Void = { _ in }
    ) -> ReminderSettings {
        var settings = ReminderSettings(isEnabled: true)
        mutate(&settings)
        return settings
    }

    private func card(
        name: String = "Thẻ VPBank", amount: Int64 = 3_200_000, due: Date
    ) -> ReminderPlanner.Debt {
        .init(
            accountID: UUID(), name: name, kind: .creditCard,
            amount: amount, dueDate: due)
    }

    private func loan(
        name: String = "Vay nhà", amount: Int64 = 5_000_000, due: Date
    ) -> ReminderPlanner.Debt {
        .init(
            accountID: UUID(), name: name, kind: .loan,
            amount: amount, dueDate: due)
    }

    // MARK: - Settings & store

    @Test func settingsDefaultIsOffWithExpectedChoices() {
        let settings = ReminderSettings.default
        #expect(!settings.isEnabled)
        #expect(settings.creditCardDue && settings.loanInstallment)
        #expect(settings.recurringItems && settings.budgetWarnings)
        #expect(settings.rentCollection)
        #expect(settings.daysBeforeDue == [3, 1, 0])
        #expect(settings.notificationHour == 9)
    }

    @Test func sanitizedClampsHourAndDayOffsets() {
        let dirty = ReminderSettings(
            isEnabled: true, daysBeforeDue: [1, 45, -2, 3, 3, 0],
            notificationHour: 25)
        let clean = dirty.sanitized()
        #expect(clean.daysBeforeDue == [3, 1, 0])
        #expect(clean.notificationHour == 23)
    }

    @Test func storeRoundTripsSettingsAndLog() {
        let store = ReminderSettingsStore(defaults: makeDefaults())
        #expect(store.load() == .default)

        store.save(ReminderSettings(
            isEnabled: true, creditCardDue: false,
            daysBeforeDue: [0, 7, 7], notificationHour: 21))
        let loaded = store.load()
        #expect(loaded.isEnabled)
        #expect(!loaded.creditCardDue)
        #expect(loaded.daysBeforeDue == [7, 0])
        #expect(loaded.notificationHour == 21)

        let budgetID = UUID()
        store.saveBudgetWarningLog(.init(
            monthKey: "2026-11", budgetIDs: [budgetID]))
        #expect(store.loadBudgetWarningLog() == .init(
            monthKey: "2026-11", budgetIDs: [budgetID]))
    }

    @Test func warningLogAppliesOnlyToItsMonth() {
        let log = ReminderBudgetWarningLog(
            monthKey: "2026-10", budgetIDs: [UUID()])
        // October's log does not suppress November warnings.
        #expect(log.budgetIDs(
            forMonthOf: day(2026, 11, 15), calendar: calendar).isEmpty)
        #expect(log.budgetIDs(
            forMonthOf: day(2026, 10, 31), calendar: calendar).count == 1)
    }

    // MARK: - Planner: debts

    /// A card due in five days produces the three default notifications —
    /// 3 days before, 1 day before and on the day, each at 9:00.
    @Test func cardDueInFiveDaysPlansThreeNotifications() {
        let now = day(2026, 11, 20, 8)
        let plan = ReminderPlanner.plan(.init(
            debts: [card(amount: 3_200_000, due: day(2026, 11, 25))],
            settings: enabledSettings(),
            now: now, calendar: calendar))

        #expect(plan.count == 3)
        #expect(plan.map(\.fireDate) == [
            day(2026, 11, 22, 9),
            day(2026, 11, 24, 9),
            day(2026, 11, 25, 9),
        ])
        #expect(plan.map(\.title) == [
            "Còn 3 ngày", "Còn 1 ngày", "Hôm nay đến hạn",
        ])
        #expect(plan.allSatisfy {
            $0.body == "Thẻ VPBank: cần trả 3.200.000 ₫ trước 25/11"
        })
        #expect(plan.allSatisfy {
            $0.id.hasPrefix("amfinance.reminder.debt.card.")
        })
    }

    /// Due today but the notification hour already passed — no past
    /// notification is ever planned.
    @Test func dueTodayAfterHourPlansNothing() {
        let plan = ReminderPlanner.plan(.init(
            debts: [card(due: day(2026, 11, 25))],
            settings: enabledSettings(),
            now: day(2026, 11, 25, 14), calendar: calendar))
        #expect(plan.isEmpty)
    }

    /// Same due date, but earlier — the on-the-day notification survives.
    @Test func dueTodayBeforeHourPlansOnTheDay() {
        let plan = ReminderPlanner.plan(.init(
            debts: [card(due: day(2026, 11, 25))],
            settings: enabledSettings { $0.daysBeforeDue = [1, 0] },
            now: day(2026, 11, 25, 8), calendar: calendar))
        // The "1 day before" fire date (yesterday 9:00) is past — only
        // "on the day" at 9:00 remains.
        #expect(plan.count == 1)
        #expect(plan[0].fireDate == day(2026, 11, 25, 9))
        #expect(plan[0].title == "Hôm nay đến hạn")
    }

    /// Overdue debts get a single nag at the next notification hour —
    /// every days-before offset lies in the past.
    @Test func overdueDebtPlansOneNagAtNextHour() {
        let now = day(2026, 11, 22, 14)  // after 9:00 → tomorrow morning
        let plan = ReminderPlanner.plan(.init(
            debts: [card(due: day(2026, 11, 19))],
            settings: enabledSettings(),
            now: now, calendar: calendar))
        #expect(plan.count == 1)
        #expect(plan[0].fireDate == day(2026, 11, 23, 9))
        #expect(plan[0].title == "Quá hạn 3 ngày")
        #expect(plan[0].body.contains("hạn 19/11"))
        #expect(plan[0].id.contains(".overdue."))
    }

    /// Before the notification hour the overdue nag fires the same day.
    @Test func overdueDebtNagsSameDayBeforeHour() {
        let plan = ReminderPlanner.plan(.init(
            debts: [card(due: day(2026, 11, 19))],
            settings: enabledSettings(),
            now: day(2026, 11, 22, 7), calendar: calendar))
        #expect(plan.map(\.fireDate) == [day(2026, 11, 22, 9)])
    }

    /// A card paid in full (amount 0) produces nothing.
    @Test func paidInFullCardIsSkipped() {
        let plan = ReminderPlanner.plan(.init(
            debts: [card(amount: 0, due: day(2026, 11, 25))],
            settings: enabledSettings(),
            now: day(2026, 11, 20), calendar: calendar))
        #expect(plan.isEmpty)
    }

    // MARK: - Planner: per-type switches

    @Test func perTypeSwitchesGateTheirNotifications() {
        let debts = [
            card(due: day(2026, 11, 25)),
            loan(due: day(2026, 11, 25)),
        ]
        let recurring = [ReminderPlanner.Recurring(
            ruleID: UUID(), title: "Thuê nhà", kind: .expense,
            amount: 7_000_000, date: day(2026, 11, 24))]
        let budgets = [ReminderPlanner.BudgetAlert(
            budgetID: UUID(), name: "Ăn uống",
            amountSpent: 900_000, monthlyLimit: 1_000_000,
            isExceeded: false)]
        let now = day(2026, 11, 20)

        func kinds(in settings: ReminderSettings) -> Set<String> {
            Set(ReminderPlanner.plan(.init(
                debts: debts, recurring: recurring, budgets: budgets,
                settings: settings, now: now, calendar: calendar))
                .map { String($0.id.split(separator: ".")[2]) })
        }

        #expect(kinds(in: enabledSettings()) == ["debt", "recurring", "budget"])
        // Turning off one debt kind leaves the other — "debt" stays.
        #expect(kinds(in: enabledSettings { $0.creditCardDue = false })
            == ["debt", "recurring", "budget"])
        #expect(kinds(in: enabledSettings { $0.loanInstallment = false })
            == ["debt", "recurring", "budget"])
        #expect(kinds(in: enabledSettings {
            $0.creditCardDue = false; $0.loanInstallment = false })
            == ["recurring", "budget"])
        #expect(kinds(in: enabledSettings { $0.recurringItems = false })
            == ["debt", "budget"])
        #expect(kinds(in: enabledSettings { $0.budgetWarnings = false })
            == ["debt", "recurring"])
        #expect(kinds(in: ReminderSettings()).isEmpty)   // master off
    }

    /// The card switch drops only card items; the loan switch only loans.
    @Test func cardAndLoanSwitchesAreIndependent() {
        let debts = [
            card(due: day(2026, 11, 25)),
            loan(due: day(2026, 11, 25)),
        ]
        let now = day(2026, 11, 20)
        let cardsOnly = ReminderPlanner.plan(.init(
            debts: debts,
            settings: enabledSettings { $0.loanInstallment = false },
            now: now, calendar: calendar))
        #expect(cardsOnly.allSatisfy { $0.id.contains(".card.") })

        let loansOnly = ReminderPlanner.plan(.init(
            debts: debts,
            settings: enabledSettings { $0.creditCardDue = false },
            now: now, calendar: calendar))
        #expect(loansOnly.allSatisfy { $0.id.contains(".loan.") })
    }

    // MARK: - Planner: recurring

    @Test func recurringFiresOnTheDayAtTheHour() {
        let ruleID = UUID()
        let plan = ReminderPlanner.plan(.init(
            recurring: [.init(
                ruleID: ruleID, title: "Trả tiền thuê", kind: .expense,
                amount: 7_000_000, date: day(2026, 11, 24))],
            settings: enabledSettings(),
            now: day(2026, 11, 20), calendar: calendar))
        #expect(plan.count == 1)
        #expect(plan[0].fireDate == day(2026, 11, 24, 9))
        #expect(plan[0].title == "Trả tiền thuê")
        #expect(plan[0].body == "Khoản chi 7.000.000 ₫ đến hạn hôm nay")
        #expect(plan[0].id.contains(ruleID.uuidString))
    }

    /// An occurrence due today after the notification hour is dropped —
    /// never in the past.
    @Test func recurringTodayAfterHourIsDropped() {
        let plan = ReminderPlanner.plan(.init(
            recurring: [.init(
                ruleID: UUID(), title: "Thuê nhà", kind: .income,
                amount: 7_000_000, date: day(2026, 11, 22))],
            settings: enabledSettings(),
            now: day(2026, 11, 22, 10), calendar: calendar))
        #expect(plan.isEmpty)
    }

    // MARK: - Planner: budgets

    /// Two alerts for the same budget still produce one notification, and
    /// a budget already warned this month is suppressed.
    @Test func budgetWarningsDedupePerBudgetPerMonth() {
        let idA = UUID(), idB = UUID()
        let alertA = ReminderPlanner.BudgetAlert(
            budgetID: idA, name: "Ăn uống",
            amountSpent: 900_000, monthlyLimit: 1_000_000, isExceeded: false)
        let alertB = ReminderPlanner.BudgetAlert(
            budgetID: idB, name: "Đi lại",
            amountSpent: 1_300_000, monthlyLimit: 1_000_000, isExceeded: true)
        let now = day(2026, 11, 15, 14)

        // Duplicate rows for the same budget collapse into one.
        let plan = ReminderPlanner.plan(.init(
            budgets: [alertA, alertA, alertB],
            settings: enabledSettings(),
            now: now, calendar: calendar))
        #expect(plan.count == 2)
        #expect(Set(plan.map(\.budgetID)) == [idA, idB])
        #expect(plan.allSatisfy { $0.id.contains("2026-11") })
        // Both fire at the next notification hour (tomorrow 9:00).
        #expect(plan.allSatisfy { $0.fireDate == day(2026, 11, 16, 9) })

        // A budget already warned this month stays silent.
        let suppressed = ReminderPlanner.plan(.init(
            budgets: [alertA, alertB], warnedBudgetIDs: [idA],
            settings: enabledSettings(),
            now: now, calendar: calendar))
        #expect(suppressed.map(\.budgetID) == [idB])
    }

    @Test func budgetWarningAndExceededTexts() {
        let plan = ReminderPlanner.plan(.init(
            budgets: [
                .init(budgetID: UUID(), name: "Ăn uống",
                      amountSpent: 900_000, monthlyLimit: 1_000_000,
                      isExceeded: false),
                .init(budgetID: UUID(), name: "Đi lại",
                      amountSpent: 1_300_000, monthlyLimit: 1_000_000,
                      isExceeded: true),
            ],
            settings: enabledSettings(),
            now: day(2026, 11, 15, 8), calendar: calendar))
        let warning = plan.first { $0.title == "Ngân sách sắp hết" }
        let exceeded = plan.first { $0.title == "Ngân sách đã vượt" }
        #expect(warning?.body == "Ăn uống: còn 100.000 ₫ trước khi đạt hạn mức")
        #expect(exceeded?.body == "Đi lại: đã vượt hạn mức 300.000 ₫")
    }

    // MARK: - Planner: rent collection

    private func rentDue(
        room: String = "Phòng 101", tenant: String = "Nguyễn Văn A",
        months: [ReminderPlanner.RentDue.Month]
    ) -> ReminderPlanner.RentDue {
        .init(leaseID: UUID(), roomName: room, tenantName: tenant,
              months: months)
    }

    private func rentMonth(
        _ year: Int, _ month: Int, due: Date, remaining: Int64
    ) -> ReminderPlanner.RentDue.Month {
        .init(start: day(year, month, 1, 0), dueDate: due,
              remaining: remaining)
    }

    /// An unpaid lease plans the payment-day reminder at the notification
    /// hour, the nag three days after, and next month's payment day.
    @Test func rentUnpaidPlansDueOverdueAndNextMonth() {
        let plan = ReminderPlanner.plan(.init(
            rents: [rentDue(months: [
                rentMonth(2026, 11, due: day(2026, 11, 25),
                          remaining: 4_500_000),
                rentMonth(2026, 12, due: day(2026, 12, 25),
                          remaining: 4_500_000),
            ])],
            settings: enabledSettings(),
            now: day(2026, 11, 20, 8), calendar: calendar))

        #expect(plan.count == 3)
        #expect(plan.map(\.fireDate) == [
            day(2026, 11, 25, 9), day(2026, 11, 28, 9), day(2026, 12, 25, 9),
        ])
        #expect(plan.map(\.title) == [
            "Thu tiền phòng", "Quá hạn 3 ngày", "Thu tiền phòng",
        ])
        #expect(plan[0].body ==
            "Phòng 101: thu 4.500.000 ₫ tiền tháng 11 · Nguyễn Văn A")
        #expect(plan[0].id.hasPrefix("amfinance.reminder.rent."))
        #expect(plan[0].id.hasSuffix("2026-11.due"))
        #expect(plan[1].id.hasSuffix("2026-11.overdue"))
        #expect(plan[2].id.hasSuffix("2026-12.due"))
        #expect(plan[2].body.contains("tiền tháng 12"))
    }

    /// A partially collected month reminds for the remaining amount only.
    @Test func rentPartialShowsRemainingAmount() {
        let plan = ReminderPlanner.plan(.init(
            rents: [rentDue(months: [
                rentMonth(2026, 11, due: day(2026, 11, 25),
                          remaining: 1_500_000),
            ])],
            settings: enabledSettings(),
            now: day(2026, 11, 20, 8), calendar: calendar))
        #expect(!plan.isEmpty)
        #expect(plan.allSatisfy { $0.body.contains("1.500.000 ₫") })
        #expect(plan.allSatisfy { !$0.body.contains("4.500.000") })
    }

    /// A month collected in full (remaining 0) produces nothing.
    @Test func rentFullyCollectedPlansNothing() {
        let plan = ReminderPlanner.plan(.init(
            rents: [rentDue(months: [
                rentMonth(2026, 11, due: day(2026, 11, 25), remaining: 0),
            ])],
            settings: enabledSettings(),
            now: day(2026, 11, 20, 8), calendar: calendar))
        #expect(plan.isEmpty)
    }

    /// The "Thu tiền phòng" switch gates every rent notification.
    @Test func rentSwitchOffPlansNothing() {
        let plan = ReminderPlanner.plan(.init(
            rents: [rentDue(months: [
                rentMonth(2026, 11, due: day(2026, 11, 25),
                          remaining: 4_500_000),
            ])],
            settings: enabledSettings { $0.rentCollection = false },
            now: day(2026, 11, 20, 8), calendar: calendar))
        #expect(plan.isEmpty)
    }

    /// Once the payment day is past the on-day reminder is gone; the
    /// +3-day nag stays until it too lies in the past.
    @Test func rentPastPaymentDayKeepsOnlyTheNag() {
        let months = [rentMonth(
            2026, 11, due: day(2026, 11, 25), remaining: 4_500_000)]
        let during = ReminderPlanner.plan(.init(
            rents: [rentDue(months: months)],
            settings: enabledSettings(),
            now: day(2026, 11, 26, 8), calendar: calendar))
        #expect(during.count == 1)
        #expect(during[0].title == "Quá hạn 3 ngày")
        #expect(during[0].fireDate == day(2026, 11, 28, 9))

        let after = ReminderPlanner.plan(.init(
            rents: [rentDue(months: months)],
            settings: enabledSettings(),
            now: day(2026, 11, 28, 10), calendar: calendar))
        #expect(after.isEmpty)
    }

    /// The same lease plans identical identifiers run after run, so a
    /// reschedule replaces instead of duplicating.
    @Test func rentIdentifiersAreStableAcrossRuns() {
        let input = ReminderPlanner.Input(
            rents: [rentDue(months: [
                rentMonth(2026, 11, due: day(2026, 11, 25),
                          remaining: 4_500_000),
                rentMonth(2026, 12, due: day(2026, 12, 25),
                          remaining: 4_500_000),
            ])],
            settings: enabledSettings(),
            now: day(2026, 11, 20, 8), calendar: calendar)
        let first = ReminderPlanner.plan(input)
        #expect(first == ReminderPlanner.plan(input))
        #expect(first.map(\.id) == ReminderPlanner.plan(input).map(\.id))
    }

    // MARK: - Planner: ordering, cap, stability, timezone

    /// With more candidates than the cap, the soonest 60 survive.
    @Test func capKeepsTheSoonestSixty() {
        let now = day(2026, 11, 20)
        // 25 debts × 4 offsets (7, 3, 1, 0) = 100 candidates.
        let debts = (1...25).map { i in
            ReminderPlanner.Debt(
                accountID: UUID(), name: "Thẻ \(i)", kind: .creditCard,
                amount: 100,
                dueDate: calendar.date(byAdding: .day, value: 14 + i, to: now)!)
        }
        let settings = enabledSettings { $0.daysBeforeDue = [7, 3, 1, 0] }
        let plan = ReminderPlanner.plan(.init(
            debts: debts, settings: settings,
            now: now, calendar: calendar))

        #expect(plan.count == ReminderPlanner.maximumPlanned)
        #expect(plan.count == 60)

        // Expected: sort every candidate (due − offset at 9:00) by
        // (fireDate, id) and take the first 60 — the soonest.
        var candidates: [(id: String, fire: Date)] = []
        for debt in debts {
            for offset in [7, 3, 1, 0] {
                let dueDay = calendar.startOfDay(for: debt.dueDate)
                let day = calendar.date(byAdding: .day, value: -offset, to: dueDay)!
                let fire = ReminderPlanner.atHour(day, hour: 9, calendar: calendar)!
                let dueKey = calendar.dateComponents(
                    [.year, .month, .day], from: dueDay)
                let key = String(
                    format: "%04d%02d%02d",
                    dueKey.year!, dueKey.month!, dueKey.day!)
                candidates.append((
                    "amfinance.reminder.debt.card." +
                    "\(debt.accountID.uuidString).\(key).d\(offset)", fire))
            }
        }
        let expected = Set(
            candidates
                .sorted { ($0.fire, $0.id) < ($1.fire, $1.id) }
                .prefix(60)
                .map(\.id))
        #expect(Set(plan.map(\.id)) == expected)
        // Output itself is chronological.
        #expect(plan.map(\.fireDate) == plan.map(\.fireDate).sorted())
    }

    /// The same inputs planned twice mint identical identifiers, so a
    /// reschedule replaces instead of duplicating.
    @Test func identifiersAreStableAcrossRuns() {
        let input = ReminderPlanner.Input(
            debts: [card(due: day(2026, 11, 25))],
            recurring: [.init(
                ruleID: UUID(), title: "Thuê nhà", kind: .expense,
                amount: 7_000_000, date: day(2026, 11, 24))],
            budgets: [.init(
                budgetID: UUID(), name: "Ăn uống",
                amountSpent: 900_000, monthlyLimit: 1_000_000,
                isExceeded: false)],
            settings: enabledSettings(),
            now: day(2026, 11, 20), calendar: calendar)
        let first = ReminderPlanner.plan(input)
        let second = ReminderPlanner.plan(input)
        #expect(first.map(\.id) == second.map(\.id))
        #expect(first == second)
    }

    /// Fire dates are built in Asia/Ho_Chi_Minh — 9:00 local, not UTC.
    @Test func fireDatesUseHoChiMinhTime() {
        let plan = ReminderPlanner.plan(.init(
            debts: [card(due: day(2026, 11, 25))],
            settings: enabledSettings { $0.daysBeforeDue = [0] },
            now: day(2026, 11, 20), calendar: calendar))
        #expect(plan.count == 1)
        // 25/11 09:00 in Asia/Ho_Chi_Minh — built with the same calendar.
        #expect(plan[0].fireDate == day(2026, 11, 25, 9))
        let components = calendar.dateComponents(
            [.day, .month, .hour], from: plan[0].fireDate)
        #expect(components.day == 25 && components.month == 11)
        #expect(components.hour == 9)
    }

    // MARK: - Scheduler

    private func seedReminderFixtures(context: ModelContext, now: Date) throws -> UUID {
        let cash = Account(name: "Tiền mặt", kind: .cash)
        let food = LedgerCategory(
            name: "Ăn uống", kind: .expense,
            icon: "fork.knife", colorHex: "FF9500")
        context.insert(cash)
        context.insert(food)

        // Remind-only rule whose next occurrence is tomorrow.
        context.insert(RecurringRule(
            title: "Trả tiền thuê", kind: .expense, amount: 7_000_000,
            account: cash, frequency: .monthly,
            startDate: calendar.date(byAdding: .day, value: 1, to: now)!,
            autoCreate: false))

        // A warning-level budget (90% used this month).
        let budget = Budget(monthlyLimit: 1_000_000, category: food)
        context.insert(budget)
        context.insert(LedgerTransaction(
            kind: .expense, amount: 900_000, date: now,
            account: cash, category: food))
        try context.save()
        return budget.id
    }

    /// Reschedule removes our stale pending requests — and only ours —
    /// then adds the planned ones; a foreign request is untouched.
    @Test func schedulerReplacesPreviouslyScheduledRequests() async throws {
        let context = try makeContext()
        let now = day(2026, 11, 15, 8)
        let budgetID = try seedReminderFixtures(context: context, now: now)

        let store = ReminderSettingsStore(defaults: makeDefaults())
        store.save(ReminderSettings(isEnabled: true))

        let fake = ReminderFakeCenter()
        fake.pending = [
            "amfinance.reminder.debt.card.stale",
            "some.other.request",
        ]
        let scheduler = ReminderScheduler(
            center: fake, settingsStore: store, calendar: calendar)

        let planned = await scheduler.reschedule(context: context, now: now)

        // Only our stale identifier was removed; the foreign one stays.
        #expect(fake.removed == ["amfinance.reminder.debt.card.stale"])
        #expect(fake.pending.contains("some.other.request"))
        // Every planned notification was scheduled — nothing else.
        #expect(Set(fake.added.map(\.id)) == Set(planned.map(\.id)))
        #expect(fake.added.allSatisfy {
            $0.id.hasPrefix(ReminderPlanner.identifierPrefix)
        })
        // One recurring + one budget warning were produced.
        #expect(planned.contains { $0.id.contains("recurring.") })
        #expect(planned.contains { $0.budgetID == budgetID })
        // The budget warning is recorded for the month.
        #expect(store.loadBudgetWarningLog().budgetIDs.contains(budgetID))
        #expect(store.loadBudgetWarningLog().monthKey == "2026-11")
    }

    /// A warning still pending is re-planned (replaced, not duplicated);
    /// once delivered — gone from pending — it stays suppressed for the
    /// rest of the month.
    @Test func schedulerSuppressesDeliveredBudgetWarnings() async throws {
        let context = try makeContext()
        let now = day(2026, 11, 15, 8)
        let budgetID = try seedReminderFixtures(context: context, now: now)
        let budgetIdentifier = ReminderPlanner.budgetIdentifier(
            budgetID: budgetID, monthKey: "2026-11")

        let store = ReminderSettingsStore(defaults: makeDefaults())
        store.save(ReminderSettings(isEnabled: true))
        let fake = ReminderFakeCenter()
        let scheduler = ReminderScheduler(
            center: fake, settingsStore: store, calendar: calendar)

        // First run schedules the warning; a second run with it still
        // pending replaces it — still exactly one request.
        _ = await scheduler.reschedule(context: context, now: now)
        fake.added.removeAll()
        _ = await scheduler.reschedule(context: context, now: now)
        #expect(fake.added.map(\.id).contains(budgetIdentifier))
        #expect(fake.pending.filter { $0 == budgetIdentifier }.count == 1)

        // Simulate delivery — the pending request is gone — and the next
        // reschedule must not warn again this month.
        fake.pending.removeAll { $0 == budgetIdentifier }
        fake.added.removeAll()
        _ = await scheduler.reschedule(context: context, now: now)
        #expect(!fake.added.map(\.id).contains(budgetIdentifier))
    }

    /// With the master switch off the queue is cleared and nothing added.
    @Test func schedulerDisabledClearsPending() async throws {
        let context = try makeContext()
        let now = day(2026, 11, 15, 8)
        _ = try seedReminderFixtures(context: context, now: now)

        let store = ReminderSettingsStore(defaults: makeDefaults())
        // isEnabled defaults to false.
        let fake = ReminderFakeCenter()
        fake.pending = ["amfinance.reminder.debt.card.stale"]
        let scheduler = ReminderScheduler(
            center: fake, settingsStore: store, calendar: calendar)

        let planned = await scheduler.reschedule(context: context, now: now)
        #expect(planned.isEmpty)
        #expect(fake.added.isEmpty)
        #expect(fake.removed == ["amfinance.reminder.debt.card.stale"])
    }

    /// Denied permission still cleans the queue but schedules nothing and
    /// marks no budget as warned.
    @Test func schedulerDeniedAddsNothing() async throws {
        let context = try makeContext()
        let now = day(2026, 11, 15, 8)
        _ = try seedReminderFixtures(context: context, now: now)

        let store = ReminderSettingsStore(defaults: makeDefaults())
        store.save(ReminderSettings(isEnabled: true))
        let fake = ReminderFakeCenter()
        fake.status = .denied
        let scheduler = ReminderScheduler(
            center: fake, settingsStore: store, calendar: calendar)

        let planned = await scheduler.reschedule(context: context, now: now)
        #expect(!planned.isEmpty)          // the plan exists…
        #expect(fake.added.isEmpty)        // …but nothing was scheduled
        #expect(store.loadBudgetWarningLog().budgetIDs.isEmpty)
    }

    /// The real-model path: a card with a statement due feeds a "debt"
    /// notification end to end.
    @Test func schedulerGathersCardDebtFromModels() async throws {
        let context = try makeContext()
        let now = day(2026, 12, 1, 8)

        let card = Account(name: "Thẻ VPBank", kind: .creditCard)
        card.creditLimit = 30_000_000
        card.statementDay = 20
        card.graceDays = 15
        context.insert(card)
        // Spending inside the Oct 21 – Nov 20 cycle (closed, due 05/12).
        context.insert(LedgerTransaction(
            kind: .expense, amount: 3_200_000,
            date: day(2026, 11, 10), account: card))
        try context.save()

        let store = ReminderSettingsStore(defaults: makeDefaults())
        store.save(ReminderSettings(isEnabled: true))
        let fake = ReminderFakeCenter()
        let scheduler = ReminderScheduler(
            center: fake, settingsStore: store, calendar: calendar)

        let planned = await scheduler.reschedule(context: context, now: now)
        let debtItems = planned.filter { $0.id.contains("debt.card.") }
        #expect(!debtItems.isEmpty)
        #expect(debtItems.allSatisfy {
            $0.body.contains("Thẻ VPBank") && $0.body.contains("3.200.000 ₫")
        })
        // Due 05/12 — 4 days out — fires on d3, d1 and d0 at 9:00.
        #expect(debtItems.count == 3)
        #expect(debtItems.map(\.fireDate) == [
            day(2026, 12, 2, 9), day(2026, 12, 4, 9), day(2026, 12, 5, 9),
        ])
    }

    // MARK: - Scheduler: rent collection

    private func seedRental(
        context: ModelContext, name: String = "Phòng 101",
        rent: Int64 = 4_500_000, paymentDay: Int = 25,
        tenant: String = "Nguyễn Văn A", isActive: Bool = true
    ) throws -> RentalLease {
        let unit = RentalUnit(name: name, listPrice: rent)
        let lease = RentalLease(
            tenantName: tenant, startDate: day(2026, 1, 1),
            monthlyRent: rent, paymentDay: paymentDay,
            isActive: isActive, unit: unit)
        context.insert(unit)
        context.insert(lease)
        try context.save()
        return lease
    }

    private func makeScheduler(
        fake: ReminderFakeCenter
    ) -> ReminderScheduler {
        let store = ReminderSettingsStore(defaults: makeDefaults())
        store.save(ReminderSettings(isEnabled: true))
        return ReminderScheduler(
            center: fake, settingsStore: store, calendar: calendar)
    }

    /// The real-model path: an unpaid lease feeds "rent" notifications —
    /// the payment day, the +3-day nag and next month's payment day.
    @Test func schedulerGathersRentFromModels() async throws {
        let context = try makeContext()
        let now = day(2026, 11, 20, 8)
        _ = try seedRental(context: context)

        let fake = ReminderFakeCenter()
        let planned = await makeScheduler(fake: fake)
            .reschedule(context: context, now: now)

        let rentItems = planned.filter { $0.id.contains("rent.") }
        #expect(rentItems.map(\.fireDate) == [
            day(2026, 11, 25, 9), day(2026, 11, 28, 9), day(2026, 12, 25, 9),
        ])
        #expect(rentItems.allSatisfy {
            $0.body.contains("Phòng 101") && $0.body.contains("Nguyễn Văn A")
        })
    }

    /// A partial collection feeds the remaining amount into the plan.
    @Test func schedulerGathersPartialRentRemaining() async throws {
        let context = try makeContext()
        let now = day(2026, 11, 20, 8)
        let lease = try seedRental(context: context)
        context.insert(LedgerTransaction(
            kind: .income, amount: 3_000_000, date: day(2026, 11, 5),
            rentalLease: lease, rentalPeriod: day(2026, 11, 1, 0)))
        try context.save()

        let fake = ReminderFakeCenter()
        let planned = await makeScheduler(fake: fake)
            .reschedule(context: context, now: now)

        let rentItems = planned.filter { $0.id.contains("rent.") }
        let november = rentItems.filter { $0.id.contains("2026-11") }
        #expect(november.count == 2)
        #expect(november.allSatisfy { $0.body.contains("1.500.000 ₫") })
        #expect(rentItems.first {
            $0.id.hasSuffix("2026-11.due")
        }?.body == "Phòng 101: thu 1.500.000 ₫ tiền tháng 11 · Nguyễn Văn A")
        // December is still fully uncollected — it shows the full rent.
        #expect(rentItems.first { $0.id.hasSuffix("2026-12.due") }?.body
            .contains("4.500.000 ₫") == true)
    }

    /// Once the month is fully collected the lease produces nothing at
    /// all — and an ended lease covering the month is skipped too.
    @Test func schedulerSkipsCollectedAndInactiveLeases() async throws {
        let context = try makeContext()
        let now = day(2026, 11, 20, 8)
        let lease = try seedRental(context: context)
        context.insert(LedgerTransaction(
            kind: .income, amount: 4_500_000, date: day(2026, 11, 5),
            rentalLease: lease, rentalPeriod: day(2026, 11, 1, 0)))
        // An ended lease still owns its month but isn't active.
        _ = try seedRental(
            context: context, name: "Phòng 102", rent: 3_000_000,
            tenant: "Cũ", isActive: false)
        try context.save()

        let fake = ReminderFakeCenter()
        let planned = await makeScheduler(fake: fake)
            .reschedule(context: context, now: now)
        #expect(planned.filter { $0.id.contains("rent.") }.isEmpty)
    }

    /// Due day 31 clamps to the 30th inside November (a 30-day month);
    /// the nag follows three days later and December keeps the real 31st.
    @Test func schedulerClampsPaymentDayToMonthLength() async throws {
        let context = try makeContext()
        let now = day(2026, 11, 10, 8)
        _ = try seedRental(context: context, paymentDay: 31)

        let fake = ReminderFakeCenter()
        let planned = await makeScheduler(fake: fake)
            .reschedule(context: context, now: now)

        let rentItems = planned.filter { $0.id.contains("rent.") }
        #expect(rentItems.map(\.fireDate) == [
            day(2026, 11, 30, 9), day(2026, 12, 3, 9), day(2026, 12, 31, 9),
        ])
        #expect(rentItems.map(\.title) == [
            "Thu tiền phòng", "Quá hạn 3 ngày", "Thu tiền phòng",
        ])
    }

    /// "Gửi thử" goes through the center's test path in five seconds and
    /// outside the reminder prefix so reschedule never cancels it.
    @Test func sendTestNotificationSchedulesFiveSecondTest() async throws {
        let fake = ReminderFakeCenter()
        let scheduler = ReminderScheduler(
            center: fake,
            settingsStore: ReminderSettingsStore(defaults: makeDefaults()),
            calendar: calendar)
        try await scheduler.sendTestNotification()
        #expect(fake.testCalls.count == 1)
        #expect(fake.testCalls[0].seconds == 5)
        #expect(!fake.testCalls[0].identifier
            .hasPrefix(ReminderPlanner.identifierPrefix))
    }
}
