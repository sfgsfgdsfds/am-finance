import Testing
import Foundation
import SwiftData
import FinanceCore
@testable import AMFinance

@MainActor
struct BudgetsTests {
    private let calendar = AppCalendar.vietnam

    private func makeContext() throws -> ModelContext {
        ModelContext(try AppModelContainer.make(inMemory: true))
    }

    private func day(
        _ year: Int, _ month: Int, _ day: Int, _ hour: Int = 12
    ) -> Date {
        calendar.date(from: DateComponents(
            year: year, month: month, day: day, hour: hour))!
    }

    // MARK: - Fixture: "now" = 15/11/2026, Asia/Ho_Chi_Minh

    private let now: Date = {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = TimeZone(identifier: "Asia/Ho_Chi_Minh")!
        return cal.date(from: DateComponents(
            year: 2026, month: 11, day: 15, hour: 12))!
    }()

    private let cFood = UUID()
    private let cTransport = UUID()
    private let cHome = UUID()
    private let cShopping = UUID()

    private var visuals: [UUID: BudgetsSnapshot.Visual] {
        [
            cFood: .init(name: "Ăn uống", icon: "fork.knife", colorHex: "FF9500"),
            cTransport: .init(name: "Di chuyển", icon: "car.fill", colorHex: "0A84FF"),
            cHome: .init(name: "Nhà cửa", icon: "house.fill", colorHex: "30B0C7"),
            cShopping: .init(name: "Mua sắm", icon: "bag.fill", colorHex: "FF375F"),
        ]
    }

    private func spend(
        _ amount: Int64, _ year: Int, _ month: Int, _ day: Int,
        category: UUID? = nil, business: Bool = false
    ) -> BudgetsSnapshot.SpendInput {
        .init(
            categoryID: category, date: self.day(year, month, day),
            amount: amount, isBusiness: business)
    }

    private func limit(
        _ monthly: Int64, category: UUID? = nil, active: Bool = true
    ) -> BudgetsSnapshot.LimitInput {
        .init(
            id: UUID(), categoryID: category,
            monthlyLimit: monthly, isActive: active)
    }

    private func snapshot(
        limits: [BudgetsSnapshot.LimitInput],
        spends: [BudgetsSnapshot.SpendInput],
        month: Date? = nil
    ) -> BudgetsSnapshot {
        BudgetsSnapshot.make(
            limits: limits, spends: spends, categories: visuals,
            month: month ?? now, now: now, calendar: calendar)
    }

    private func row(
        _ snap: BudgetsSnapshot, for category: UUID
    ) -> BudgetsSnapshot.Row? {
        snap.categories.first { $0.categoryID == category }
    }

    // MARK: - Counting rules

    @Test func overallCountsOnlyPersonalExpenses() throws {
        let snap = snapshot(
            limits: [limit(10_000_000), limit(8_000_000, category: cFood)],
            spends: [
                spend(4_000_000, 2026, 11, 3, category: cFood),
                spend(3_000_000, 2026, 11, 4, category: cFood, business: true),
                spend(2_000_000, 2026, 11, 5, category: cTransport),
            ])
        // 4tr food + 2tr transport — the 3tr business expense is ignored.
        #expect(snap.overall?.progress.spent == 6_000_000)
        // A category budget counts every expense of its category,
        // business ones included.
        let food = try #require(row(snap, for: cFood))
        #expect(food.progress.spent == 7_000_000)
        #expect(snap.monthTitle == "Tháng 11/2026")
        #expect(snap.isCurrentMonth)
    }

    @Test func futureDatedSpendsThisMonthDoNotCountYet() {
        let snap = snapshot(
            limits: [limit(8_000_000, category: cFood)],
            spends: [
                spend(2_000_000, 2026, 11, 3, category: cFood),
                // The 25th is after "now" (the 15th) — not counted yet.
                spend(9_000_000, 2026, 11, 25, category: cFood),
            ])
        #expect(row(snap, for: cFood)?.progress.spent == 2_000_000)
        // The month's real total follows the same month-to-date window.
        #expect(snap.totalSpent == 2_000_000)
    }

