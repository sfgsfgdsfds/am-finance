import Testing
import SwiftData
import Foundation
import FinanceCore
@testable import AMFinance

@MainActor
struct ModelsV2Tests {

    private let calendar = AppCalendar.vietnam

    private func makeContext() throws -> ModelContext {
        ModelContext(try AppModelContainer.make(inMemory: true))
    }

    private func fetchAll<T: PersistentModel>(_ type: T.Type, in context: ModelContext) throws -> [T] {
        try context.fetch(FetchDescriptor<T>())
    }

    /// A start-of-day instant in Asia/Ho_Chi_Minh — same day granularity the
    /// recurrence engine works at.
    private func day(_ year: Int, _ month: Int, _ dayOfMonth: Int) -> Date {
        calendar.date(from: DateComponents(year: year, month: month, day: dayOfMonth))!
    }

    // MARK: - Round trips

    @Test func budgetRoundTripsInMemoryContainer() throws {
        let context = try makeContext()
        let food = LedgerCategory(name: "Ăn uống", kind: .expense)
        context.insert(food)
        let overall = Budget(monthlyLimit: 10_000_000, note: "Tổng chi")
        let foodBudget = Budget(monthlyLimit: 3_000_000, isActive: false,
                                note: "Ăn uống", category: food)
        context.insert(overall)
        context.insert(foodBudget)
        try context.save()

        let budgets = try fetchAll(Budget.self, in: context)
        #expect(budgets.count == 2)

        // nil category = overall monthly budget.
        let rOverall = try #require(budgets.first { $0.id == overall.id })
        #expect(rOverall.monthlyLimit == 10_000_000)
        #expect(rOverall.isActive)
        #expect(rOverall.note == "Tổng chi")
        #expect(rOverall.category == nil)

        let rFood = try #require(budgets.first { $0.id == foodBudget.id })
        #expect(rFood.monthlyLimit == 3_000_000)
        #expect(!rFood.isActive)
        #expect(rFood.category?.id == food.id)
        #expect(food.budgets?.count == 1)
    }

    @Test func recurringRuleRoundTripsAndBuildsSchedule() throws {
        let context = try makeContext()
        let bank = Account(name: "Ngân hàng", kind: .bank)
        let food = LedgerCategory(name: "Ăn uống", kind: .expense)
        let web = Business(name: "Làm web")
        context.insert(bank)
        context.insert(food)
        context.insert(web)

        let rule = RecurringRule(
            title: "Thuê nhà", kind: .expense, amount: 7_000_000,
            note: "Hằng tháng", account: bank,
            category: food, business: web,
            frequency: .monthly, interval: 2,
            startDate: day(2026, 1, 5), endDate: day(2027, 1, 5),
            maximumOccurrences: 6, autoCreate: true, isActive: true
        )
        context.insert(rule)
        try context.save()

        let stored = try #require(try fetchAll(RecurringRule.self, in: context).first)
        #expect(stored.title == "Thuê nhà")
        #expect(stored.kind == .expense)
        #expect(stored.frequency == .monthly)
        #expect(stored.account?.id == bank.id)
        #expect(stored.category?.id == food.id)
        #expect(stored.business?.id == web.id)
        #expect(bank.recurringRules?.count == 1)
        #expect(food.recurringRules?.count == 1)
        #expect(web.recurringRules?.count == 1)

        let schedule = try #require(stored.recurrenceRule(calendar: calendar))
        #expect(schedule.frequency == .monthly)
        #expect(schedule.interval == 2)
        #expect(schedule.startDate == day(2026, 1, 5))
        #expect(schedule.endDate == day(2027, 1, 5))
        #expect(schedule.maximumOccurrences == 6)

        // Computed setters write the raw strings back.
        stored.kind = .transfer
        stored.frequency = .weekly
        #expect(stored.kindRaw == "transfer")
        #expect(stored.frequencyRaw == "weekly")
        try context.save()
    }

    @Test func invalidScheduleBuildsNoRule() throws {
        let badInterval = RecurringRule(
            title: "x", kind: .expense, amount: 1,
            frequency: .monthly, interval: 0, startDate: day(2026, 1, 1)
        )
        #expect(badInterval.recurrenceRule(calendar: calendar) == nil)

        let endBeforeStart = RecurringRule(
            title: "x", kind: .expense, amount: 1,
            frequency: .monthly, startDate: day(2026, 1, 5),
            endDate: day(2026, 1, 4)
        )
        #expect(endBeforeStart.recurrenceRule(calendar: calendar) == nil)

        let badMaximum = RecurringRule(
            title: "x", kind: .expense, amount: 1,
            frequency: .monthly, startDate: day(2026, 1, 5),
            maximumOccurrences: 0
        )
        #expect(badMaximum.recurrenceRule(calendar: calendar) == nil)
    }

