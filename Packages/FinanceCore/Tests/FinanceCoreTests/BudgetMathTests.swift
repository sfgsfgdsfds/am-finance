import Foundation
import Testing
@testable import FinanceCore

private let hcm: Calendar = {
    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = TimeZone(identifier: "Asia/Ho_Chi_Minh")!
    return calendar
}()

private let utc: Calendar = {
    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = TimeZone(identifier: "UTC")!
    return calendar
}()

/// Local date-time in Asia/Ho_Chi_Minh.
private func day(
    _ y: Int, _ m: Int, _ d: Int,
    _ h: Int = 0, _ min: Int = 0, _ s: Int = 0
) -> Date {
    hcm.date(from: DateComponents(
        year: y, month: m, day: d, hour: h, minute: min, second: s))!
}

/// Date-time built from UTC components.
private func utcDay(
    _ y: Int, _ m: Int, _ d: Int,
    _ h: Int = 0, _ min: Int = 0
) -> Date {
    utc.date(from: DateComponents(year: y, month: m, day: d, hour: h, minute: min))!
}

private let foodID = UUID(uuidString: "11111111-1111-1111-1111-111111111111")!
private let travelID = UUID(uuidString: "22222222-2222-2222-2222-222222222222")!
private let toolsID = UUID(uuidString: "33333333-3333-3333-3333-333333333333")!
private let catA = UUID(uuidString: "aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa")!
private let catB = UUID(uuidString: "bbbbbbbb-bbbb-bbbb-bbbb-bbbbbbbbbbbb")!
private let catC = UUID(uuidString: "cccccccc-cccc-cccc-cccc-cccccccccccc")!
private let catD = UUID(uuidString: "dddddddd-dddd-dddd-dddd-dddddddddddd")!
private let catE = UUID(uuidString: "eeeeeeee-eeee-eeee-eeee-eeeeeeeeeeee")!

struct BudgetEvaluationTests {

    // January 2026 has 31 days; as of Jan 15: 15 elapsed, 16 left.

    @Test func noSpend() throws {
        let limit = try BudgetLimit(categoryID: foodID, monthlyLimit: 3_000_000)
        let row = try BudgetMath.evaluate(
            limit: limit, spends: [],
            asOf: day(2026, 1, 15), calendar: hcm)
        #expect(row.spent == 0)
        #expect(row.remaining == 3_000_000)
        #expect(row.fractionUsed == 0)
        #expect(row.status == .ok)
        #expect(row.daysElapsed == 15)
        #expect(row.daysLeft == 16)
        #expect(row.averageDailySpend == 0)
        #expect(row.projectedMonthEndSpend == 0)
        #expect(row.safeDailySpend == 187_500)  // 3_000_000 / 16
        #expect(!row.projectionExceedsLimit)
        #expect(row.message == "Còn 3.000.000 ₫ cho 16 ngày")
    }

    @Test func underAtThresholdAtLimitOver() throws {
        // Limit 1_000_000, default threshold 0.8 → warning at ≥ 800_000.
        let limit = try BudgetLimit(categoryID: foodID, monthlyLimit: 1_000_000)
        func spend(_ amount: Int64) throws -> [BudgetSpend] {
            [try BudgetSpend(categoryID: foodID, date: day(2026, 1, 10), amount: amount)]
        }
        let under = try BudgetMath.evaluate(
            limit: limit, spends: spend(700_000),
            asOf: day(2026, 1, 15), calendar: hcm)
        #expect(under.fractionUsed == 0.7)
        #expect(under.status == .ok)

        let atThreshold = try BudgetMath.evaluate(
            limit: limit, spends: spend(800_000),
            asOf: day(2026, 1, 15), calendar: hcm)
        #expect(atThreshold.fractionUsed == 0.8)
        #expect(atThreshold.status == .warning)

        let atLimit = try BudgetMath.evaluate(
            limit: limit, spends: spend(1_000_000),
            asOf: day(2026, 1, 15), calendar: hcm)
        #expect(atLimit.fractionUsed == 1)
        #expect(atLimit.status == .warning)  // at, not over
        #expect(atLimit.remaining == 0)
        #expect(atLimit.safeDailySpend == 0)

        let over = try BudgetMath.evaluate(
            limit: limit, spends: spend(1_000_001),
            asOf: day(2026, 1, 15), calendar: hcm)
        #expect(over.status == .exceeded)
        #expect(over.remaining == -1)
        #expect(over.safeDailySpend == 0)
    }

