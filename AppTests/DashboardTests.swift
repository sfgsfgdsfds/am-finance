import Testing
import Foundation
import SwiftData
import FinanceCore
@testable import AMFinance

@MainActor
struct DashboardTests {
    private let calendar = AppCalendar.vietnam

    private func makeContext() throws -> ModelContext {
        ModelContext(try AppModelContainer.make(inMemory: true))
    }

    private func day(
        _ year: Int, _ month: Int, _ day: Int, _ hour: Int = 12
    ) -> Date {
        calendar.date(from: DateComponents(
            year: year, month: month, day: day, hour: hour
        ))!
    }

    // MARK: - Fixture: "now" = 15/11/2026, Asia/Ho_Chi_Minh

    private let now: Date = {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = TimeZone(identifier: "Asia/Ho_Chi_Minh")!
        return cal.date(from: DateComponents(
            year: 2026, month: 11, day: 15, hour: 12
        ))!
    }()

    private let cSalary = UUID()
    private let cRent = UUID()
    private let cFood = UUID()
    private let cTransport = UUID()
    private let cShopping = UUID()
    private let cHome = UUID()
    private let cHealth = UUID()
    private let cVenue = UUID()
    private let bApartment = UUID()
    private let bWeb = UUID()

    private var categoryVisuals: [UUID: DashboardSnapshot.Visual] {
        [
            cSalary: .init(name: "Lương & thù lao", icon: "banknote", colorHex: "34C759"),
            cRent: .init(name: "Tiền thuê phòng", icon: "bed.double.fill", colorHex: "32ADE6"),
            cFood: .init(name: "Ăn uống", icon: "fork.knife", colorHex: "FF9500"),
            cTransport: .init(name: "Di chuyển", icon: "car.fill", colorHex: "0A84FF"),
            cShopping: .init(name: "Mua sắm", icon: "bag.fill", colorHex: "FF375F"),
            cHome: .init(name: "Nhà cửa", icon: "house.fill", colorHex: "30B0C7"),
            cHealth: .init(name: "Sức khoẻ", icon: "heart.fill", colorHex: "FF3B30"),
            cVenue: .init(name: "Thuê mặt bằng", icon: "storefront.fill", colorHex: "64D2FF"),
        ]
    }

    private var businessVisuals: [UUID: DashboardSnapshot.Visual] {
        [
            bApartment: .init(name: "Căn hộ dịch vụ", icon: "building.2.fill", colorHex: "30B0C7"),
            bWeb: .init(name: "Làm web", icon: "chevron.left.forwardslash.chevron.right", colorHex: "0A84FF"),
        ]
    }

    /// A hand-made month: November 2026 with personal + business activity,
    /// October and September entries for the series/comparison, one transfer
    /// that must never count, and a stale entry outside the window.
    private var fixtureEntries: [ReportEntry] {
        [
            // November — income: 21.000.000
            .init(date: day(2026, 11, 5), kind: .income, amount: 10_000_000,
                  categoryID: cSalary),
            .init(date: day(2026, 11, 8), kind: .income, amount: 8_000_000,
                  categoryID: cRent, businessID: bApartment),
            .init(date: day(2026, 11, 9), kind: .income, amount: 3_000_000,
                  categoryID: cSalary, businessID: bWeb),
            // November — expense: 9.300.000
            .init(date: day(2026, 11, 9), kind: .expense, amount: 2_500_000,
                  categoryID: cVenue, businessID: bApartment),
            .init(date: day(2026, 11, 3), kind: .expense, amount: 2_000_000,
                  categoryID: cFood),
            .init(date: day(2026, 11, 4), kind: .expense, amount: 1_500_000,
                  categoryID: cTransport),
            .init(date: day(2026, 11, 5), kind: .expense, amount: 1_200_000,
                  categoryID: cShopping),
            .init(date: day(2026, 11, 6), kind: .expense, amount: 1_000_000,
                  categoryID: cHome),
            .init(date: day(2026, 11, 7), kind: .expense, amount: 800_000,
                  categoryID: cHealth),
            .init(date: day(2026, 11, 8), kind: .expense, amount: 300_000),
            // November — a transfer never counts towards income/expense.
            .init(date: day(2026, 11, 10), kind: .transfer, amount: 9_000_000),
            // October — income 7.000.000, expense 3.000.000.
            .init(date: day(2026, 10, 10), kind: .income, amount: 7_000_000,
                  categoryID: cSalary),
            .init(date: day(2026, 10, 11), kind: .expense, amount: 3_000_000,
                  categoryID: cFood),
            // September — income 1.000.000, expense 4.000.000.
            .init(date: day(2026, 9, 9), kind: .income, amount: 1_000_000),
            .init(date: day(2026, 9, 10), kind: .expense, amount: 4_000_000,
                  categoryID: cFood),
            // Far older — outside the six-month window.
            .init(date: day(2025, 12, 20), kind: .income, amount: 999_000_000),
        ]
    }