    // MARK: - Status thresholds

    @Test func statusThresholds() {
        let snap = snapshot(
            limits: [
                limit(1_000_000, category: cFood),        // 79%
                limit(1_000_000, category: cTransport), // exactly 80%
                limit(1_000_000, category: cHome),      // exactly 100%
                limit(1_000_000, category: cShopping),  // just over
            ],
            spends: [
                spend(790_000, 2026, 11, 3, category: cFood),
                spend(800_000, 2026, 11, 3, category: cTransport),
                spend(1_000_000, 2026, 11, 3, category: cHome),
                spend(1_000_001, 2026, 11, 3, category: cShopping),
            ])
        #expect(row(snap, for: cFood)?.progress.status == .ok)
        #expect(row(snap, for: cTransport)?.progress.status == .warning)
        // Exactly at the limit still warns — "vượt" needs spent > limit.
        #expect(row(snap, for: cHome)?.progress.status == .warning)
        #expect(row(snap, for: cShopping)?.progress.status == .exceeded)
        #expect(snap.okCount == 1)
        #expect(snap.warningCount == 2)
        #expect(snap.exceededCount == 1)
        #expect(snap.totalLimit == 4_000_000)
    }

    // MARK: - Ordering

    @Test func categoryRowsSortExceededFirst() {
        let snap = snapshot(
            limits: [
                limit(1_000_000, category: cFood),       // 50% ok
                limit(1_000_000, category: cTransport), // 90% warning
                limit(1_000_000, category: cHome),      // 120% exceeded
                limit(1_000_000, category: cShopping),  // 200% exceeded
            ],
            spends: [
                spend(500_000, 2026, 11, 3, category: cFood),
                spend(900_000, 2026, 11, 3, category: cTransport),
                spend(1_200_000, 2026, 11, 3, category: cHome),
                spend(2_000_000, 2026, 11, 3, category: cShopping),
            ])
        // Exceeded first by fraction desc, then warning, then ok.
        #expect(snap.categories.map(\.categoryID)
            == [cShopping, cHome, cTransport, cFood])
    }

    @Test func overallRowIsSeparateFromCategoryOrdering() {
        // An exceeded overall budget does not join the category ordering —
        // it is exposed via `overall` so the view pins it on top.
        let snap = snapshot(
            limits: [limit(100_000), limit(10_000_000, category: cFood)],
            spends: [spend(2_000_000, 2026, 11, 3, category: cFood)])
        #expect(snap.overall?.progress.status == .exceeded)
        #expect(snap.categories.map(\.categoryID) == [cFood])
    }

    // MARK: - Inactive & invalid limits

    @Test func inactiveAndNonPositiveLimitsAreExcluded() {
        let snap = snapshot(
            limits: [
                limit(5_000_000, category: cFood, active: false),
                limit(0, category: cTransport),
                limit(8_000_000, category: cHome),
            ],
            spends: [spend(1_000_000, 2026, 11, 3, category: cHome)])
        #expect(snap.overall == nil)
        #expect(snap.categories.map(\.categoryID) == [cHome])
        #expect(snap.totalLimit == 8_000_000)
    }

    // MARK: - Past month

    @Test func pastMonthUsesWholeMonth() {
        // "now" is 15/11 — October's snapshot evaluates the whole month,
        // including its last day, and ignores other months.
        let snap = snapshot(
            limits: [limit(10_000_000, category: cFood)],
            spends: [
                spend(3_000_000, 2026, 10, 28, category: cFood),
                spend(2_000_000, 2026, 10, 31, category: cFood),
                spend(9_000_000, 2026, 11, 2, category: cFood),
            ],
            month: day(2026, 10, 10))
        #expect(!snap.isCurrentMonth)
        let food = row(snap, for: cFood)
        #expect(food?.progress.spent == 5_000_000)
        #expect(food?.progress.daysLeft == 0)
        #expect(snap.totalSpent == 5_000_000)
    }

    // MARK: - Suggestion

    @Test func suggestionAveragesPrecedingMonths() {
        // August had nothing, September 3tr, October 6tr →
        // (0 + 3tr + 6tr) / 3 = 3tr for a November budget.
        let suggestion = BudgetsSuggestion.monthlyAverage(
            spends: [
                spend(3_000_000, 2026, 9, 10, category: cFood),
                spend(6_000_000, 2026, 10, 10, category: cFood),
            ],
            scope: .category(cFood),
            forMonth: day(2026, 11, 5),
            calendar: calendar)
        #expect(suggestion == 3_000_000)
    }

    @Test func suggestionRoundsToNearest10000() {
        // 4.007.000 in one of three months → 1.335.666,67 → 1.340.000.
        let suggestion = BudgetsSuggestion.monthlyAverage(
            spends: [spend(4_007_000, 2026, 10, 3, category: cFood)],
            scope: .category(cFood),
            forMonth: day(2026, 11, 5),
            calendar: calendar)
        #expect(suggestion == 1_340_000)
    }

    @Test func suggestionScopeMatchesBudgetRule() {
        // Personal scope ignores business spends; a category scope keeps them.
        let spends = [
            spend(3_000_000, 2026, 9, 5, category: cFood),
            spend(6_000_000, 2026, 10, 5, category: cFood, business: true),
        ]
        let month = day(2026, 11, 5)
        #expect(BudgetsSuggestion.monthlyAverage(
            spends: spends, scope: .personal,
            forMonth: month, calendar: calendar) == 1_000_000)
        #expect(BudgetsSuggestion.monthlyAverage(
            spends: spends, scope: .category(cFood),
            forMonth: month, calendar: calendar) == 3_000_000)
    }

    @Test func suggestionNilWithoutDataOrRoundedToZero() {
        #expect(BudgetsSuggestion.monthlyAverage(
            spends: [], scope: .personal,
            forMonth: day(2026, 11, 5), calendar: calendar) == nil)
        // 4.000 total → 1.333 average → rounds to 0 → nothing to suggest.
        #expect(BudgetsSuggestion.monthlyAverage(
            spends: [spend(4_000, 2026, 10, 3, category: cFood)],
            scope: .category(cFood),
            forMonth: day(2026, 11, 5), calendar: calendar) == nil)
    }

    // MARK: - Draft

    @Test func draftRequiresPositiveAmount() {
        #expect(!BudgetsDraft().isValid)
        #expect(!BudgetsDraft(amount: 0).isValid)
        #expect(BudgetsDraft(amount: 500_000).isValid)
    }

    @Test func draftMapsToAndFromModel() {
        let food = LedgerCategory(name: "Ăn uống", kind: .expense)
        let budget = Budget(
            monthlyLimit: 5_000_000, isActive: true,
            note: "ghi chú", category: food)
        let draft = BudgetsDraft(budget: budget)
        #expect(draft == BudgetsDraft(
            amount: 5_000_000, isActive: true, note: "ghi chú"))

        var edited = draft
        edited.amount = 8_000_000
        edited.isActive = false
        edited.note = "  ghi chú mới  "
        edited.apply(to: budget)
        #expect(budget.monthlyLimit == 8_000_000)
        #expect(!budget.isActive)
        #expect(budget.note == "ghi chú mới")
        // The watched category is never rewritten by apply.
        #expect(budget.category?.id == food.id)

        let created = draft.makeBudget(category: food)
        #expect(created.monthlyLimit == 5_000_000)
        #expect(created.category?.id == food.id)
        #expect(created.isActive)
    }

    // MARK: - Target availability

    @Test func availableTargetsSkipTakenAndArchived() {
        let food = LedgerCategory(name: "Ăn uống", kind: .expense)
        let transport = LedgerCategory(name: "Di chuyển", kind: .expense)
        let salary = LedgerCategory(name: "Lương", kind: .income)
        let old = LedgerCategory(name: "Cũ", kind: .expense, isArchived: true)
        let targets = BudgetsTarget.available(
            categories: [food, transport, salary, old],
            budgetedCategoryIDs: [nil, food.id])
        // Overall taken (nil in the set) and food taken; salary is income
        // and "Cũ" is archived — only transport remains.
        #expect(targets == [.category(transport.id)])
    }

    @Test func availableTargetsOfferOverallFirst() {
        let food = LedgerCategory(name: "Ăn uống", kind: .expense)
        #expect(BudgetsTarget.available(
            categories: [food], budgetedCategoryIDs: [])
            == [.overall, .category(food.id)])
        // An empty set of budgets still offers the overall slot.
        #expect(BudgetsTarget.available(
            categories: [], budgetedCategoryIDs: []) == [.overall])
    }

    // MARK: - End-to-end with real models

    /// Inserts real SwiftData rows, fetches with the same date-range +
    /// kind predicate the view uses, maps to snapshot inputs and checks
    /// the counting rules on the result.
    @Test func snapshotFromModelRows() throws {
        let context = try makeContext()
        let cash = Account(name: "Tiền mặt", kind: .cash)
        let food = LedgerCategory(
            name: "Ăn uống", kind: .expense,
            icon: "fork.knife", colorHex: "FF9500")
        let shop = Business(name: "Cửa hàng")
        context.insert(cash)
        context.insert(food)
        context.insert(shop)
        let overallBudget = Budget(monthlyLimit: 10_000_000)
        let foodBudget = Budget(monthlyLimit: 8_000_000, category: food)
        context.insert(overallBudget)
        context.insert(foodBudget)

        let interval = ReportSummary.monthInterval(
            containing: .now, calendar: calendar)
        context.insert(LedgerTransaction(
            kind: .expense, amount: 3_000_000, date: interval.start,
            account: cash, category: food))
        context.insert(LedgerTransaction(
            kind: .expense, amount: 2_000_000, date: interval.start,
            account: cash, category: food, business: shop))
        // Income and transfers never count as spends.
        context.insert(LedgerTransaction(
            kind: .income, amount: 9_000_000, date: interval.start,
            account: cash))
        context.insert(LedgerTransaction(
            kind: .transfer, amount: 1_000_000, date: interval.start,
            account: cash, toAccount: cash))
        try context.save()

        let start = interval.start
        let end = interval.end
        let expense = TransactionKind.expense.rawValue
        let fetched = try context.fetch(FetchDescriptor<LedgerTransaction>(
            predicate: #Predicate {
                $0.date >= start && $0.date < end && $0.kindRaw == expense
            }))
        #expect(fetched.count == 2)

        let snap = BudgetsSnapshot.make(
            limits: [overallBudget, foodBudget].map {
                .init(
                    id: $0.id, categoryID: $0.category?.id,
                    monthlyLimit: $0.monthlyLimit, isActive: $0.isActive,
                    note: $0.note)
            },
            spends: fetched.map {
                .init(
                    categoryID: $0.category?.id, date: $0.date,
                    amount: $0.amount, isBusiness: $0.business != nil)
            },
            categories: [food.id: .init(
                name: food.name, icon: food.icon, colorHex: food.colorHex)],
            month: start, now: .now, calendar: calendar)

        // Overall: the 2tr business expense is ignored → 3tr.
        #expect(snap.overall?.progress.spent == 3_000_000)
        #expect(snap.overall?.name == "Ngân sách chi tiêu cá nhân")
        // Food: both expenses count → 5tr, with the model's styling.
        let foodRow = try #require(snap.categories.first)
        #expect(foodRow.progress.spent == 5_000_000)
        #expect(foodRow.name == "Ăn uống")
        #expect(foodRow.icon == "fork.knife")
        #expect(snap.totalSpent == 5_000_000)
        #expect(snap.totalLimit == 18_000_000)
    }
}
