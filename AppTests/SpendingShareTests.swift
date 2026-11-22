import Testing
import SwiftData
import Foundation
import FinanceCore
@testable import AMFinance

@MainActor
struct SpendingShareTests {
    private let calendar = AppCalendar.vietnam

    private func makeContext() throws -> ModelContext {
        ModelContext(try AppModelContainer.make(inMemory: true))
    }

    private func date(
        _ year: Int, _ month: Int, _ day: Int,
        _ hour: Int = 12, _ minute: Int = 0
    ) -> Date {
        calendar.date(from: DateComponents(
            year: year, month: month, day: day,
            hour: hour, minute: minute
        ))!
    }

    private var november2026: ReportDateInterval {
        ReportDateInterval(
            start: date(2026, 11, 1, 0, 0), end: date(2026, 12, 1, 0, 0))
    }

    private let catFood = UUID()
    private let catFuel = UUID()
    private let catHome = UUID()
    private let bizA = UUID()
    private let bizB = UUID()

    private var lookupCategories: [UUID: SpendingShareEntityInfo] {
        [
            catFood: SpendingShareEntityInfo(
                name: "Ăn uống", icon: "fork.knife", colorHex: "FF9500"),
            catFuel: SpendingShareEntityInfo(
                name: "Di chuyển", icon: "car.fill", colorHex: "0A84FF"),
            catHome: SpendingShareEntityInfo(
                name: "Nhà cửa", icon: "house.fill", colorHex: "30B0C7"),
        ]
    }

    private var lookupBusinesses: [UUID: SpendingShareEntityInfo] {
        [
            bizA: SpendingShareEntityInfo(
                name: "Làm web",
                icon: "chevron.left.forwardslash.chevron.right",
                colorHex: "0A84FF"),
            bizB: SpendingShareEntityInfo(
                name: "Căn hộ dịch vụ", icon: "building.2.fill",
                colorHex: "30B0C7"),
        ]
    }

    private func compute(
        entries: [ReportEntry],
        kind: TransactionKind = .expense,
        mode: SpendingShareMode,
        scope: ReportScope = .all,
        interval: ReportDateInterval? = nil,
        limit: Int = ShareDonutMath.sliceLimit
    ) -> SpendingShareResult {
        SpendingShareBuilder.compute(.init(
            entries: entries,
            interval: interval ?? november2026,
            kind: kind,
            mode: mode,
            scope: scope,
            categories: lookupCategories,
            businesses: lookupBusinesses,
            limit: limit
        ))
    }

    // MARK: - By segment ("Mảng")

