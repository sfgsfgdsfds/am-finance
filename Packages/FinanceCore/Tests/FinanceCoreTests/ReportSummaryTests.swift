import Foundation
import Testing
@testable import FinanceCore

// All helpers are private so nothing collides with other test files.

private let reportCal: Calendar = {
    var c = Calendar(identifier: .gregorian)
    c.timeZone = TimeZone(identifier: "Asia/Ho_Chi_Minh")!
    return c
}()

/// Start-of-day (or a given time) in the test calendar.
private func d(_ year: Int, _ month: Int, _ day: Int,
               hour: Int = 0, minute: Int = 0) -> Date {
    reportCal.date(from: DateComponents(year: year, month: month, day: day,
                                        hour: hour, minute: minute))!
}

private let catFood = UUID(uuidString: "11111111-1111-1111-1111-111111111111")!
private let catRent = UUID(uuidString: "22222222-2222-2222-2222-222222222222")!
private let catFun  = UUID(uuidString: "33333333-3333-3333-3333-333333333333")!
private let bizApt  = UUID(uuidString: "AAAAAAAA-AAAA-AAAA-AAAA-AAAAAAAAAAAA")!
private let bizWeb  = UUID(uuidString: "BBBBBBBB-BBBB-BBBB-BBBB-BBBBBBBBBBBB")!

private func entry(_ y: Int, _ mo: Int, _ day: Int,
                   _ kind: TransactionKind, _ amount: Int64,
                   category: UUID? = nil, business: UUID? = nil,
                   hour: Int = 0, minute: Int = 0) -> ReportEntry {
    ReportEntry(date: d(y, mo, day, hour: hour, minute: minute),
                kind: kind, amount: amount,
                categoryID: category, businessID: business)
}

private let july = ReportDateInterval(start: d(2026, 7, 1), end: d(2026, 8, 1))

struct ReportTotalsTests {

    @Test func emptyInput() {
        let t = ReportSummary.totals(entries: [], in: july)
        #expect(t == .zero)
        #expect(t.net == 0)
        #expect(ReportSummary.byCategory(entries: [], in: july, kind: .expense).isEmpty)
        #expect(ReportSummary.byBusiness(entries: [], in: july).isEmpty)
    }

    @Test func incomeExpenseNetCount() {
        let entries = [
            entry(2026, 7, 5, .income, 2_000_000),
            entry(2026, 7, 10, .income, 500_000),
            entry(2026, 7, 15, .expense, 900_000),
        ]
        let t = ReportSummary.totals(entries: entries, in: july)
        #expect(t.income == 2_500_000)
        #expect(t.expense == 900_000)
        #expect(t.net == 1_600_000)
        #expect(t.count == 3)
    }

    @Test func transfersIgnored() {
        let entries = [
            entry(2026, 7, 5, .income, 1_000_000),
            entry(2026, 7, 6, .transfer, 5_000_000),   // card payment
            entry(2026, 7, 7, .transfer, 3_000_000),   // loan repayment
        ]
        let t = ReportSummary.totals(entries: entries, in: july)
        #expect(t.income == 1_000_000)
        #expect(t.expense == 0)
        #expect(t.count == 1)
    }

    @Test func intervalBoundsAreHalfOpen() {
        let entries = [
            entry(2026, 6, 30, .expense, 100),         // before start
            entry(2026, 7, 1, .expense, 200),          // exactly at start: in
            entry(2026, 7, 31, .expense, 300, hour: 23, minute: 59),
            entry(2026, 8, 1, .expense, 400),          // exactly at end: out
        ]
        let t = ReportSummary.totals(entries: entries, in: july)
        #expect(t.expense == 500)
        #expect(t.count == 2)
    }

    @Test func emptyIntervalMatchesNothing() {
        let empty = ReportDateInterval(start: d(2026, 7, 10), end: d(2026, 7, 10))
        let entries = [entry(2026, 7, 10, .expense, 500)]
        #expect(ReportSummary.totals(entries: entries, in: empty) == .zero)
    }

    @Test func sumsSaturate() {
        // Two huge incomes must not trap — they clamp at Int64.max.
        let entries = [
            entry(2026, 7, 5, .income, .max),
            entry(2026, 7, 6, .income, 1),
        ]
        let t = ReportSummary.totals(entries: entries, in: july)
        #expect(t.income == .max)
        #expect(t.net == .max)
    }

    @Test func negativeAmountsClampToZero() {
        let entries = [entry(2026, 7, 5, .income, -100)]
        #expect(ReportSummary.totals(entries: entries, in: july).income == 0)
    }
}

