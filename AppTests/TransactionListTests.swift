import Testing
import SwiftData
import Foundation
import FinanceCore
@testable import AMFinance

@MainActor
struct TransactionListTests {
    private let calendar = AppCalendar.vietnam

    private func makeContext() throws -> ModelContext {
        ModelContext(try AppModelContainer.make(inMemory: true))
    }

    private func date(
        _ year: Int, _ month: Int, _ day: Int,
        _ hour: Int = 12, _ minute: Int = 0
    ) -> Date {
        calendar.date(from: DateComponents(
            year: year, month: month, day: day, hour: hour, minute: minute
        ))!
    }

    private func row(
        kind: TransactionKind = .expense,
        amount: Int64 = 100_000,
        date: Date,
        note: String = "",
        needsReview: Bool = false,
        accountID: UUID? = nil,
        accountName: String? = nil,
        toAccountID: UUID? = nil,
        toAccountName: String? = nil,
        categoryID: UUID? = nil,
        categoryName: String? = nil,
        categoryIcon: String = "",
        categoryColorHex: String = "",
        businessID: UUID? = nil,
        businessName: String? = nil
    ) -> TransactionListRow {
        TransactionListRow(
            kind: kind, amount: amount, date: date, note: note,
            needsReview: needsReview,
            accountID: accountID, accountName: accountName,
            toAccountID: toAccountID, toAccountName: toAccountName,
            categoryID: categoryID, categoryName: categoryName,
            categoryIcon: categoryIcon, categoryColorHex: categoryColorHex,
            businessID: businessID, businessName: businessName
        )
    }

    // MARK: - Grouping & ordering