    @Test func customWarningThreshold() throws {
        let limit = try BudgetLimit(categoryID: foodID, monthlyLimit: 1_000_000)
        let spend = try BudgetSpend(categoryID: foodID, date: day(2026, 1, 10), amount: 600_000)
        let strict = try BudgetMath.evaluate(
            limit: limit, spends: [spend],
            asOf: day(2026, 1, 15), calendar: hcm, warningThreshold: 0.5)
        #expect(strict.status == .warning)  // 0.6 ≥ 0.5
        let loose = try BudgetMath.evaluate(
            limit: limit, spends: [spend],
            asOf: day(2026, 1, 15), calendar: hcm, warningThreshold: 0.9)
        #expect(loose.status == .ok)  // 0.6 < 0.9
    }

    @Test func overallCountsEveryCategory() throws {
        let limit = try BudgetLimit(monthlyLimit: 10_000_000)  // nil = overall
        let spends = try [
            BudgetSpend(categoryID: foodID, date: day(2026, 1, 5), amount: 1_000_000),
            BudgetSpend(categoryID: travelID, date: day(2026, 1, 8), amount: 2_000_000),
            BudgetSpend(date: day(2026, 1, 12), amount: 500_000),  // uncategorized
        ]
        let row = try BudgetMath.evaluate(
            limit: limit, spends: spends,
            asOf: day(2026, 1, 15), calendar: hcm)
        #expect(row.spent == 3_500_000)
        #expect(row.remaining == 6_500_000)
    }

    @Test func categoryLimitCountsOnlyItsCategory() throws {
        let limit = try BudgetLimit(categoryID: foodID, monthlyLimit: 10_000_000)
        let spends = try [
            BudgetSpend(categoryID: foodID, date: day(2026, 1, 5), amount: 1_000_000),
            BudgetSpend(categoryID: travelID, date: day(2026, 1, 8), amount: 2_000_000),
            BudgetSpend(date: day(2026, 1, 12), amount: 500_000),
            BudgetSpend(categoryID: foodID, date: day(2025, 12, 31), amount: 9_000_000),  // other month
        ]
        let row = try BudgetMath.evaluate(
            limit: limit, spends: spends,
            asOf: day(2026, 1, 15), calendar: hcm)
        #expect(row.spent == 1_000_000)
        #expect(row.remaining == 9_000_000)
    }

    @Test func spendsAfterReferenceDayDoNotCountYet() throws {
        let limit = try BudgetLimit(monthlyLimit: 10_000_000)
        let spends = try [
            BudgetSpend(date: day(2026, 1, 14), amount: 100_000),
            BudgetSpend(date: day(2026, 1, 15, 23), amount: 200_000),  // same day, later hour
            BudgetSpend(date: day(2026, 1, 16), amount: 400_000),      // tomorrow: not yet
        ]
        let row = try BudgetMath.evaluate(
            limit: limit, spends: spends,
            asOf: day(2026, 1, 15, 9), calendar: hcm)
        #expect(row.spent == 300_000)
    }

    @Test func firstDayOfMonth() throws {
        let limit = try BudgetLimit(monthlyLimit: 3_000_000)
        let row = try BudgetMath.evaluate(
            limit: limit,
            spends: [try BudgetSpend(date: day(2026, 1, 1, 12), amount: 100_000)],
            asOf: day(2026, 1, 1), calendar: hcm)
        #expect(row.daysElapsed == 1)
        #expect(row.daysLeft == 30)
        #expect(row.averageDailySpend == 100_000)
        #expect(row.projectedMonthEndSpend == 3_100_000)  // 100_000 × 31
        #expect(row.projectionExceedsLimit)
        #expect(row.safeDailySpend == 96_666)  // 2_900_000 / 30
    }