struct ReportSplitTests {

    @Test func personalVsBusiness() {
        let entries = [
            entry(2026, 7, 1, .income, 1_000_000),                       // personal
            entry(2026, 7, 2, .expense, 200_000),                        // personal
            entry(2026, 7, 3, .income, 5_000_000, business: bizApt),
            entry(2026, 7, 4, .expense, 800_000, business: bizWeb),
            entry(2026, 7, 5, .transfer, 9_000_000, business: bizApt),   // ignored
        ]
        let s = ReportSummary.splitByOwnership(entries: entries, in: july)
        #expect(s.personal == ReportTotals(income: 1_000_000, expense: 200_000, count: 2))
        #expect(s.business == ReportTotals(income: 5_000_000, expense: 800_000, count: 2))
    }

    @Test func scopeFiltersTotals() {
        let entries = [
            entry(2026, 7, 1, .expense, 100),
            entry(2026, 7, 2, .expense, 200, business: bizApt),
            entry(2026, 7, 3, .expense, 300, business: bizWeb),
        ]
        #expect(ReportSummary.totals(entries: entries, in: july, scope: .personal).expense == 100)
        #expect(ReportSummary.totals(entries: entries, in: july, scope: .anyBusiness).expense == 500)
        #expect(ReportSummary.totals(entries: entries, in: july, scope: .business(bizApt)).expense == 200)
    }
}

struct ReportCategoryTests {

    @Test func rankingAndShares() {
        let entries = [
            entry(2026, 7, 1, .expense, 100, category: catFood),
            entry(2026, 7, 2, .expense, 300, category: catRent),
            entry(2026, 7, 3, .expense, 200, category: catFood),
            entry(2026, 7, 4, .expense, 400),                            // uncategorized
            entry(2026, 7, 5, .income, 9_000, category: catFood),        // other kind
        ]
        let rows = ReportSummary.byCategory(entries: entries, in: july, kind: .expense)
        #expect(rows.count == 3)
        // Totals: uncategorized 400, food 300, rent 300. Tie breaks nil last.
        #expect(rows[0].categoryID == nil && rows[0].total == 400)
        #expect(rows[1].categoryID == catFood && rows[1].total == 300)
        #expect(rows[1].count == 2)
        #expect(rows[2].categoryID == catRent && rows[2].total == 300)
        #expect(rows[0].share == 0.4)
        #expect(rows[1].share == 0.3)
        #expect(abs(rows[2].share - 0.3) < 1e-12)
        #expect(rows.allSatisfy { !$0.isOther })
    }

    @Test func tieBreakIsDeterministic() {
        // Equal totals: non-nil categories order by UUID string,
        // uncategorized always last.
        let entries = [
            entry(2026, 7, 1, .expense, 100, category: catFun),
            entry(2026, 7, 2, .expense, 100, category: catFood),
            entry(2026, 7, 3, .expense, 100, category: catRent),
        ]
        let rows = ReportSummary.byCategory(entries: entries, in: july, kind: .expense)
        #expect(rows.map(\.categoryID) == [catFood, catRent, catFun])
    }

    @Test func topNFoldsRestIntoOther() {
        let entries = [
            entry(2026, 7, 1, .expense, 500, category: catRent),
            entry(2026, 7, 2, .expense, 300, category: catFood),
            entry(2026, 7, 3, .expense, 150, category: catFun),
            entry(2026, 7, 4, .expense, 50),                             // uncategorized
        ]
        let rows = ReportSummary.topCategories(entries: entries, in: july,
                                               kind: .expense, limit: 2)
        #expect(rows.count == 3)
        #expect(rows[0].categoryID == catRent)
        #expect(rows[1].categoryID == catFood)
        let other = rows[2]
        #expect(other.isOther)
        #expect(other.categoryID == nil)
        #expect(other.total == 200)
        #expect(other.count == 2)
        #expect(other.share == 0.2)
    }

    @Test func topNCoversAllWhenLimitIsBig() {
        let entries = [entry(2026, 7, 1, .expense, 100, category: catFood)]
        let rows = ReportSummary.topCategories(entries: entries, in: july,
                                               kind: .expense, limit: 5)
        #expect(rows.count == 1)
        #expect(!rows[0].isOther)
    }
}

struct ReportBusinessTests {