    /// `.nullify` — cascades can't sync to CloudKit — so deleting a category
    /// leaves budgets and rules behind with `category == nil`.
    @Test func deletingCategoryNullifiesBudgetAndRule() throws {
        let context = try makeContext()
        let food = LedgerCategory(name: "Ăn uống", kind: .expense)
        context.insert(food)
        let budget = Budget(monthlyLimit: 3_000_000, category: food)
        let rule = RecurringRule(
            title: "Thuê", kind: .expense, amount: 1_000, category: food,
            frequency: .monthly, startDate: day(2026, 1, 5)
        )
        context.insert(budget)
        context.insert(rule)
        try context.save()

        context.delete(food)
        try context.save()

        #expect(budget.category == nil)
        #expect(rule.category == nil)
        #expect(try fetchAll(Budget.self, in: context).count == 1)
        #expect(try fetchAll(RecurringRule.self, in: context).count == 1)
    }

    // MARK: - RecurringGenerator

    @Test func generatorCreatesMonthlyRows() throws {
        let context = try makeContext()
        let bank = Account(name: "Ngân hàng", kind: .bank, openingBalance: 1_000_000)
        let food = LedgerCategory(name: "Ăn uống", kind: .expense)
        let web = Business(name: "Làm web")
        context.insert(bank)
        context.insert(food)
        context.insert(web)

        let rule = RecurringRule(
            title: "Thuê phòng", kind: .income, amount: 2_000_000,
            account: bank, category: food, business: web,
            frequency: .monthly, startDate: day(2026, 9, 15)
        )
        context.insert(rule)
        try context.save()

        let created = try RecurringGenerator.generateDueTransactions(
            in: context, now: day(2026, 11, 22)
        )
        #expect(created == 3)
        #expect(rule.lastGeneratedDate == day(2026, 11, 15))

        let transactions = try fetchAll(LedgerTransaction.self, in: context)
            .sorted { $0.date < $1.date }
        #expect(transactions.map(\.date) == [
            day(2026, 9, 15), day(2026, 10, 15), day(2026, 11, 15),
        ])
        for transaction in transactions {
            #expect(transaction.kindRaw == "income")
            #expect(transaction.amount == 2_000_000)
            // Empty note falls back to the rule title.
            #expect(transaction.note == "Thuê phòng")
            #expect(transaction.account?.id == bank.id)
            #expect(transaction.category?.id == food.id)
            #expect(transaction.business?.id == web.id)
        }
        #expect(bank.balance == 1_000_000 + 3 * 2_000_000)

        // Idempotent: a second run at the same `now` creates nothing.
        #expect(try RecurringGenerator.generateDueTransactions(
            in: context, now: day(2026, 11, 22)
        ) == 0)
        #expect(try fetchAll(LedgerTransaction.self, in: context).count == 3)
    }

    @Test func generatorCreatesWeeklyTransferRows() throws {
        let context = try makeContext()
        let bank = Account(name: "Ngân hàng", kind: .bank, openingBalance: 10_000_000)
        let wallet = Account(name: "Ví", kind: .eWallet)
        context.insert(bank)
        context.insert(wallet)

        let rule = RecurringRule(
            title: "Nạp ví", kind: .transfer, amount: 500_000,
            note: "Top-up", account: bank, toAccount: wallet,
            frequency: .weekly, startDate: day(2026, 11, 2)
        )
        context.insert(rule)
        try context.save()

        let created = try RecurringGenerator.generateDueTransactions(
            in: context, now: day(2026, 11, 22)
        )
        #expect(created == 3)

        let transactions = try fetchAll(LedgerTransaction.self, in: context)
        #expect(transactions.map(\.date).sorted() == [
            day(2026, 11, 2), day(2026, 11, 9), day(2026, 11, 16),
        ])
        for transaction in transactions {
            #expect(transaction.kindRaw == "transfer")
            // An explicit note wins over the title fallback.
            #expect(transaction.note == "Top-up")
            #expect(transaction.account?.id == bank.id)
            #expect(transaction.toAccount?.id == wallet.id)
        }
        #expect(bank.balance == 10_000_000 - 1_500_000)
        #expect(wallet.balance == 1_500_000)
    }

    @Test func generatorRespectsEndDate() throws {
        let context = try makeContext()
        let bank = Account(name: "Ngân hàng", kind: .bank)
        context.insert(bank)
        context.insert(RecurringRule(
            title: "Gói có hạn", kind: .expense, amount: 100_000,
            account: bank, frequency: .monthly,
            startDate: day(2026, 9, 15), endDate: day(2026, 10, 20)
        ))
        try context.save()

        #expect(try RecurringGenerator.generateDueTransactions(
            in: context, now: day(2026, 11, 22)
        ) == 2)
        let dates = try fetchAll(LedgerTransaction.self, in: context).map(\.date).sorted()
        #expect(dates == [day(2026, 9, 15), day(2026, 10, 15)])
        #expect(bank.balance == -200_000)
    }

    @Test func generatorRespectsMaximumOccurrences() throws {
        let context = try makeContext()
        let bank = Account(name: "Ngân hàng", kind: .bank)
        context.insert(bank)
        context.insert(RecurringRule(
            title: "Hai lần", kind: .expense, amount: 100_000,
            account: bank, frequency: .monthly,
            startDate: day(2026, 9, 15), maximumOccurrences: 2
        ))
        try context.save()

        #expect(try RecurringGenerator.generateDueTransactions(
            in: context, now: day(2026, 11, 22)
        ) == 2)
        // The cap is permanent: a later run produces nothing more.
        #expect(try RecurringGenerator.generateDueTransactions(
            in: context, now: day(2026, 12, 20)
        ) == 0)
        #expect(try fetchAll(LedgerTransaction.self, in: context).count == 2)
    }

    @Test func generatorSkipsInactiveRemindOnlyAndInvalidRules() throws {
        let context = try makeContext()
        let bank = Account(name: "Ngân hàng", kind: .bank)
        context.insert(bank)
        let inactive = RecurringRule(
            title: "Tắt", kind: .expense, amount: 1_000,
            account: bank, frequency: .daily,
            startDate: day(2026, 1, 1), isActive: false
        )
        let remindOnly = RecurringRule(
            title: "Nhắc", kind: .expense, amount: 1_000,
            account: bank, frequency: .daily,
            startDate: day(2026, 1, 1), autoCreate: false
        )
        let invalid = RecurringRule(
            title: "Hỏng", kind: .expense, amount: 1_000,
            account: bank, frequency: .daily, interval: 0,
            startDate: day(2026, 1, 1)
        )
        context.insert(inactive)
        context.insert(remindOnly)
        context.insert(invalid)
        try context.save()

        #expect(try RecurringGenerator.generateDueTransactions(
            in: context, now: day(2026, 11, 22)
        ) == 0)
        #expect(try fetchAll(LedgerTransaction.self, in: context).isEmpty)
        // Skipped rules are left completely alone.
        #expect(inactive.lastGeneratedDate == nil)
        #expect(remindOnly.lastGeneratedDate == nil)
        #expect(invalid.lastGeneratedDate == nil)
        #expect(bank.balance == 0)
    }

    /// A rule that never ran may have more than 36 missed occurrences; the
    /// per-run cap produces the earliest ones and the next run picks up the
    /// rest — nothing is silently dropped.
    @Test func generatorResumesBacklogAcrossRuns() throws {
        let context = try makeContext()
        let bank = Account(name: "Ngân hàng", kind: .bank)
        context.insert(bank)
        let rule = RecurringRule(
            title: "Hằng ngày", kind: .expense, amount: 1_000,
            account: bank, frequency: .daily, startDate: day(2026, 10, 1)
        )
        context.insert(rule)
        try context.save()

        let now = day(2026, 11, 22) // 53 occurrences: Oct 1 … Nov 22
        #expect(try RecurringGenerator.generateDueTransactions(
            in: context, now: now
        ) == RecurringGenerator.perRunLimit)
        #expect(rule.lastGeneratedDate == day(2026, 11, 5))

        #expect(try RecurringGenerator.generateDueTransactions(
            in: context, now: now
        ) == 17)
        #expect(rule.lastGeneratedDate == now)
        #expect(try fetchAll(LedgerTransaction.self, in: context).count == 53)

        #expect(try RecurringGenerator.generateDueTransactions(
            in: context, now: now
        ) == 0)
    }

    /// Nothing due yet: no rows, but `lastGeneratedDate` still advances to
    /// `now` so the rule is marked as checked through.
    @Test func generatorWithFutureStartOnlyStampsCheck() throws {
        let context = try makeContext()
        let bank = Account(name: "Ngân hàng", kind: .bank)
        context.insert(bank)
        let rule = RecurringRule(
            title: "Sắp tới", kind: .expense, amount: 1_000,
            account: bank, frequency: .daily, startDate: day(2026, 12, 1)
        )
        context.insert(rule)
        try context.save()

        let now = day(2026, 11, 22)
        #expect(try RecurringGenerator.generateDueTransactions(
            in: context, now: now
        ) == 0)
        #expect(try fetchAll(LedgerTransaction.self, in: context).isEmpty)
        #expect(rule.lastGeneratedDate == now)
    }
}
