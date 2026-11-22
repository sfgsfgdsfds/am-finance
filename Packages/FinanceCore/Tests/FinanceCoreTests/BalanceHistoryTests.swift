import Foundation
import Testing
@testable import FinanceCore

private let hcm: Calendar = {
    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = TimeZone(identifier: "Asia/Ho_Chi_Minh")!
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

struct BalanceHistorySeriesTests {

    @Test func emptyInputProducesEmptySeries() throws {
        #expect(try BalanceHistory.series(entries: [], openingBalance: 500_000).isEmpty)
        #expect(try BalanceHistory.series(
            entries: [],
            anchor: BalanceHistoryAnchor(date: day(2026, 1, 1), balance: 1)
        ).isEmpty)
    }

    @Test func singleEntry() throws {
        let points = try BalanceHistory.series(
            entries: [BalanceHistoryEntry(date: day(2026, 1, 10, 9), delta: 250_000)],
            openingBalance: 1_000_000
        )
        #expect(points == [BalanceHistoryPoint(date: day(2026, 1, 10, 9), balance: 1_250_000)])
    }

    @Test func unorderedInputIsSortedStably() throws {
        let d1 = day(2026, 1, 1)
        let d2 = day(2026, 1, 2)
        let d3 = day(2026, 1, 3)
        let points = try BalanceHistory.series(
            entries: [
                BalanceHistoryEntry(date: d3, delta: 30),
                BalanceHistoryEntry(date: d1, delta: 100),
                BalanceHistoryEntry(date: d2, delta: -50),
            ],
            openingBalance: 0
        )
        #expect(points.map(\.date) == [d1, d2, d3])
        #expect(points.map(\.balance) == [100, 50, 80])
    }

    @Test func sameTimestampKeepsInputOrder() throws {
        let d = day(2026, 1, 5, 12)
        let points = try BalanceHistory.series(
            entries: [
                BalanceHistoryEntry(date: d, delta: 100),
                BalanceHistoryEntry(date: d, delta: -30),
            ],
            openingBalance: 1_000
        )
        // Unstable order would give 970 then 1070.
        #expect(points.map(\.balance) == [1_100, 1_070])
    }
}

struct BalanceHistoryAnchorTests {
    // Entries: Jan 1 +100, Jan 2 -50, Jan 3 +200, Jan 5 -30.
    private var entries: [BalanceHistoryEntry] {
        [
            BalanceHistoryEntry(date: day(2026, 1, 1), delta: 100),
            BalanceHistoryEntry(date: day(2026, 1, 2), delta: -50),
            BalanceHistoryEntry(date: day(2026, 1, 3), delta: 200),
            BalanceHistoryEntry(date: day(2026, 1, 5), delta: -30),
        ]
    }

    @Test func anchorInTheMiddle() throws {
        // Anchor after the Jan 3 entry: balance 1000 includes +100 -50 +200.
        let points = try BalanceHistory.series(
            entries: entries,
            anchor: BalanceHistoryAnchor(date: day(2026, 1, 3, 12), balance: 1_000)
        )
        #expect(points.map(\.balance) == [850, 800, 1_000, 970])
    }

    @Test func anchorBeforeAllEntries() throws {
        let points = try BalanceHistory.series(
            entries: entries,
            anchor: BalanceHistoryAnchor(date: day(2025, 12, 31), balance: 1_000)
        )
        #expect(points.map(\.balance) == [1_100, 1_050, 1_250, 1_220])
    }

    @Test func anchorAfterAllEntries() throws {
        let points = try BalanceHistory.series(
            entries: entries,
            anchor: BalanceHistoryAnchor(date: day(2026, 1, 10), balance: 1_220)
        )
        #expect(points.map(\.balance) == [1_100, 1_050, 1_250, 1_220])
    }

    @Test func entryAtExactlyTheAnchorInstant() throws {
        // The -50 at Jan 2 00:00 is already inside the anchor balance.
        let points = try BalanceHistory.series(
            entries: [
                BalanceHistoryEntry(date: day(2026, 1, 1), delta: 100),
                BalanceHistoryEntry(date: day(2026, 1, 2), delta: -50),
                BalanceHistoryEntry(date: day(2026, 1, 3), delta: 200),
            ],
            anchor: BalanceHistoryAnchor(date: day(2026, 1, 2), balance: 1_050)
        )
        #expect(points.map(\.balance) == [1_100, 1_050, 1_250])
    }