    @Test func sectionsGroupByDayNewestFirst() {
        let rows = [
            row(amount: 1, date: date(2026, 11, 20, 9)),
            row(amount: 2, date: date(2026, 11, 22, 18)),
            row(amount: 3, date: date(2026, 11, 20, 20)),
            row(amount: 4, date: date(2026, 11, 22, 8)),
        ]
        let sections = TransactionListGrouping.sections(for: rows, calendar: calendar)

        #expect(sections.map(\.day) == [
            calendar.startOfDay(for: date(2026, 11, 22)),
            calendar.startOfDay(for: date(2026, 11, 20)),
        ])
        // Within a day the newest transaction comes first.
        #expect(sections[0].rows.map(\.amount) == [2, 4])
        #expect(sections[1].rows.map(\.amount) == [3, 1])
    }

    @Test func vietnamDayBoundarySplitsAtMidnight() {
        let rows = [
            row(date: date(2026, 11, 22, 23, 59)),
            row(date: date(2026, 11, 23, 0, 1)),
        ]
        let sections = TransactionListGrouping.sections(for: rows, calendar: calendar)

        #expect(sections.count == 2)
        #expect(sections[0].day == calendar.startOfDay(for: date(2026, 11, 23)))
        #expect(sections[1].day == calendar.startOfDay(for: date(2026, 11, 22)))
    }

    @Test func groupingUsesVietnamCalendarNotUTC() {
        var utc = Calendar(identifier: .gregorian)
        utc.timeZone = TimeZone(identifier: "UTC")!
        // 2026-11-22 17:30 UTC is 2026-11-23 00:30 in Asia/Ho_Chi_Minh —
        // the row must land on the 23rd's section, not the 22nd's.
        let instant = utc.date(from: DateComponents(
            year: 2026, month: 11, day: 22, hour: 17, minute: 30
        ))!
        let sections = TransactionListGrouping.sections(
            for: [row(date: instant)], calendar: calendar)
        #expect(sections.map(\.day) == [
            calendar.startOfDay(for: date(2026, 11, 23))
        ])
    }

    // MARK: - Totals

    @Test func totalsIgnoreTransfers() {
        let rows = [
            row(kind: .income, amount: 1_000_000, date: date(2026, 11, 20)),
            row(kind: .expense, amount: 400_000, date: date(2026, 11, 20)),
            row(kind: .transfer, amount: 9_000_000, date: date(2026, 11, 20)),
            row(kind: .expense, amount: 100_000, date: date(2026, 11, 21)),
        ]
        #expect(TransactionListGrouping.incomeTotal(of: rows) == 1_000_000)
        #expect(TransactionListGrouping.expenseTotal(of: rows) == 500_000)
        #expect(TransactionListGrouping.netTotal(of: rows) == 500_000)

        let sections = TransactionListGrouping.sections(for: rows, calendar: calendar)
        #expect(sections[0].incomeTotal == 0)
        #expect(sections[0].expenseTotal == 100_000)
        #expect(sections[1].incomeTotal == 1_000_000)
        #expect(sections[1].expenseTotal == 400_000)
    }

    @Test func monthIntervalCoversWholeMonth() {
        let (start, end) = TransactionListGrouping.monthInterval(
            containing: date(2026, 11, 22), calendar: calendar)
        #expect(start == date(2026, 11, 1, 0, 0))
        #expect(end == date(2026, 12, 1, 0, 0))
        #expect(TransactionListGrouping.shiftingMonth(
            of: start, by: 1, calendar: calendar) == end)
        #expect(TransactionListGrouping.shiftingMonth(
            of: start, by: -1, calendar: calendar) == date(2026, 10, 1, 0, 0))
    }

    // MARK: - Filter

    @Test func inactiveFilterMatchesEverything() {
        let filter = TransactionListFilter()
        #expect(!filter.isActive)
        let rows = [
            row(kind: .expense, date: date(2026, 11, 20)),
            row(kind: .income, date: date(2026, 11, 21)),
            row(kind: .transfer, date: date(2026, 11, 22)),
        ]
        #expect(rows.filter(filter.matches).count == 3)
    }

    @Test func filterByKind() {
        var filter = TransactionListFilter(kind: .expense)
        #expect(filter.isActive)
        let rows = [
            row(kind: .expense, date: date(2026, 11, 20)),
            row(kind: .income, date: date(2026, 11, 21)),
            row(kind: .transfer, date: date(2026, 11, 22)),
        ]
        #expect(rows.filter(filter.matches).map(\.kind) == [.expense])

        filter.kind = .transfer
        #expect(rows.filter(filter.matches).map(\.kind) == [.transfer])
    }

    @Test func filterByAccountMatchesSourceAndDestination() {
        let a = UUID(), b = UUID(), c = UUID()
        let rows = [
            row(kind: .expense, date: date(2026, 11, 20), accountID: a),
            row(kind: .transfer, date: date(2026, 11, 21),
                accountID: b, toAccountID: a),
            row(kind: .income, date: date(2026, 11, 22), accountID: c),
        ]
        // Account A appears as source of the expense and destination of the
        // transfer — both stay.
        let filter = TransactionListFilter(accountID: a)
        #expect(rows.filter(filter.matches).count == 2)
    }

    @Test func filterByCategory() {
        let food = UUID(), fuel = UUID()
        let rows = [
            row(date: date(2026, 11, 20), categoryID: food),
            row(date: date(2026, 11, 21), categoryID: fuel),
            row(date: date(2026, 11, 22), categoryID: nil),
        ]
        let filter = TransactionListFilter(categoryID: food)
        let kept = rows.filter(filter.matches)
        #expect(kept.map(\.categoryID) == [food])
    }

    @Test func filterByBusinessAndPersonal() {
        let shop = UUID()
        let rows = [
            row(date: date(2026, 11, 20), businessID: nil),
            row(date: date(2026, 11, 21), businessID: shop),
            row(date: date(2026, 11, 22), businessID: UUID()),
        ]

        // "Cá nhân" keeps only transactions with no business attached.
        var filter = TransactionListFilter(business: .personal)
        #expect(rows.filter(filter.matches).count == 1)
        #expect(rows.filter(filter.matches).first?.businessID == nil)

        filter.business = .business(shop)
        #expect(rows.filter(filter.matches).map(\.businessID) == [shop])
    }

    @Test func filterNeedsReviewOnly() {
        let rows = [
            row(date: date(2026, 11, 20), needsReview: true),
            row(date: date(2026, 11, 21), needsReview: false),
        ]
        let filter = TransactionListFilter(onlyNeedsReview: true)
        #expect(rows.filter(filter.matches).map(\.needsReview) == [true])
    }

    @Test func filtersCombineWithAnd() {
        let account = UUID(), category = UUID(), business = UUID()
        let wanted = row(
            kind: .expense, date: date(2026, 11, 20),
            accountID: account, categoryID: category, businessID: business)
        let rows = [
            wanted,
            // Wrong kind.
            row(kind: .income, date: date(2026, 11, 21),
                accountID: account, categoryID: category, businessID: business),
            // Wrong account.
            row(kind: .expense, date: date(2026, 11, 22),
                accountID: UUID(), categoryID: category, businessID: business),
            // Wrong business.
            row(kind: .expense, date: date(2026, 11, 23),
                accountID: account, categoryID: category, businessID: nil),
        ]
        let filter = TransactionListFilter(
            kind: .expense, accountID: account,
            categoryID: category, business: .business(business))
        #expect(rows.filter(filter.matches) == [wanted])
    }

    // MARK: - Search

    @Test func searchNormalizesDiacriticsAndCase() {
        #expect(TransactionListSearch.normalize("Ăn Nhậu") == "an nhau")
        #expect(TransactionListSearch.normalize("Đi Chơi") == "di choi")
        #expect(TransactionListSearch.normalize("  ĂN   TRƯA  ") == "an trua")
        #expect(TransactionListSearch.normalize("") == "")
    }

    @Test func searchMatchesNoteCategoryAccountAndBusiness() {
        let target = row(
            date: date(2026, 11, 22),
            note: "Ăn nhậu cuối tuần",
            accountName: "Tiền Mặt",
            categoryName: "Đi chơi",
            businessName: "Căn hộ dịch vụ"
        )
        #expect(TransactionListSearch.matches(target, query: "an nhau"))
        #expect(TransactionListSearch.matches(target, query: "tien mat"))
        #expect(TransactionListSearch.matches(target, query: "di choi"))
        #expect(TransactionListSearch.matches(target, query: "CAN HO"))
        #expect(!TransactionListSearch.matches(target, query: "xang"))
    }

    @Test func searchTransferMatchesDestinationAccount() {
        let transfer = row(
            kind: .transfer, date: date(2026, 11, 22),
            accountName: "Tiền mặt", toAccountName: "Ngân hàng")
        #expect(TransactionListSearch.matches(transfer, query: "ngan hang"))
        #expect(TransactionListSearch.matches(transfer, query: "tien mat"))
    }

    @Test func searchByAmountDigits() {
        let target = row(amount: 1_250_000, date: date(2026, 11, 22))
        #expect(TransactionListSearch.matches(target, query: "125"))
        #expect(TransactionListSearch.matches(target, query: "1250000"))
        // Grouped digits the way VND renders them.
        #expect(TransactionListSearch.matches(target, query: "1.250.000"))
        #expect(!TransactionListSearch.matches(target, query: "999"))
        // Not a pure digit query — falls back to text fields and misses.
        #expect(!TransactionListSearch.matches(target, query: "125k"))
    }

    // MARK: - Row presentation

    @Test func rowTitleAndBadgeByKind() {
        let categorized = row(
            date: date(2026, 11, 22),
            categoryName: "Ăn uống", categoryIcon: "fork.knife",
            categoryColorHex: "FF9500")
        #expect(categorized.title == "Ăn uống")
        #expect(categorized.badgeSymbol == "fork.knife")

        let transfer = row(kind: .transfer, date: date(2026, 11, 22))
        #expect(transfer.title == "Chuyển khoản")
        #expect(transfer.badgeSymbol == "arrow.left.arrow.right")

        let loose = row(date: date(2026, 11, 22))
        #expect(loose.title == "Chưa phân loại")
        #expect(loose.badgeSymbol == "questionmark")
    }

    @Test func rowSubtitleComposesNoteAccountAndBusiness() {
        let plain = row(date: date(2026, 11, 22), note: "Phở",
                        accountName: "Tiền mặt", businessName: "Làm web")
        #expect(plain.subtitle == "Phở · Tiền mặt · Làm web")

        let transfer = row(kind: .transfer, date: date(2026, 11, 22),
                           note: "Trả thẻ",
                           accountName: "Tiền mặt", toAccountName: "Thẻ tín dụng")
        #expect(transfer.subtitle == "Trả thẻ · Tiền mặt → Thẻ tín dụng")
    }

    // MARK: - Duplicate

    @Test func duplicateCreatesNewRowDatedNow() throws {
        let context = try makeContext()
        let cash = Account(name: "Tiền mặt", kind: .cash)
        let category = LedgerCategory(name: "Ăn uống", kind: .expense)
        context.insert(cash)
        context.insert(category)
        let original = LedgerTransaction(
            kind: .expense, amount: 150_000,
            date: date(2026, 11, 10), note: "Phở",
            account: cash, category: category, needsReview: true
        )
        original.externalSource = "bank"
        original.externalID = "txn-1"
        context.insert(original)
        try context.save()

        let now = Date.now
        let copy = TransactionListDuplicate.insert(
            of: original, into: context, now: now)
        try context.save()

        let all = try context.fetch(FetchDescriptor<LedgerTransaction>())
        #expect(all.count == 2)
        #expect(copy.id != original.id)
        #expect(copy.date == now)
        #expect(copy.amount == 150_000)
        #expect(copy.kind == .expense)
        #expect(copy.note == "Phở")
        #expect(copy.account?.id == cash.id)
        #expect(copy.category?.id == category.id)
        #expect(copy.needsReview)
        // The copy is a new manual entry — no bank-link fields.
        #expect(copy.externalID == nil)
        #expect(copy.externalSource == nil)
    }

    // MARK: - Month-range fetch (mirrors the view's @Query predicate)

    @Test func monthRangeFetchOnlyLoadsVisibleMonth() throws {
        let context = try makeContext()
        let cash = Account(name: "Tiền mặt", kind: .cash)
        context.insert(cash)
        context.insert(LedgerTransaction(
            kind: .expense, amount: 1,
            date: date(2026, 10, 31, 23, 59), account: cash))
        context.insert(LedgerTransaction(
            kind: .expense, amount: 2,
            date: date(2026, 11, 1, 0, 0), account: cash))
        context.insert(LedgerTransaction(
            kind: .expense, amount: 3,
            date: date(2026, 11, 30, 23, 59), account: cash))
        context.insert(LedgerTransaction(
            kind: .expense, amount: 4,
            date: date(2026, 12, 1, 0, 0), account: cash))
        try context.save()

        let (start, end) = TransactionListGrouping.monthInterval(
            containing: date(2026, 11, 15), calendar: calendar)
        let descriptor = FetchDescriptor<LedgerTransaction>(
            predicate: #Predicate<LedgerTransaction> {
                $0.date >= start && $0.date < end
            },
            sortBy: [SortDescriptor(\LedgerTransaction.date, order: .reverse)]
        )
        let fetched = try context.fetch(descriptor)
        #expect(fetched.map(\.amount) == [3, 2])
    }
}