    @Test func lastDayOfMonth() throws {
        // Jan 31: 31 elapsed, 0 left; projected == spent (pace already final).
        let limit = try BudgetLimit(monthlyLimit: 3_100_000)
        let row = try BudgetMath.evaluate(
            limit: limit,
            spends: [try BudgetSpend(date: day(2026, 1, 31), amount: 3_100_000)],
            asOf: day(2026, 1, 31, 12), calendar: hcm)
        #expect(row.daysElapsed == 31)
        #expect(row.daysLeft == 0)
        #expect(row.averageDailySpend == 100_000)
        #expect(row.projectedMonthEndSpend == 3_100_000)
        #expect(row.status == .warning)  // spent == limit, not over
        #expect(!row.projectionExceedsLimit)
        #expect(row.safeDailySpend == 0)  // nothing remains
        #expect(row.message == "Đã hết hạn mức")
    }

    @Test func lastDaySafeDailyIsWholeRemaining() throws {
        // Still under the limit on the last day: today can spend it all.
        let limit = try BudgetLimit(monthlyLimit: 5_000_000)
        let row = try BudgetMath.evaluate(
            limit: limit,
            spends: [try BudgetSpend(date: day(2026, 1, 31), amount: 3_100_000)],
            asOf: day(2026, 1, 31, 12), calendar: hcm)
        #expect(row.remaining == 1_900_000)
        #expect(row.daysLeft == 0)
        #expect(row.safeDailySpend == 1_900_000)
        #expect(row.message == "Còn 1.900.000 ₫ cho hôm nay")
    }

    @Test func leapYearFebruary() throws {
        let limit = try BudgetLimit(monthlyLimit: 2_900_000)
        // February 2024 has 29 days.
        let first = try BudgetMath.evaluate(
            limit: limit,
            spends: [try BudgetSpend(date: day(2024, 2, 1, 8), amount: 100_000)],
            asOf: day(2024, 2, 1, 9), calendar: hcm)
        #expect(first.daysElapsed == 1)
        #expect(first.daysLeft == 28)
        #expect(first.projectedMonthEndSpend == 2_900_000)  // 100_000 × 29
        #expect(!first.projectionExceedsLimit)  // projection lands exactly on the limit

        let last = try BudgetMath.evaluate(
            limit: limit,
            spends: [try BudgetSpend(date: day(2024, 2, 29, 10), amount: 580_000)],
            asOf: day(2024, 2, 29, 12), calendar: hcm)
        #expect(last.daysElapsed == 29)
        #expect(last.daysLeft == 0)
        #expect(last.averageDailySpend == 20_000)
        #expect(last.projectedMonthEndSpend == 580_000)

        // February 2025 is not a leap year: Feb 28 is already the last day.
        let nonLeap = try BudgetMath.evaluate(
            limit: limit, spends: [],
            asOf: day(2025, 2, 28), calendar: hcm)
        #expect(nonLeap.daysElapsed == 28)
        #expect(nonLeap.daysLeft == 0)
    }

    @Test func projectionHandCheckable() throws {
        // 4 spends of 400_000 during Jan 1-15 → 1_600_000 spent as of
        // Jan 16 → 100_000/day → projected 3_100_000 for the 31 days.
        let spends = try (1...4).map {
            try BudgetSpend(categoryID: foodID, date: day(2026, 1, $0), amount: 400_000)
        }
        let atLimit = try BudgetMath.evaluate(
            limit: try BudgetLimit(categoryID: foodID, monthlyLimit: 3_100_000),
            spends: spends, asOf: day(2026, 1, 16), calendar: hcm)
        #expect(atLimit.spent == 1_600_000)
        #expect(atLimit.daysElapsed == 16)
        #expect(atLimit.daysLeft == 15)
        #expect(atLimit.averageDailySpend == 100_000)
        #expect(atLimit.projectedMonthEndSpend == 3_100_000)
        #expect(!atLimit.projectionExceedsLimit)  // equal to the limit

        let tighter = try BudgetMath.evaluate(
            limit: try BudgetLimit(categoryID: foodID, monthlyLimit: 3_000_000),
            spends: spends, asOf: day(2026, 1, 16), calendar: hcm)
        #expect(tighter.projectedMonthEndSpend == 3_100_000)
        #expect(tighter.projectionExceedsLimit)  // pace is over…
        #expect(tighter.status == .ok)           // …but so far only ~53% used
        #expect(tighter.remaining == 1_400_000)
        #expect(tighter.safeDailySpend == 93_333)  // 1_400_000 / 15
    }