    private func snapshot(
        entries: [ReportEntry]? = nil,
        recents: [DashboardSnapshot.RecentInput] = [],
        accounts: [DashboardSnapshot.AccountInput] = [],
        pendingReviewCount: Int = 0,
        hasAnyTransaction: Bool = true
    ) -> DashboardSnapshot {
        DashboardSnapshot.make(
            entries: entries ?? fixtureEntries,
            recents: recents,
            accounts: accounts,
            categories: categoryVisuals,
            businesses: businessVisuals,
            pendingReviewCount: pendingReviewCount,
            hasAnyTransaction: hasAnyTransaction,
            now: now,
            calendar: calendar
        )
    }

    // MARK: - Month totals

    @Test func monthTotalsIncomeExpenseNet() {
        let month = snapshot().month
        #expect(month.title == "Tháng 11/2026")
        #expect(month.income == 21_000_000)
        #expect(month.expense == 9_300_000)
        #expect(month.net == 11_700_000)
    }

    @Test func monthPersonalBusinessSplit() {
        let month = snapshot().month
        #expect(month.personalExpense == 6_800_000)
        #expect(month.businessIncome == 11_000_000)
        #expect(month.businessExpense == 2_500_000)
    }

    @Test func monthOverMonthPercents() {
        let month = snapshot().month
        // Income 21tr vs 7tr = +200%; expense 9,3tr vs 3tr = +210%.
        #expect(month.incomeChangePercent == 2.0)
        #expect(abs((month.expenseChangePercent ?? 0) - 2.1) < 0.0001)
    }

    @Test func monthOverMonthPercentNilWhenPreviousIsZero() {
        // Only November entries — October had nothing, so both percents hide.
        let currentOnly = fixtureEntries.filter {
            $0.date >= day(2026, 11, 1)
        }
        let month = snapshot(entries: currentOnly).month
        #expect(month.incomeChangePercent == nil)
        #expect(month.expenseChangePercent == nil)
        #expect(month.income == 21_000_000)
        #expect(month.expense == 9_300_000)
    }

    // MARK: - Six-month series