    @Test func profitLossAndMargin() {
        let entries = [
            entry(2026, 7, 1, .income, 4_000_000, business: bizApt),
            entry(2026, 7, 2, .expense, 1_000_000, business: bizApt),
            entry(2026, 7, 3, .income, 2_000_000, business: bizWeb),
            entry(2026, 7, 4, .expense, 3_000_000, business: bizWeb),
            entry(2026, 7, 5, .expense, 500_000),                        // personal: out
        ]
        let rows = ReportSummary.byBusiness(entries: entries, in: july)
        #expect(rows.count == 2)
        // Sorted by profit descending: apt (+3tr) before web (-1tr).
        #expect(rows[0].businessID == bizApt)
        #expect(rows[0].revenue == 4_000_000)
        #expect(rows[0].cost == 1_000_000)
        #expect(rows[0].profit == 3_000_000)
        #expect(rows[0].margin == 0.75)
        #expect(rows[1].businessID == bizWeb)
        #expect(rows[1].profit == -1_000_000)
        #expect(rows[1].margin == -0.5)
    }

    @Test func zeroRevenueBusinessHasZeroMargin() {
        // Costs only: profit negative but margin is defined as 0.
        let entries = [entry(2026, 7, 1, .expense, 700_000, business: bizApt)]
        let rows = ReportSummary.byBusiness(entries: entries, in: july)
        #expect(rows.count == 1)
        #expect(rows[0].revenue == 0)
        #expect(rows[0].profit == -700_000)
        #expect(rows[0].margin == 0)
    }
}

struct ReportMonthlySeriesTests {

    @Test func spansYearBoundaryAndZeroFills() {
        // 4 months ending in March 2026: Dec 2025 ... Mar 2026.
        let entries = [
            entry(2025, 12, 10, .income, 1_000_000),
            entry(2026, 1, 5, .expense, 300_000),
            entry(2026, 1, 20, .income, 200_000),
            entry(2026, 3, 1, .expense, 100_000),
            entry(2025, 11, 30, .income, 9_000_000),   // before window
        ]
        let points = ReportSummary.monthly(entries: entries, months: 4,
                                           endingAt: d(2026, 3, 15),
                                           calendar: reportCal)
        #expect(points.count == 4)
        #expect(points[0].monthStart == d(2025, 12, 1))
        #expect(points[0].income == 1_000_000 && points[0].expense == 0)
        #expect(points[0].net == 1_000_000)
        #expect(points[1].monthStart == d(2026, 1, 1))
        #expect(points[1].income == 200_000 && points[1].expense == 300_000)
        #expect(points[1].net == -100_000)
        // February has no entries but is still present.
        #expect(points[2].monthStart == d(2026, 2, 1))
        #expect(points[2].income == 0 && points[2].expense == 0 && points[2].net == 0)
        #expect(points[3].monthStart == d(2026, 3, 1))
        #expect(points[3].expense == 100_000)
    }

    @Test func emptyInputStillProducesMonths() {
        let points = ReportSummary.monthly(entries: [], months: 3,
                                           endingAt: d(2026, 6, 20),
                                           calendar: reportCal)
        #expect(points.count == 3)
        #expect(points.allSatisfy { $0.income == 0 && $0.expense == 0 })
    }

    @Test func scopeFilters() {
        let entries = [
            entry(2026, 6, 5, .income, 100),
            entry(2026, 6, 6, .income, 200, business: bizApt),
            entry(2026, 6, 7, .income, 400, business: bizWeb),
        ]
        let all = ReportSummary.monthly(entries: entries, months: 1,
                                        endingAt: d(2026, 6, 15), calendar: reportCal)
        #expect(all[0].income == 700)
        let personal = ReportSummary.monthly(entries: entries, months: 1,
                                             endingAt: d(2026, 6, 15), calendar: reportCal,
                                             scope: .personal)
        #expect(personal[0].income == 100)
        let apt = ReportSummary.monthly(entries: entries, months: 1,
                                        endingAt: d(2026, 6, 15), calendar: reportCal,
                                        scope: .business(bizApt))
        #expect(apt[0].income == 200)
    }

    @Test func entryJustAfterMidnightOnTheFirst() {
        // 00:30 local (Asia/Ho_Chi_Minh) on March 1 belongs to March.
        let entries = [entry(2026, 3, 1, .income, 250_000, hour: 0, minute: 30)]
        let points = ReportSummary.monthly(entries: entries, months: 2,
                                           endingAt: d(2026, 3, 20),
                                           calendar: reportCal)
        #expect(points[0].monthStart == d(2026, 2, 1) && points[0].income == 0)
        #expect(points[1].monthStart == d(2026, 3, 1) && points[1].income == 250_000)
    }

    @Test func nonpositiveMonthCount() {
        #expect(ReportSummary.monthly(entries: [], months: 0,
                                      endingAt: d(2026, 6, 1),
                                      calendar: reportCal).isEmpty)
    }
}