    @Test func safeDailySplitsRemainingOverDaysLeft() throws {
        // Jan 15 → 16 days left; 2_200_000 / 16 = 137_500.
        let row = try BudgetMath.evaluate(
            limit: try BudgetLimit(monthlyLimit: 3_000_000),
            spends: [try BudgetSpend(date: day(2026, 1, 10), amount: 800_000)],
            asOf: day(2026, 1, 15), calendar: hcm)
        #expect(row.remaining == 2_200_000)
        #expect(row.safeDailySpend == 137_500)
    }
}

struct BudgetMessageTests {

    @Test func remainingForDaysLeft() throws {
        // Spec example: "Còn 1.200.000 ₫ cho 12 ngày" — Jan 19, 12 days left.
        let row = try BudgetMath.evaluate(
            limit: try BudgetLimit(categoryID: foodID, monthlyLimit: 2_000_000),
            spends: [try BudgetSpend(categoryID: foodID, date: day(2026, 1, 10), amount: 800_000)],
            asOf: day(2026, 1, 19), calendar: hcm)
        #expect(row.status == .ok)  // 0.4 < 0.8
        #expect(row.message == "Còn 1.200.000 ₫ cho 12 ngày")
    }

    @Test func exceededShowsOvershoot() throws {
        // Spec example: "Vượt 350.000 ₫".
        let row = try BudgetMath.evaluate(
            limit: try BudgetLimit(monthlyLimit: 1_000_000),
            spends: [try BudgetSpend(date: day(2026, 1, 10), amount: 1_350_000)],
            asOf: day(2026, 1, 15), calendar: hcm)
        #expect(row.status == .exceeded)
        #expect(row.message == "Vượt 350.000 ₫")
    }

    @Test func warningStillShowsRemainingMessage() throws {
        // In warning but inside the limit: same "Còn … cho … ngày" form.
        let row = try BudgetMath.evaluate(
            limit: try BudgetLimit(monthlyLimit: 1_000_000),
            spends: [try BudgetSpend(date: day(2026, 1, 10), amount: 900_000)],
            asOf: day(2026, 1, 19), calendar: hcm)
        #expect(row.status == .warning)
        #expect(row.message == "Còn 100.000 ₫ cho 12 ngày")
    }
}

struct BudgetSummaryTests {

    @Test func sortingAndCounts() throws {
        // As of Jan 15, five 1_000_000 limits:
        //   catA ok 0.3, catB exceeded 1.5, catC warning 0.9,
        //   catD ok 0.5, catE exceeded 1.1
        // plus a 600_000 spend in an unwatched category.
        let spends = try [
            BudgetSpend(categoryID: catA, date: day(2026, 1, 5), amount: 300_000),
            BudgetSpend(categoryID: catB, date: day(2026, 1, 5), amount: 1_500_000),
            BudgetSpend(categoryID: catC, date: day(2026, 1, 5), amount: 900_000),
            BudgetSpend(categoryID: catD, date: day(2026, 1, 5), amount: 500_000),
            BudgetSpend(categoryID: catE, date: day(2026, 1, 5), amount: 1_100_000),
            BudgetSpend(categoryID: toolsID, date: day(2026, 1, 5), amount: 600_000),
        ]
        let limits = try [catA, catB, catC, catD, catE].map {
            try BudgetLimit(categoryID: $0, monthlyLimit: 1_000_000)
        }
        let summary = try BudgetMath.summary(
            limits: limits, spends: spends,
            asOf: day(2026, 1, 15), calendar: hcm)

        // Exceeded first (fraction desc: 1.5 then 1.1), then warning,
        // then ok (fraction desc: 0.5 then 0.3).
        #expect(summary.rows.map(\.limit.categoryID) == [catB, catE, catC, catD, catA])
        #expect(summary.exceededCount == 2)
        #expect(summary.warningCount == 1)
        #expect(summary.okCount == 2)
        #expect(summary.totalLimit == 5_000_000)
        // Every spend of the month counts once, including the unwatched
        // 600_000 — the row totals only sum to 4_300_000.
        #expect(summary.totalSpent == 4_900_000)
    }