    @Test func sixMonthSeriesHasSixZeroFilledPoints() {
        let months = snapshot().months
        #expect(months.count == 6)
        #expect(months.map(\.monthStart) == [
            day(2026, 6, 1, 0), day(2026, 7, 1, 0), day(2026, 8, 1, 0),
            day(2026, 9, 1, 0), day(2026, 10, 1, 0), day(2026, 11, 1, 0),
        ])
        // June–August have no entries and stay zero-filled.
        #expect(months[0].income == 0 && months[0].expense == 0)
        #expect(months[1].income == 0 && months[1].expense == 0)
        #expect(months[2].income == 0 && months[2].expense == 0)
        #expect(months[3].income == 1_000_000 && months[3].expense == 4_000_000)
        #expect(months[4].income == 7_000_000 && months[4].expense == 3_000_000)
        #expect(months[5].income == 21_000_000 && months[5].expense == 9_300_000)
        // The December 2025 entry is outside the window entirely.
        #expect(months.allSatisfy { $0.income < 1_000_000_000 })
    }

    // MARK: - Top expense categories

    @Test func topCategoriesFoldsRestIntoOther() {
        let rows = snapshot().topExpenseCategories
        #expect(rows.count == 6)
        #expect(rows.map(\.name) == [
            "Thuê mặt bằng", "Ăn uống", "Di chuyển", "Mua sắm", "Nhà cửa", "Khác",
        ])
        #expect(rows.map(\.total) == [
            2_500_000, 2_000_000, 1_500_000, 1_200_000, 1_000_000, 1_100_000,
        ])
        let other = try? #require(rows.last)
        #expect(other?.isOther == true)
        #expect(other?.icon == "ellipsis.circle.fill")
        // 1,1tr of 9,3tr ≈ 11,8%.
        #expect(abs((other?.share ?? 0) - 1_100_000.0 / 9_300_000.0) < 0.0001)
        // Named rows carry their styling through for the badge.
        #expect(rows[0].icon == "storefront.fill")
        #expect(rows[0].colorHex == "64D2FF")
    }

    @Test func topCategoriesDoesNotFoldAtExactlyFive() {
        let fiveCategories = [
            ReportEntry(date: day(2026, 11, 3), kind: .expense, amount: 5,
                        categoryID: cFood),
            ReportEntry(date: day(2026, 11, 3), kind: .expense, amount: 4,
                        categoryID: cTransport),
            ReportEntry(date: day(2026, 11, 3), kind: .expense, amount: 3,
                        categoryID: cShopping),
            ReportEntry(date: day(2026, 11, 3), kind: .expense, amount: 2,
                        categoryID: cHome),
            ReportEntry(date: day(2026, 11, 3), kind: .expense, amount: 1),
        ]
        let rows = snapshot(entries: fiveCategories).topExpenseCategories
        #expect(rows.count == 5)
        #expect(rows.allSatisfy { !$0.isOther })
        // The uncategorized row gets its own label.
        #expect(rows.last?.name == "Chưa phân loại")
    }

    // MARK: - Business profit & loss

    @Test func businessResultsSortedByProfit() {
        let results = snapshot().businessResults
        #expect(results.count == 2)
        #expect(results[0].businessID == bApartment)
        #expect(results[0].name == "Căn hộ dịch vụ")
        #expect(results[0].revenue == 8_000_000)
        #expect(results[0].cost == 2_500_000)
        #expect(results[0].profit == 5_500_000)
        #expect(results[1].businessID == bWeb)
        #expect(results[1].profit == 3_000_000)
    }

    @Test func businessResultsEmptyWhenNoBusinessActivity() {
        let personalOnly = [
            ReportEntry(date: day(2026, 11, 3), kind: .expense, amount: 10_000,
                        categoryID: cFood),
        ]
        #expect(snapshot(entries: personalOnly).businessResults.isEmpty)
    }

    // MARK: - Transfers

    @Test func transfersNeverCounted() {
        let transfersOnly = [
            ReportEntry(date: day(2026, 11, 3), kind: .transfer, amount: 9_000_000),
            ReportEntry(date: day(2026, 10, 3), kind: .transfer, amount: 1_000_000),
        ]
        let snap = snapshot(entries: transfersOnly)
        #expect(snap.month.income == 0 && snap.month.expense == 0 && snap.month.net == 0)
        #expect(snap.topExpenseCategories.isEmpty)
        #expect(snap.businessResults.isEmpty)
        #expect(snap.months.allSatisfy { $0.income == 0 && $0.expense == 0 })
        // Still not the welcome card — the table has rows.
        #expect(!snap.isEmpty)
    }

    // MARK: - Net worth & chips

    @Test func netWorthSplitsAssetsAndLiabilities() {
        let accounts = [
            DashboardSnapshot.AccountInput(
                id: UUID(), name: "Ngân hàng", isLiability: false,
                balance: 20_000_000, sortOrder: 1),
            DashboardSnapshot.AccountInput(
                id: UUID(), name: "Tiền mặt", isLiability: false,
                balance: 5_000_000, sortOrder: 0),
            DashboardSnapshot.AccountInput(
                id: UUID(), name: "Thẻ Visa", isLiability: true,
                balance: -3_000_000, sortOrder: 2),
            DashboardSnapshot.AccountInput(
                id: UUID(), name: "Ví cũ", isLiability: false,
                balance: 99_000_000, isArchived: true, sortOrder: 3),
        ]
        let snap = snapshot(accounts: accounts)
        #expect(snap.netWorth.assets == 25_000_000)
        #expect(snap.netWorth.liabilities == -3_000_000)
        #expect(snap.netWorth.total == 22_000_000)
        // Chips skip archived accounts and follow sortOrder.
        #expect(snap.accountChips.map(\.name) == ["Tiền mặt", "Ngân hàng", "Thẻ Visa"])
    }

    // MARK: - Pending review & empty state

    @Test func pendingReviewCountPassesThrough() {
        #expect(snapshot(pendingReviewCount: 3).pendingReviewCount == 3)
    }

    @Test func emptyStateFlagFollowsHasAnyTransaction() {
        #expect(snapshot(hasAnyTransaction: false).isEmpty)
        #expect(!snapshot(hasAnyTransaction: true).isEmpty)
        // Fresh install: no entries either — the snapshot is still well formed.
        let fresh = snapshot(entries: [], hasAnyTransaction: false)
        #expect(fresh.isEmpty)
        #expect(fresh.month.income == 0)
        #expect(fresh.months.count == 6)
        #expect(fresh.topExpenseCategories.isEmpty)
    }

    // MARK: - Recent items

    @Test func recentItemsRenderHistoryRowInfo() {
        let expense = UUID()
        let transfer = UUID()
        let income = UUID()
        let recents: [DashboardSnapshot.RecentInput] = [
            .init(id: expense, kind: .expense, amount: 45_000,
                  date: day(2026, 11, 14, 18),
                  note: "Ăn tối", accountName: "Tiền mặt",
                  category: .init(name: "Ăn uống", icon: "fork.knife",
                                  colorHex: "FF9500")),
            .init(id: transfer, kind: .transfer, amount: 2_000_000,
                  date: day(2026, 11, 14, 9),
                  accountName: "Ngân hàng", toAccountName: "Tiền mặt"),
            .init(id: income, kind: .income, amount: 500_000,
                  date: day(2026, 11, 13), accountName: "Tiền mặt"),
        ]
        let items = snapshot(recents: recents).recentItems
        #expect(items.count == 3)

        #expect(items[0].title == "Ăn uống")
        #expect(items[0].subtitle == "Ăn tối · Tiền mặt · 14/11")
        #expect(items[0].icon == "fork.knife")
        #expect(items[0].colorHex == "FF9500")
        #expect(items[0].kind == .expense)

        #expect(items[1].title == "Chuyển khoản")
        #expect(items[1].subtitle == "Ngân hàng → Tiền mặt · 14/11")
        #expect(items[1].icon == "arrow.left.arrow.right")
        #expect(items[1].colorHex == "64748B")

        // Income without a category falls back to the kind name.
        #expect(items[2].title == "Thu")
        #expect(items[2].subtitle == "Tiền mặt · 13/11")
        #expect(items[2].icon == "arrow.down.left")
    }

    // MARK: - Formatting helpers

    @Test func percentAndShareText() {
        #expect(DashboardSnapshot.percentText(2.1) == "+210%")
        #expect(DashboardSnapshot.percentText(-0.083) == "-8%")
        #expect(DashboardSnapshot.percentText(0) == "0%")
        #expect(DashboardSnapshot.shareText(0.118) == "12%")
        #expect(DashboardSnapshot.shareText(0) == "0%")
    }

    // MARK: - End-to-end with real models

    /// Inserts real SwiftData rows, maps them to snapshot inputs the same way
    /// the view does, and checks the aggregated numbers — including the
    /// signed-balance convention (a card purchase makes the card more
    /// negative, feeding "Nợ").
    @Test func snapshotFromModelRows() throws {
        let context = try makeContext()
        let cash = Account(name: "Tiền mặt", kind: .cash,
                           openingBalance: 5_000_000, sortOrder: 0)
        let card = Account(name: "Thẻ Visa", kind: .creditCard, sortOrder: 1)
        context.insert(cash)
        context.insert(card)
        let food = LedgerCategory(name: "Ăn uống", kind: .expense,
                                  icon: "fork.knife", colorHex: "FF9500")
        context.insert(food)
        let shop = Business(name: "Cửa hàng", icon: "storefront.fill",
                            colorHex: "0A84FF")
        context.insert(shop)

        let monthStart = ReportSummary.monthInterval(
            containing: .now, calendar: calendar
        ).start
        context.insert(LedgerTransaction(
            kind: .income, amount: 10_000_000, date: monthStart,
            account: cash, business: shop
        ))
        context.insert(LedgerTransaction(
            kind: .expense, amount: 500_000, date: monthStart,
            account: card, category: food, business: shop
        ))
        context.insert(LedgerTransaction(
            kind: .transfer, amount: 2_000_000, date: monthStart,
            account: cash, toAccount: card
        ))
        try context.save()

        let transactions = try context.fetch(FetchDescriptor<LedgerTransaction>(
            predicate: #Predicate { $0.date >= monthStart },
            sortBy: [SortDescriptor(\.date, order: .reverse)]
        ))
        #expect(transactions.count == 3)

        let snap = DashboardSnapshot.make(
            entries: transactions.map {
                ReportEntry(date: $0.date, kind: $0.kind, amount: $0.amount,
                            categoryID: $0.category?.id, businessID: $0.business?.id)
            },
            accounts: [cash, card].map {
                .init(id: $0.id, name: $0.name, isLiability: $0.kind.isLiability,
                      icon: $0.icon, colorHex: $0.colorHex,
                      balance: $0.balance, isArchived: $0.isArchived,
                      sortOrder: $0.sortOrder)
            },
            categories: [food.id: .init(name: food.name, icon: food.icon,
                                        colorHex: food.colorHex)],
            businesses: [shop.id: .init(name: shop.name, icon: shop.icon,
                                        colorHex: shop.colorHex)],
            pendingReviewCount: transactions.filter(\.needsReview).count,
            hasAnyTransaction: !transactions.isEmpty,
            now: .now,
            calendar: calendar
        )

        #expect(!snap.isEmpty)
        #expect(snap.month.income == 10_000_000)
        #expect(snap.month.expense == 500_000)
        #expect(snap.month.businessIncome == 10_000_000)
        // Cash: 5tr opening + 10tr income - 2tr transfer out = 13tr.
        // Card: -500k from the purchase + 2tr as transfer destination =
        // +1,5tr — a liability-kind account can still sit positive.
        #expect(cash.balance == 13_000_000)
        #expect(card.balance == 1_500_000)
        #expect(snap.netWorth.assets == 13_000_000)
        #expect(snap.netWorth.liabilities == 1_500_000)
        #expect(snap.netWorth.total == 14_500_000)
        #expect(snap.topExpenseCategories.map(\.name) == ["Ăn uống"])
        #expect(snap.businessResults.map(\.profit) == [9_500_000])
    }
}