    @Test func segmentSharesForHandmadeMonth() {
        let entries = [
            // Personal: 3M + 2M = 5M.
            ReportEntry(date: date(2026, 11, 5), kind: .expense,
                        amount: 3_000_000, categoryID: catFood),
            ReportEntry(date: date(2026, 11, 6), kind: .expense,
                        amount: 2_000_000, categoryID: catFuel),
            // Business A: 3M. Business B: 2M.
            ReportEntry(date: date(2026, 11, 7), kind: .expense,
                        amount: 3_000_000, categoryID: catHome,
                        businessID: bizA),
            ReportEntry(date: date(2026, 11, 8), kind: .expense,
                        amount: 2_000_000, categoryID: catFood,
                        businessID: bizB),
            // October — a different period, must not count.
            ReportEntry(date: date(2026, 10, 2), kind: .expense,
                        amount: 9_000_000, businessID: bizB),
        ]
        let result = compute(entries: entries, mode: .segment)
        #expect(result.total == 10_000_000)
        #expect(result.slices.map(\.name)
                == ["Cá nhân", "Làm web", "Căn hộ dịch vụ"])
        #expect(result.slices.map(\.amount)
                == [5_000_000, 3_000_000, 2_000_000])
        #expect(result.slices.map(\.percent) == [50, 30, 20])
        let personal = result.slices[0]
        #expect(personal.isPersonal)
        #expect(personal.businessID == nil)
        #expect(personal.id == SpendingShareBuilder.personalID)
        #expect(result.slices[1].businessID == bizA)
        #expect(result.slices[1].colorHex == "0A84FF")
        #expect(result.slices[2].businessID == bizB)
        #expect(!result.isEmpty)
    }

    @Test func transfersAreIgnored() {
        let entries = [
            // Huge transfer inside the period — never a share.
            ReportEntry(date: date(2026, 11, 5), kind: .transfer,
                        amount: 99_000_000, categoryID: catFood,
                        businessID: bizA),
            ReportEntry(date: date(2026, 11, 5), kind: .expense,
                        amount: 1_000_000, categoryID: catFood),
        ]
        let expense = compute(entries: entries, mode: .segment)
        #expect(expense.total == 1_000_000)
        #expect(expense.slices.map(\.name) == ["Cá nhân"])
        // A transfer-only period is empty even for income.
        let income = compute(
            entries: entries, kind: .income, mode: .category)
        #expect(income.isEmpty)
        #expect(income.total == 0)
    }

    // MARK: - By category ("Danh mục")

    @Test func categorySharesResolveNamesAndUncategorized() {
        let entries = [
            ReportEntry(date: date(2026, 11, 5), kind: .expense,
                        amount: 4_000_000, categoryID: catFood),
            ReportEntry(date: date(2026, 11, 6), kind: .expense,
                        amount: 1_000_000),   // no category
        ]
        let result = compute(entries: entries, mode: .category)
        #expect(result.total == 5_000_000)
        #expect(result.slices.map(\.name) == ["Ăn uống", "Chưa phân loại"])
        #expect(result.slices.map(\.percent) == [80, 20])
        #expect(result.slices[0].categoryID == catFood)
        #expect(result.slices[0].colorHex == "FF9500")
        #expect(result.slices[1].categoryID == nil)
        #expect(result.slices[1].colorHex == "8E8E93")
    }

    @Test func categorySharesFoldIntoOtherBeyondSix() {
        // Eight categories, amounts 100k…800k — the two smallest fold away.
        let cats = (0..<8).map { _ in UUID() }
        let entries = cats.enumerated().map { index, id in
            ReportEntry(
                date: date(2026, 11, 5), kind: .expense,
                amount: Int64(index + 1) * 100_000, categoryID: id)
        }
        var info: [UUID: SpendingShareEntityInfo] = [:]
        for (index, id) in cats.enumerated() {
            info[id] = SpendingShareEntityInfo(name: "Mục \(index + 1)")
        }
        let result = SpendingShareBuilder.compute(.init(
            entries: entries,
            interval: november2026,
            kind: .expense,
            mode: .category,
            categories: info
        ))
        #expect(result.slices.count == ShareDonutMath.sliceLimit + 1)
        #expect(result.slices.prefix(6).map(\.categoryID)
                == Array(cats.dropFirst(2).reversed()))
        let other = result.slices.last
        #expect(other?.isOther == true)
        #expect(other?.name == "Khác")
        #expect(other?.amount == 300_000)   // 100k + 200k
        #expect(other?.categoryID == nil)
        #expect(result.slices.map(\.percent).reduce(0, +) == 100)
    }

    // MARK: - Percents

    @Test func percentsSumToExactlyOneHundred() {
        // Largest-remainder: thirds become 34 + 33 + 33, still 100.
        #expect(ShareDonutMath.percents(amounts: [1, 1, 1]) == [34, 33, 33])
        #expect(ShareDonutMath.percents(amounts: [333_334, 333_333, 333_333])
                == [34, 33, 33])
        let entries = [
            ReportEntry(date: date(2026, 11, 1), kind: .expense,
                        amount: 333_334, categoryID: catFood),
            ReportEntry(date: date(2026, 11, 2), kind: .expense,
                        amount: 333_333, categoryID: catFuel),
            ReportEntry(date: date(2026, 11, 3), kind: .expense,
                        amount: 333_333, categoryID: catHome),
        ]
        let result = compute(entries: entries, mode: .category)
        #expect(result.slices.map(\.percent) == [34, 33, 33])
        #expect(result.slices.map(\.percent).reduce(0, +) == 100)
    }

    // MARK: - Edge cases

    @Test func emptyPeriodYieldsNoSlices() {
        let january = ReportDateInterval(
            start: date(2026, 1, 1, 0, 0), end: date(2026, 2, 1, 0, 0))
        let entries = [
            ReportEntry(date: date(2026, 11, 5), kind: .expense,
                        amount: 1_000_000, categoryID: catFood),
        ]
        let result = compute(
            entries: entries, mode: .category, interval: january)
        #expect(result.isEmpty)
        #expect(result.slices.isEmpty)
        #expect(result.total == 0)
        #expect(ShareDonutMath.percents(amounts: []).isEmpty)
        #expect(ShareDonutMath.percents(amounts: [0, 0]) == [0, 0])
    }

    @Test func singleSliceIsOneHundredPercent() {
        let entries = [
            ReportEntry(date: date(2026, 11, 5), kind: .expense,
                        amount: 2_500_000, categoryID: catFood),
        ]
        let result = compute(entries: entries, mode: .category)
        #expect(result.slices.count == 1)
        #expect(result.slices[0].percent == 100)
    }

    @Test func scopeFiltersEntries() {
        let entries = [
            ReportEntry(date: date(2026, 11, 5), kind: .expense,
                        amount: 3_000_000, categoryID: catFood),
            ReportEntry(date: date(2026, 11, 6), kind: .expense,
                        amount: 7_000_000, categoryID: catHome,
                        businessID: bizA),
        ]
        let personal = compute(
            entries: entries, mode: .segment, scope: .personal)
        #expect(personal.total == 3_000_000)
        #expect(personal.slices.map(\.name) == ["Cá nhân"])
        let scoped = compute(
            entries: entries, mode: .segment, scope: .business(bizA))
        #expect(scoped.total == 7_000_000)
        #expect(scoped.slices.map(\.businessID) == [bizA])
        #expect(scoped.slices[0].percent == 100)
    }

    @Test func incomeKindGroupsByCategory() {
        let entries = [
            ReportEntry(date: date(2026, 11, 5), kind: .income,
                        amount: 15_000_000, categoryID: catFood,
                        businessID: bizA),
            ReportEntry(date: date(2026, 11, 6), kind: .income,
                        amount: 5_000_000, categoryID: catFuel),
        ]
        let result = compute(entries: entries, kind: .income, mode: .category)
        #expect(result.total == 20_000_000)
        #expect(result.slices.map(\.name) == ["Ăn uống", "Di chuyển"])
        #expect(result.slices.map(\.percent) == [75, 25])
    }

    // MARK: - Chart math (ShareDonutMath)

    @Test func donutFoldingKeepsSixPlusOther() {
        let slices = (1...8).map {
            ShareDonutSlice(
                id: "s\($0)", name: "Mục \($0)", amount: Int64($0) * 100_000)
        }
        let folded = ShareDonutMath.folded(slices)
        #expect(folded.count == 7)
        #expect(folded.last?.id == ShareDonutMath.otherID)
        #expect(folded.last?.name == "Khác")
        #expect(folded.last?.amount == 300_000)
        // Idempotent: folding an already-folded list is a no-op.
        let refolded = ShareDonutMath.folded(folded)
        #expect(refolded == folded)
        // Everything fits → unchanged apart from ordering.
        let few = ShareDonutMath.folded(Array(slices.prefix(3)))
        #expect(few.count == 3)
        #expect(few.map(\.amount) == [300_000, 200_000, 100_000])
    }

    @Test func colorFallbackAssignsDistinctColors() {
        let slices = [
            ShareDonutSlice(id: "a", name: "A", amount: 5, colorHex: "FF9500"),
            // Duplicate of the first slice's color.
            ShareDonutSlice(id: "b", name: "B", amount: 4, colorHex: "FF9500"),
            // Missing.
            ShareDonutSlice(id: "c", name: "C", amount: 3, colorHex: ""),
            // Invalid hex.
            ShareDonutSlice(id: "d", name: "D", amount: 2, colorHex: "ZZZZZZ"),
            // Same color, lower case — still a duplicate.
            ShareDonutSlice(id: "e", name: "E", amount: 1, colorHex: "ff9500"),
        ]
        let resolved = ShareDonutMath.resolvedColorHexes(
            slices, palette: AppTheme.palette)
        #expect(resolved.count == slices.count)
        #expect(Set(resolved).count == slices.count)
        #expect(resolved[0] == "FF9500")
        #expect(resolved.allSatisfy { HexColor.parse($0) != nil })
    }

    // MARK: - SwiftData mapping (mirrors the views' entry conversion)

    @Test func builderFromSwiftDataEntries() throws {
        let context = try makeContext()
        let cash = Account(name: "Tiền mặt", kind: .cash)
        let food = LedgerCategory(
            name: "Ăn uống", kind: .expense, colorHex: "FF9500")
        let shop = Business(name: "Làm web", colorHex: "0A84FF")
        context.insert(cash)
        context.insert(food)
        context.insert(shop)
        context.insert(LedgerTransaction(
            kind: .expense, amount: 4_000_000, date: date(2026, 11, 5),
            account: cash, category: food, business: shop))
        context.insert(LedgerTransaction(
            kind: .expense, amount: 1_000_000, date: date(2026, 11, 6),
            account: cash, category: food))
        context.insert(LedgerTransaction(
            kind: .transfer, amount: 8_000_000, date: date(2026, 11, 7),
            account: cash))
        context.insert(LedgerTransaction(
            kind: .expense, amount: 7_000_000, date: date(2026, 10, 2),
            account: cash, category: food))
        try context.save()

        // The same date+kind predicate the card and section queries use.
        let start = november2026.start
        let end = november2026.end
        let expense = TransactionKind.expense.rawValue
        let fetched = try context.fetch(FetchDescriptor<LedgerTransaction>(
            predicate: #Predicate {
                $0.date >= start && $0.date < end && $0.kindRaw == expense
            }))
        #expect(fetched.count == 2)

        let entries = fetched.map {
            ReportEntry(
                date: $0.date, kind: $0.kind, amount: $0.amount,
                categoryID: $0.category?.id, businessID: $0.business?.id)
        }
        let result = SpendingShareBuilder.compute(.init(
            entries: entries,
            interval: november2026,
            kind: .expense,
            mode: .segment,
            businesses: [shop.id: SpendingShareEntityInfo(
                name: shop.name, colorHex: shop.colorHex)]
        ))
        #expect(result.total == 5_000_000)
        #expect(result.slices.map(\.name) == ["Làm web", "Cá nhân"])
        #expect(result.slices.map(\.percent) == [80, 20])
        #expect(result.slices[0].businessID == shop.id)
    }
}