    @Test func totalSpentCountsEachSpendOnce() throws {
        // One food spend feeds both the overall row and the food row,
        // but totalSpent is the real money out — counted once.
        let spends = [try BudgetSpend(categoryID: foodID, date: day(2026, 1, 5), amount: 2_000_000)]
        let limits = [
            try BudgetLimit(monthlyLimit: 10_000_000),
            try BudgetLimit(categoryID: foodID, monthlyLimit: 5_000_000),
        ]
        let summary = try BudgetMath.summary(
            limits: limits, spends: spends,
            asOf: day(2026, 1, 15), calendar: hcm)
        #expect(summary.totalSpent == 2_000_000)
        // Both ok; sorted by fraction used descending: 0.4 before 0.2.
        #expect(summary.rows.map(\.limit.categoryID) == [foodID, nil])
        #expect(summary.rows.map(\.spent) == [2_000_000, 2_000_000])
    }

    @Test func emptyLimits() throws {
        let summary = try BudgetMath.summary(
            limits: [],
            spends: [try BudgetSpend(date: day(2026, 1, 5), amount: 700_000)],
            asOf: day(2026, 1, 15), calendar: hcm)
        #expect(summary.rows.isEmpty)
        #expect(summary.totalLimit == 0)
        #expect(summary.totalSpent == 700_000)
        #expect(summary.okCount == 0)
        #expect(summary.warningCount == 0)
        #expect(summary.exceededCount == 0)
    }
}

struct BudgetTimeZoneTests {

    @Test func monthBoundaryInHoChiMinh() throws {
        // 2026-01-31 16:00 UTC = 23:00 HCM on Jan 31 → January spend.
        // 2026-01-31 18:00 UTC = 01:00 HCM on Feb 1  → February spend.
        let januarySpend = try BudgetSpend(date: utcDay(2026, 1, 31, 16), amount: 100_000)
        let februarySpend = try BudgetSpend(date: utcDay(2026, 1, 31, 18), amount: 200_000)
        let limit = try BudgetLimit(monthlyLimit: 10_000_000)

        let january = try BudgetMath.evaluate(
            limit: limit, spends: [januarySpend, februarySpend],
            asOf: day(2026, 1, 31, 23, 30), calendar: hcm)
        #expect(january.spent == 100_000)

        let february = try BudgetMath.evaluate(
            limit: limit, spends: [januarySpend, februarySpend],
            asOf: day(2026, 2, 10), calendar: hcm)
        #expect(february.spent == 200_000)
        #expect(february.daysElapsed == 10)
        #expect(february.daysLeft == 18)  // February 2026 has 28 days
    }
}

struct BudgetValidationTests {

    @Test func nonPositiveLimitThrows() {
        #expect(throws: BudgetError.nonPositiveLimit) {
            _ = try BudgetLimit(monthlyLimit: 0)
        }
        #expect(throws: BudgetError.nonPositiveLimit) {
            _ = try BudgetLimit(categoryID: foodID, monthlyLimit: -1)
        }
    }

    @Test func nonPositiveAmountThrows() {
        #expect(throws: BudgetError.nonPositiveAmount) {
            _ = try BudgetSpend(date: day(2026, 1, 5), amount: 0)
        }
        #expect(throws: BudgetError.nonPositiveAmount) {
            _ = try BudgetSpend(categoryID: foodID, date: day(2026, 1, 5), amount: -50)
        }
    }

    @Test func statusRawValues() {
        #expect(BudgetStatus.ok.rawValue == "ok")
        #expect(BudgetStatus.warning.rawValue == "warning")
        #expect(BudgetStatus.exceeded.rawValue == "exceeded")
    }
}

struct BudgetOverflowTests {

    @Test func spentOverflowThrows() throws {
        let limit = try BudgetLimit(monthlyLimit: Int64.max)
        let spends = try [
            BudgetSpend(date: day(2026, 1, 5), amount: Int64.max),
            BudgetSpend(date: day(2026, 1, 6), amount: Int64.max),
        ]
        #expect(throws: BudgetError.overflow) {
            _ = try BudgetMath.evaluate(
                limit: limit, spends: spends,
                asOf: day(2026, 1, 15), calendar: hcm)
        }
    }

    @Test func totalLimitOverflowThrows() throws {
        let limits = [
            try BudgetLimit(monthlyLimit: Int64.max),
            try BudgetLimit(monthlyLimit: Int64.max),
        ]
        #expect(throws: BudgetError.overflow) {
            _ = try BudgetMath.summary(
                limits: limits, spends: [],
                asOf: day(2026, 1, 15), calendar: hcm)
        }
    }
}