    @Test func anchorOnLastEntryMatchesOpeningMode() throws {
        let entries = [
            BalanceHistoryEntry(date: day(2026, 1, 1), delta: 100),
            BalanceHistoryEntry(date: day(2026, 1, 2), delta: -50),
            BalanceHistoryEntry(date: day(2026, 1, 3), delta: 200),
        ]
        let openingMode = try BalanceHistory.series(entries: entries, openingBalance: 1_000)
        let anchorMode = try BalanceHistory.series(
            entries: entries,
            anchor: BalanceHistoryAnchor(date: day(2026, 1, 3), balance: 1_250)
        )
        #expect(anchorMode == openingMode)
    }
}

struct BalanceHistoryDailyTests {

    @Test func closingBalancesAndGaps() throws {
        let points = try BalanceHistory.dailyBalances(
            entries: [
                BalanceHistoryEntry(date: day(2026, 1, 10, 10), delta: 1_000_000),
                BalanceHistoryEntry(date: day(2026, 1, 10, 15), delta: -200_000),
                BalanceHistoryEntry(date: day(2026, 1, 13, 9), delta: 500_000),
            ],
            from: day(2026, 1, 9),
            to: day(2026, 1, 14),
            basis: .opening(2_000_000),
            calendar: hcm
        )
        #expect(points.count == 6)
        #expect(points.map(\.date) == (9...14).map { day(2026, 1, $0) })
        #expect(points.map(\.balance) == [
            2_000_000,  // Jan 9  — before the first entry: opening
            2_800_000,  // Jan 10 — both entries of the day applied
            2_800_000,  // Jan 11 — carried forward
            2_800_000,  // Jan 12 — carried forward
            3_300_000,  // Jan 13
            3_300_000,  // Jan 14 — carried forward
        ])
    }

    @Test func localDayBoundaryInHoChiMinh() throws {
        let points = try BalanceHistory.dailyBalances(
            entries: [
                BalanceHistoryEntry(date: day(2026, 1, 10, 23, 59, 59), delta: 100),
                BalanceHistoryEntry(date: day(2026, 1, 11, 0, 0, 0), delta: 200),
            ],
            from: day(2026, 1, 10),
            to: day(2026, 1, 11),
            basis: .opening(1_000),
            calendar: hcm
        )
        // 23:59:59 still belongs to Jan 10 local; 00:00:00 opens Jan 11.
        #expect(points.map(\.balance) == [1_100, 1_300])
    }

    @Test func daysBeforeFirstEntryUseDerivedValue() throws {
        // Anchor after the range: everything is derived backwards.
        let points = try BalanceHistory.dailyBalances(
            entries: [BalanceHistoryEntry(date: day(2026, 1, 15), delta: 300)],
            from: day(2026, 1, 10),
            to: day(2026, 1, 16),
            basis: .anchor(BalanceHistoryAnchor(date: day(2026, 1, 20), balance: 5_000)),
            calendar: hcm
        )
        #expect(points.map(\.balance) == [4_700, 4_700, 4_700, 4_700, 4_700, 5_000, 5_000])
    }

    @Test func rangeExpandsToWholeDays() throws {
        // start/end mid-day still produce whole-day closes.
        let points = try BalanceHistory.dailyBalances(
            entries: [BalanceHistoryEntry(date: day(2026, 1, 10, 22), delta: 50)],
            from: day(2026, 1, 10, 15),
            to: day(2026, 1, 11, 8),
            basis: .opening(0),
            calendar: hcm
        )
        #expect(points.map(\.date) == [day(2026, 1, 10), day(2026, 1, 11)])
        #expect(points.map(\.balance) == [50, 50])
    }

    @Test func reversedRangeThrows() throws {
        #expect(throws: BalanceHistoryError.invalidRange) {
            try BalanceHistory.dailyBalances(
                entries: [],
                from: day(2026, 1, 10),
                to: day(2026, 1, 9),
                basis: .opening(0),
                calendar: hcm
            )
        }
    }
}