struct ReportDailySeriesTests {

    @Test func februaryLeapYearHas29Days() {
        let points = ReportSummary.daily(entries: [],
                                         inMonthContaining: d(2024, 2, 15),
                                         calendar: reportCal)
        #expect(points.count == 29)
        #expect(points[28].date == d(2024, 2, 29))
    }

    @Test func februaryCommonYearHas28Days() {
        let points = ReportSummary.daily(entries: [],
                                         inMonthContaining: d(2026, 2, 15),
                                         calendar: reportCal)
        #expect(points.count == 28)
        #expect(points[27].date == d(2026, 2, 28))
    }

    @Test func entriesLandOnTheirDayAndZeroFill() {
        let entries = [
            entry(2026, 7, 1, .income, 100, hour: 0, minute: 30),
            entry(2026, 7, 1, .expense, 40, hour: 23, minute: 30),
            entry(2026, 7, 31, .expense, 50),
            entry(2026, 8, 1, .expense, 60),             // next month: out
            entry(2026, 7, 20, .transfer, 999),          // ignored
        ]
        let points = ReportSummary.daily(entries: entries,
                                         inMonthContaining: d(2026, 7, 15),
                                         calendar: reportCal)
        #expect(points.count == 31)
        #expect(points[0].date == d(2026, 7, 1))
        #expect(points[0].income == 100 && points[0].expense == 40)
        #expect(points[30].expense == 50)
        #expect(points[1].income == 0 && points[1].expense == 0)
        #expect(points[29].net == 0)
    }
}

struct ReportMonthIntervalTests {

    @Test func startAndEndOfMonth() {
        let m = ReportSummary.monthInterval(containing: d(2026, 3, 15),
                                            calendar: reportCal)
        #expect(m.start == d(2026, 3, 1))
        #expect(m.end == d(2026, 4, 1))
    }

    @Test func firstInstantOfMonth() {
        // 00:30 local on the 1st is inside that month, not the previous.
        let m = ReportSummary.monthInterval(containing: d(2026, 3, 1, hour: 0, minute: 30),
                                            calendar: reportCal)
        #expect(m.start == d(2026, 3, 1))
        #expect(m.end == d(2026, 4, 1))
        // One instant before midnight local is still February.
        let feb = ReportSummary.monthInterval(
            containing: d(2026, 3, 1).addingTimeInterval(-1), calendar: reportCal)
        #expect(feb.start == d(2026, 2, 1))
    }

    @Test func decemberRollsToJanuary() {
        let m = ReportSummary.monthInterval(containing: d(2025, 12, 25),
                                            calendar: reportCal)
        #expect(m.start == d(2025, 12, 1))
        #expect(m.end == d(2026, 1, 1))
    }
}

struct ReportComparisonTests {

    @Test func equalLengthPreviousInterval() {
        // July vs June (both the [1st, 1st) span: previous has equal
        // duration, not equal calendar size).
        let entries = [
            entry(2026, 7, 10, .income, 2_000_000),
            entry(2026, 6, 15, .income, 1_000_000),
        ]
        let c = ReportSummary.comparison(entries: entries, in: july)
        #expect(c.current.income == 2_000_000)
        #expect(c.previous.income == 1_000_000)
        #expect(c.income.delta == 1_000_000)
        #expect(c.income.percent == 1.0)               // +100%
        #expect(c.previous.count == 1)
        #expect(c.count.delta == 0)
        #expect(c.count.percent == 0)
    }

    @Test func zeroPreviousGivesNilPercent() {
        // June had nothing; July has income. Percent is undefined → nil.
        let entries = [entry(2026, 7, 10, .income, 500_000)]
        let c = ReportSummary.comparison(entries: entries, in: july)
        #expect(c.previous == .zero)
        #expect(c.income.delta == 500_000)
        #expect(c.income.percent == nil)
        #expect(c.net.percent == nil)
        #expect(c.count.percent == nil)
    }

    @Test func negativeDirection() {
        let entries = [
            entry(2026, 6, 10, .expense, 400_000),
            entry(2026, 7, 10, .expense, 300_000),
        ]
        let c = ReportSummary.comparison(entries: entries, in: july)
        #expect(c.expense.delta == -100_000)
        #expect(c.expense.percent == -0.25)
    }

    @Test func previousIntervalHelper() {
        #expect(july.previous.start == d(2026, 5, 31))   // 31 days back
        #expect(july.previous.end == d(2026, 7, 1))
        #expect(july.next.start == d(2026, 8, 1))
        #expect(july.next.end == d(2026, 9, 1))
    }
}
