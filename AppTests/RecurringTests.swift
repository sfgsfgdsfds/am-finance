import Testing
import Foundation
import SwiftData
import FinanceCore
@testable import AMFinance

@MainActor
struct RecurringTests {

    private let calendar = AppCalendar.vietnam

    private func makeContext() throws -> ModelContext {
        ModelContext(try AppModelContainer.make(inMemory: true))
    }

    private func fetchAll<T: PersistentModel>(_ type: T.Type, in context: ModelContext) throws -> [T] {
        try context.fetch(FetchDescriptor<T>())
    }

    /// A moment in Asia/Ho_Chi_Minh — hour 12 acts as "now"; hour 0
    /// (via `sod`) matches the engine's start-of-day occurrences.
    private func day(_ year: Int, _ month: Int, _ dayOfMonth: Int, _ hour: Int = 12) -> Date {
        calendar.date(from: DateComponents(
            year: year, month: month, day: dayOfMonth, hour: hour
        ))!
    }

    /// Start-of-day instant — occurrence dates compare equal to this.
    private func sod(_ year: Int, _ month: Int, _ dayOfMonth: Int) -> Date {
        day(year, month, dayOfMonth, 0)
    }

    // MARK: - Draft validation

    @Test func emptyDraftFailsTitleAmountAndAccount() {
        let draft = RecurringDraft()
        #expect(Set(draft.validate(calendar: calendar)) == [
            .missingTitle, .missingAmount, .missingAccount,
        ])
        #expect(!draft.isValid)
    }

    @Test func whitespaceTitleCountsAsMissing() {
        var draft = RecurringDraft()
        draft.title = "   "
        draft.amount = 10_000
        draft.account = Account(name: "Tiền mặt", kind: .cash)
        #expect(draft.validate(calendar: calendar) == [.missingTitle])
    }

    @Test func completeExpenseAndIncomeDraftsAreValid() {
        let cash = Account(name: "Tiền mặt", kind: .cash)

        var expense = RecurringDraft()
        expense.title = "Thuê mặt bằng"
        expense.amount = 7_000_000
        expense.account = cash
        expense.category = LedgerCategory(name: "Nhà cửa", kind: .expense)
        #expect(expense.isValid)

        var income = RecurringDraft()
        income.title = "Lương"
        income.kind = .income
        income.amount = 20_000_000
        income.account = cash
        income.category = LedgerCategory(name: "Lương & thù lao", kind: .income)
        #expect(income.isValid)
    }

    @Test func transferRequiresDestination() {
        var draft = RecurringDraft()
        draft.title = "Trả nợ thẻ"
        draft.kind = .transfer
        draft.amount = 2_000_000
        draft.account = Account(name: "Ngân hàng", kind: .bank)
        #expect(draft.validate(calendar: calendar) == [.missingDestination])
    }

    @Test func transferRejectsSourceAsDestination() {
        let bank = Account(name: "Ngân hàng", kind: .bank)
        var draft = RecurringDraft()
        draft.title = "Trả nợ thẻ"
        draft.kind = .transfer
        draft.amount = 2_000_000
        draft.account = bank
        draft.toAccount = bank
        #expect(draft.validate(calendar: calendar) == [.sameSourceAndDestination])
    }

    @Test func categoryMustMatchKind() {
        var draft = RecurringDraft()
        draft.title = "Lương"
        draft.kind = .income
        draft.amount = 1_000_000
        draft.account = Account(name: "Ngân hàng", kind: .bank)
        draft.category = LedgerCategory(name: "Ăn uống", kind: .expense)
        #expect(draft.validate(calendar: calendar) == [.categoryKindMismatch])
    }

    @Test func switchingToTransferClearsCategoryAndBusiness() {
        var draft = RecurringDraft()
        draft.category = LedgerCategory(name: "Ăn uống", kind: .expense)
        draft.business = Business(name: "Làm web")
        draft.setKind(.transfer)
        #expect(draft.category == nil)
        #expect(draft.business == nil)
    }

    @Test func endDateBeforeStartFails() {
        var draft = RecurringDraft()
        draft.title = "Gói có hạn"
        draft.amount = 100_000
        draft.account = Account(name: "Tiền mặt", kind: .cash)
        draft.startDate = day(2026, 1, 10)
        draft.endMode = .date
        draft.endDate = day(2026, 1, 9)
        #expect(draft.validate(calendar: calendar).contains(.endBeforeStart))
        // Same calendar day is allowed — one occurrence.
        draft.endDate = day(2026, 1, 10)
        #expect(draft.isValid)
    }

    @Test func invalidIntervalAndEndCountFail() {
        var draft = RecurringDraft()
        draft.title = "x"
        draft.amount = 1_000
        draft.account = Account(name: "Tiền mặt", kind: .cash)

        draft.interval = 0
        #expect(draft.validate(calendar: calendar).contains(.invalidInterval))
        draft.interval = 1

        draft.endMode = .count
        draft.endCount = 0
        #expect(draft.validate(calendar: calendar).contains(.invalidEndCount))
        draft.endCount = 3
        #expect(draft.isValid)
    }

    // MARK: - Draft ↔ model round trip

    @Test func insertThenReadBackMatchesDraft() throws {
        let context = try makeContext()
        let bank = Account(name: "Ngân hàng", kind: .bank)
        let tools = LedgerCategory(name: "Công cụ", kind: .expense)
        let web = Business(name: "Làm web")
        context.insert(bank)
        context.insert(tools)
        context.insert(web)

        var draft = RecurringDraft()
        draft.title = "  ChatGPT Plus  "
        draft.amount = 500_000
        draft.account = bank
        draft.category = tools
        draft.business = web
        draft.frequency = .weekly
        draft.interval = 2
        draft.startDate = day(2026, 1, 5)
        draft.endMode = .count
        draft.endCount = 8
        draft.autoCreate = false
        draft.note = "Gói AI"

        let rule = try draft.insert(into: context)
        try context.save()

        // The title is stored trimmed; the rule starts active and the
        // generator has nothing recorded yet.
        #expect(rule.title == "ChatGPT Plus")
        #expect(rule.isActive)
        #expect(rule.lastGeneratedDate == nil)

        let stored = try #require(try fetchAll(RecurringRule.self, in: context).first)
        #expect(stored.kind == .expense)
        #expect(stored.amount == 500_000)
        #expect(stored.account?.id == bank.id)
        #expect(stored.category?.id == tools.id)
        #expect(stored.business?.id == web.id)
        #expect(stored.frequency == .weekly)
        #expect(stored.interval == 2)
        #expect(stored.startDate == day(2026, 1, 5))
        #expect(stored.endDate == nil)
        #expect(stored.maximumOccurrences == 8)
        #expect(!stored.autoCreate)
        #expect(stored.note == "Gói AI")

        let roundTrip = RecurringDraft(rule: stored)
        #expect(roundTrip.title == "ChatGPT Plus")
        #expect(roundTrip.kind == .expense)
        #expect(roundTrip.amount == 500_000)
        #expect(roundTrip.account?.id == bank.id)
        #expect(roundTrip.category?.id == tools.id)
        #expect(roundTrip.business?.id == web.id)
        #expect(roundTrip.frequency == .weekly)
        #expect(roundTrip.interval == 2)
        #expect(roundTrip.endMode == .count)
        #expect(roundTrip.endCount == 8)
        #expect(!roundTrip.autoCreate)
        #expect(roundTrip.note == "Gói AI")
    }

    @Test func dateEndModeRoundTrips() {
        var draft = RecurringDraft()
        draft.startDate = day(2026, 1, 1)
        draft.endMode = .date
        draft.endDate = day(2026, 12, 31)
        #expect(draft.resolvedEndDate == day(2026, 12, 31))
        #expect(draft.resolvedMaximumOccurrences == nil)

        let rule = RecurringRule(
            title: "Có hạn", kind: .expense, amount: 1_000,
            frequency: .monthly, startDate: day(2026, 1, 1),
            endDate: day(2026, 12, 31)
        )
        let back = RecurringDraft(rule: rule)
        #expect(back.endMode == .date)
        #expect(back.endDate == day(2026, 12, 31))
    }

    @Test func transferDraftNormalizesToModel() throws {
        let context = try makeContext()
        let bank = Account(name: "Ngân hàng", kind: .bank)
        let wallet = Account(name: "Ví", kind: .eWallet)
        context.insert(bank)
        context.insert(wallet)

        var draft = RecurringDraft()
        draft.title = "Nạp ví"
        draft.kind = .transfer
        draft.amount = 300_000
        draft.account = bank
        draft.toAccount = wallet
        // Leftovers the form never shows for transfers must not be saved.
        draft.category = LedgerCategory(name: "Không lưu", kind: .expense)
        draft.business = Business(name: "Không lưu")

        let rule = try draft.insert(into: context)
        try context.save()

        #expect(rule.toAccount?.id == wallet.id)
        #expect(rule.category == nil)
        #expect(rule.business == nil)
    }

    @Test func applyWritesScheduleButKeepsStateFlags() throws {
        let context = try makeContext()
        let cash = Account(name: "Tiền mặt", kind: .cash)
        context.insert(cash)
        let rule = RecurringRule(
            title: "Cũ", kind: .expense, amount: 100_000,
            account: cash, frequency: .monthly,
            startDate: day(2026, 1, 1),
            lastGeneratedDate: day(2026, 10, 1),
            autoCreate: true, isActive: false
        )
        context.insert(rule)
        try context.save()

        var draft = RecurringDraft(rule: rule)
        #expect(draft.endMode == .never)
        draft.title = "Mới"
        draft.amount = 250_000
        draft.frequency = .weekly
        draft.autoCreate = false
        try draft.apply(to: rule)
        try context.save()

        #expect(rule.title == "Mới")
        #expect(rule.amount == 250_000)
        #expect(rule.frequency == .weekly)
        #expect(!rule.autoCreate)
        // Editing the schedule never pauses/unpauses the rule or rewinds
        // the generator's progress marker.
        #expect(!rule.isActive)
        #expect(rule.lastGeneratedDate == day(2026, 10, 1))
    }

    // MARK: - Upcoming: ordering and totals over 30 days

    /// now = 10/11/2026; the window covers 10/11 → 10/12 inclusive.
    private func mixedRules() -> [RecurringUpcoming.Input] {
        [
            // Daily expense 10k from 8/11 → 31 occurrences in the window.
            .init(title: "Cà phê", kind: .expense, amount: 10_000,
                  frequency: .daily, startDate: day(2026, 11, 8)),
            // Weekly expense 100k on Thursdays → 5 occurrences.
            .init(title: "Đi chợ", kind: .expense, amount: 100_000,
                  frequency: .weekly, startDate: day(2026, 11, 12)),
            // Monthly income 5tr on the 15th → 15/11 inside the window.
            .init(title: "Tiền thuê", kind: .income, amount: 5_000_000,
                  frequency: .monthly, startDate: day(2026, 10, 15)),
            // Weekly income 2tr → 13/11, 20/11, 27/11, 4/12 inside.
            .init(title: "Lương", kind: .income, amount: 2_000_000,
                  frequency: .weekly, startDate: day(2026, 11, 6)),
            // Daily transfer 1tr from 11/11 → 30 occurrences in the list,
            // but never inside the expected Thu/Chi totals.
            .init(title: "Trả nợ", kind: .transfer, amount: 1_000_000,
                  frequency: .daily, startDate: day(2026, 11, 11)),
            // Paused rules are invisible to the window entirely.
            .init(title: "Tạm dừng", kind: .expense, amount: 99_000,
                  frequency: .daily, startDate: day(2026, 11, 8),
                  isActive: false),
        ]
    }

    @Test func upcomingOrdersChronologicallyAcrossFrequencies() {
        let now = day(2026, 11, 10)
        let window = RecurringUpcoming.window(days: 30, now: now, calendar: calendar)
        let items = RecurringUpcoming.occurrences(
            in: mixedRules(), window: window, now: now, calendar: calendar
        )

        // 31 daily + 5 weekly expenses, 1 monthly + 4 weekly incomes,
        // 30 transfers — the paused rule contributes nothing.
        #expect(items.count == 71)
        #expect(items.first?.date == sod(2026, 11, 10))
        #expect(items.first?.daysUntil == 0)
        #expect(items.first?.statusText == "Hôm nay")
        #expect(items.last?.date == sod(2026, 12, 10))
        #expect(items.last?.daysUntil == 30)
        // Chronological throughout.
        #expect(items.map(\.date) == items.map(\.date).sorted())
        // Transfers do appear in the upcoming list.
        #expect(items.filter { $0.kind == .transfer }.count == 30)
    }

    @Test func upcomingTotalsSkipTransfersAndPaused() {
        let now = day(2026, 11, 10)
        let window = RecurringUpcoming.window(days: 30, now: now, calendar: calendar)
        let totals = RecurringUpcoming.totals(
            in: mixedRules(), window: window, now: now, calendar: calendar
        )

        #expect(totals.income == 5_000_000 + 4 * 2_000_000)
        #expect(totals.expense == 31 * 10_000 + 5 * 100_000)
        #expect(totals.net == 13_000_000 - 810_000)
    }

    @Test func windowIncludesBoundaryDay() {
        let now = day(2026, 11, 10)
        let window = RecurringUpcoming.window(days: 30, now: now, calendar: calendar)
        // Exactly 30 days out is inside; 31 days out is not.
        let rule = RecurringUpcoming.Input(
            title: "Hằng ngày", kind: .expense, amount: 1_000,
            frequency: .daily, startDate: day(2026, 12, 10)
        )
        let inside = RecurringUpcoming.occurrences(
            in: [rule], window: window, now: now, calendar: calendar
        )
        #expect(inside.map(\.date) == [sod(2026, 12, 10)])

        let justOutside = RecurringUpcoming.Input(
            title: "Hằng ngày", kind: .expense, amount: 1_000,
            frequency: .daily, startDate: day(2026, 12, 11)
        )
        #expect(RecurringUpcoming.occurrences(
            in: [justOutside], window: window, now: now, calendar: calendar
        ).isEmpty)
    }

    // MARK: - Next occurrence & finished detection

    @Test func nextOccurrenceIncludesToday() {
        let input = RecurringUpcoming.Input(
            title: "Hằng ngày", kind: .expense, amount: 1_000,
            frequency: .daily, startDate: day(2026, 11, 1)
        )
        #expect(RecurringUpcoming.nextOccurrence(
            of: input, asOf: day(2026, 11, 10), calendar: calendar
        ) == sod(2026, 11, 10))
    }

    @Test func finishedByEndDatePassed() {
        let input = RecurringUpcoming.Input(
            title: "Gói có hạn", kind: .expense, amount: 1_000,
            frequency: .monthly, startDate: day(2026, 9, 5),
            endDate: day(2026, 10, 20)
        )
        #expect(RecurringUpcoming.isFinished(
            input, asOf: day(2026, 11, 10), calendar: calendar
        ))
    }

    @Test func finishedByCountReached() {
        let input = RecurringUpcoming.Input(
            title: "Hai lần", kind: .expense, amount: 1_000,
            frequency: .monthly, startDate: day(2026, 9, 15),
            maximumOccurrences: 2
        )
        // 15/9 and 15/10 are done; nothing remains on or after 10/11.
        #expect(RecurringUpcoming.isFinished(
            input, asOf: day(2026, 11, 10), calendar: calendar
        ))
    }

    @Test func liveAndFutureRulesAreNotFinished() {
        let ongoing = RecurringUpcoming.Input(
            title: "Hằng tháng", kind: .expense, amount: 1_000,
            frequency: .monthly, startDate: day(2026, 9, 15)
        )
        #expect(!RecurringUpcoming.isFinished(
            ongoing, asOf: day(2026, 11, 10), calendar: calendar
        ))

        let future = RecurringUpcoming.Input(
            title: "Sắp bắt đầu", kind: .expense, amount: 1_000,
            frequency: .monthly, startDate: day(2026, 12, 1)
        )
        #expect(!RecurringUpcoming.isFinished(
            future, asOf: day(2026, 11, 10), calendar: calendar
        ))

        // A paused rule still has occurrences — it is paused, not finished.
        let paused = RecurringUpcoming.Input(
            title: "Tạm dừng", kind: .expense, amount: 1_000,
            frequency: .monthly, startDate: day(2026, 9, 15),
            isActive: false
        )
        #expect(!RecurringUpcoming.isFinished(
            paused, asOf: day(2026, 11, 10), calendar: calendar
        ))
    }

    @Test func invalidScheduleReadsAsFinished() {
        let broken = RecurringUpcoming.Input(
            title: "Hỏng", kind: .expense, amount: 1_000,
            frequency: .monthly, interval: 0, startDate: day(2026, 9, 15)
        )
        #expect(RecurringUpcoming.isFinished(
            broken, asOf: day(2026, 11, 10), calendar: calendar
        ))
        #expect(RecurringUpcoming.nextOccurrence(
            of: broken, asOf: day(2026, 11, 10), calendar: calendar
        ) == nil)
    }

    @Test func nextOccurrencesMapCoversEveryLiveRule() {
        let inputs = mixedRules()
        let map = RecurringUpcoming.nextOccurrences(
            of: inputs, asOf: day(2026, 11, 10), calendar: calendar
        )
        // Every rule here still has occurrences — including the paused one.
        #expect(map.count == inputs.count)
        #expect(map[inputs[0].id] == sod(2026, 11, 10))
        #expect(map[inputs[2].id] == sod(2026, 11, 15))
    }

    // MARK: - Preview of the next dates

    @Test func previewClamps31stAcrossShortMonths() {
        var draft = RecurringDraft()
        draft.frequency = .monthly
        draft.startDate = day(2026, 1, 31)
        // 2026 is not a leap year: Jan 31, Feb 28, Mar 31 — re-clamped
        // from the anchor each time, never drifting to Feb + N days.
        #expect(draft.previewDates(count: 3, calendar: calendar) == [
            sod(2026, 1, 31),
            sod(2026, 2, 28),
            sod(2026, 3, 31),
        ])
    }

    @Test func previewStopsAtEndCount() {
        var draft = RecurringDraft()
        draft.frequency = .daily
        draft.startDate = day(2026, 1, 10)
        draft.endMode = .count
        draft.endCount = 2
        #expect(draft.previewDates(count: 3, calendar: calendar) == [
            sod(2026, 1, 10),
            sod(2026, 1, 11),
        ])
    }

    @Test func previewEmptyWhileScheduleInvalid() {
        var draft = RecurringDraft()
        draft.frequency = .daily
        draft.startDate = day(2026, 1, 10)
        draft.endMode = .date
        draft.endDate = day(2026, 1, 9)
        #expect(draft.previewDates(calendar: calendar).isEmpty)
    }

    // MARK: - "Tạo giao dịch ngay"

    @Test func makeTransactionMirrorsGeneratorMapping() throws {
        let context = try makeContext()
        let bank = Account(name: "Ngân hàng", kind: .bank, openingBalance: 1_000_000)
        let wallet = Account(name: "Ví", kind: .eWallet)
        let tools = LedgerCategory(name: "Công cụ", kind: .expense)
        let web = Business(name: "Làm web")
        for model in [bank, wallet] { context.insert(model) }
        context.insert(tools)
        context.insert(web)

        // With an explicit note the note wins, like the generator.
        let rule = RecurringRule(
            title: "Trả nợ thẻ", kind: .transfer, amount: 2_000_000,
            note: "Trả Visa", account: bank, toAccount: wallet,
            category: tools, business: web,
            frequency: .monthly, startDate: day(2026, 1, 5),
            lastGeneratedDate: day(2026, 10, 5)
        )
        let at = day(2026, 11, 22, 15)
        let transaction = RecurringEditView.makeTransaction(from: rule, at: at)
        #expect(transaction.kind == .transfer)
        #expect(transaction.amount == 2_000_000)
        #expect(transaction.date == at)
        #expect(transaction.note == "Trả Visa")
        #expect(transaction.account?.id == bank.id)
        #expect(transaction.toAccount?.id == wallet.id)
        #expect(transaction.category?.id == tools.id)
        #expect(transaction.business?.id == web.id)

        // An empty note falls back to the rule title.
        let untitled = RecurringRule(
            title: "Thuê mặt bằng", kind: .expense, amount: 7_000_000,
            account: bank, category: tools,
            frequency: .monthly, startDate: day(2026, 1, 5)
        )
        let second = RecurringEditView.makeTransaction(from: untitled, at: at)
        #expect(second.note == "Thuê mặt bằng")

        // The caller owns lastGeneratedDate — the helper must not touch it.
        #expect(rule.lastGeneratedDate == day(2026, 10, 5))
        #expect(untitled.lastGeneratedDate == nil)
    }
}