struct BalanceHistorySummaryTests {

    @Test func summaryNumbers() throws {
        let start = day(2026, 1, 3)
        let end = day(2026, 1, 5, 23, 59)
        let summary = try BalanceHistory.summary(
            entries: [
                BalanceHistoryEntry(date: day(2026, 1, 2), delta: 500),
                BalanceHistoryEntry(date: day(2026, 1, 3, 10), delta: -200),
                BalanceHistoryEntry(date: day(2026, 1, 4), delta: -50),
                BalanceHistoryEntry(date: day(2026, 1, 6), delta: 1_000),
            ],
            from: start,
            to: end,
            basis: .opening(300)
        )
        #expect(summary.opening == 800)
        #expect(summary.closing == 550)
        #expect(summary.totalIn == 0)
        #expect(summary.totalOut == 250)
        #expect(summary.netChange == -250)
        #expect(summary.minimum == BalanceHistoryPoint(date: day(2026, 1, 4), balance: 550))
        #expect(summary.maximum == BalanceHistoryPoint(date: start, balance: 800))
    }

    @Test func rangeBoundariesAreInclusive() throws {
        let start = day(2026, 3, 1, 8)
        let end = day(2026, 3, 5, 20)
        let summary = try BalanceHistory.summary(
            entries: [
                BalanceHistoryEntry(date: start, delta: 100),
                BalanceHistoryEntry(date: end, delta: -40),
                BalanceHistoryEntry(date: day(2026, 3, 6), delta: 999),
            ],
            from: start,
            to: end,
            basis: .opening(0)
        )
        #expect(summary.opening == 0)
        #expect(summary.closing == 60)
        #expect(summary.totalIn == 100)
        #expect(summary.totalOut == 40)
        #expect(summary.netChange == 60)
    }

    @Test func emptyRangeKeepsOpening() throws {
        let start = day(2026, 4, 1)
        let summary = try BalanceHistory.summary(
            entries: [BalanceHistoryEntry(date: day(2026, 4, 10), delta: 500)],
            from: start,
            to: day(2026, 4, 5),
            basis: .opening(700)
        )
        #expect(summary.opening == 700)
        #expect(summary.closing == 700)
        #expect(summary.totalIn == 0)
        #expect(summary.totalOut == 0)
        #expect(summary.netChange == 0)
        #expect(summary.minimum == BalanceHistoryPoint(date: start, balance: 700))
        #expect(summary.maximum == BalanceHistoryPoint(date: start, balance: 700))
    }

    @Test func summaryWithAnchorBasis() throws {
        // Anchor 1000 at Jan 10 includes the Jan 2 +500 and Jan 8 +300.
        let summary = try BalanceHistory.summary(
            entries: [
                BalanceHistoryEntry(date: day(2026, 1, 2), delta: 500),
                BalanceHistoryEntry(date: day(2026, 1, 8), delta: 300),
                BalanceHistoryEntry(date: day(2026, 1, 12), delta: -100),
            ],
            from: day(2026, 1, 10),
            to: day(2026, 1, 15),
            basis: .anchor(BalanceHistoryAnchor(date: day(2026, 1, 10, 12), balance: 1_000))
        )
        #expect(summary.opening == 1_000)
        #expect(summary.closing == 900)
        #expect(summary.netChange == -100)
    }

    @Test func reversedRangeThrows() throws {
        #expect(throws: BalanceHistoryError.invalidRange) {
            try BalanceHistory.summary(
                entries: [],
                from: day(2026, 1, 10),
                to: day(2026, 1, 9),
                basis: .opening(0)
            )
        }
    }
}

struct BalanceHistoryDownsampleTests {
    private func points(_ balances: [Int64]) -> [BalanceHistoryPoint] {
        balances.enumerated().map {
            BalanceHistoryPoint(date: day(2026, 1, 1).addingTimeInterval(TimeInterval($0.offset * 3600)), balance: $0.element)
        }
    }

    @Test func keepsFirstLastMinAndMax() {
        let input = points([5, 1, 2, 3, 9, 2, 2, 2, 2, 8])
        let result = BalanceHistory.downsample(input, maxCount: 5)
        #expect(result.count == 5)
        #expect(result.first == input.first)
        #expect(result.last == input.last)
        #expect(result.contains(BalanceHistoryPoint(date: input[1].date, balance: 1)))
        #expect(result.contains(BalanceHistoryPoint(date: input[4].date, balance: 9)))
        // Chronological order preserved (indices 0, 1, 2, 4, 9).
        #expect(result.map(\.balance) == [5, 1, 2, 9, 8])
    }

    @Test func smallInputReturnedUnchanged() {
        let input = points([3, 1, 4])
        #expect(BalanceHistory.downsample(input, maxCount: 10) == input)
        #expect(BalanceHistory.downsample(input, maxCount: 3) == input)
    }

    @Test func zeroAndTinyBudgets() {
        let input = points([3, 1, 4, 1, 5])
        #expect(BalanceHistory.downsample(input, maxCount: 0).isEmpty)
        #expect(BalanceHistory.downsample(input, maxCount: -2).isEmpty)
        // maxCount 1 keeps the first point (highest priority).
        #expect(BalanceHistory.downsample(input, maxCount: 1) == [input[0]])
        // maxCount 2 keeps first and last.
        #expect(BalanceHistory.downsample(input, maxCount: 2) == [input[0], input[4]])
    }

    @Test func extremesOnTheEnds() {
        // Min is the first point, max is the last: the budget goes to fill.
        let input = points([1, 5, 5, 5, 5, 5, 5, 9])
        let result = BalanceHistory.downsample(input, maxCount: 4)
        #expect(result.count == 4)
        #expect(result.first == input.first)
        #expect(result.last == input.last)
    }
}

struct BalanceHistoryReconcileTests {

    @Test func reconcileSign() throws {
        // App shows more than the bank: need a negative adjustment.
        let overstated = try BalanceHistory.reconcile(computed: 1_200_000, reported: 1_000_000)
        #expect(overstated.difference == 200_000)
        #expect(overstated.adjustmentDelta == -200_000)

        // App shows less than the bank: need a positive adjustment.
        let understated = try BalanceHistory.reconcile(computed: 1_000_000, reported: 1_200_000)
        #expect(understated.difference == -200_000)
        #expect(understated.adjustmentDelta == 200_000)

        let matched = try BalanceHistory.reconcile(computed: 500, reported: 500)
        #expect(matched.difference == 0)
        #expect(matched.adjustmentDelta == 0)
    }
}

struct BalanceHistoryErrorTests {

    @Test func runningBalanceOverflowThrows() throws {
        #expect(throws: BalanceHistoryError.overflow) {
            try BalanceHistory.series(
                entries: [BalanceHistoryEntry(date: day(2026, 1, 1), delta: 1)],
                openingBalance: Int64.max
            )
        }
        #expect(throws: BalanceHistoryError.overflow) {
            try BalanceHistory.series(
                entries: [BalanceHistoryEntry(date: day(2026, 1, 1), delta: -1)],
                openingBalance: Int64.min
            )
        }
    }

    @Test func anchorBackDerivationOverflowThrows() throws {
        // Int64.min - 1 cannot be represented.
        #expect(throws: BalanceHistoryError.overflow) {
            try BalanceHistory.series(
                entries: [BalanceHistoryEntry(date: day(2026, 1, 1), delta: 1)],
                anchor: BalanceHistoryAnchor(date: day(2026, 1, 1), balance: Int64.min)
            )
        }
    }

    @Test func summaryTotalOverflowThrows() throws {
        #expect(throws: BalanceHistoryError.overflow) {
            try BalanceHistory.summary(
                entries: [
                    BalanceHistoryEntry(date: day(2026, 1, 2), delta: Int64.max),
                    BalanceHistoryEntry(date: day(2026, 1, 3), delta: Int64.max),
                ],
                from: day(2026, 1, 1),
                to: day(2026, 1, 31),
                basis: .opening(0)
            )
        }
    }

    @Test func reconcileOverflowThrows() throws {
        #expect(throws: BalanceHistoryError.overflow) {
            try BalanceHistory.reconcile(computed: Int64.min, reported: 1)
        }
    }
}
