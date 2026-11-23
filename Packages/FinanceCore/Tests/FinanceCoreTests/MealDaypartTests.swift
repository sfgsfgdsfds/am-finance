import Testing
@testable import FinanceCore

/// `MealDaypart`'s non-overlapping daypart buckets — 05–10 sáng,
/// 11–13 trưa, 14–17 chiều, 18–22 tối — and the neutral 23:00–04:59
/// stretch.
struct MealDaypartTests {
    @Test func bucketsMeetButNeverOverlap() {
        // Every wall-clock hour maps to exactly one bucket or neutral.
        let expected: [MealDaypart?] = [
            nil, nil, nil, nil, nil,                  // 00–04 neutral
            .sang, .sang, .sang, .sang, .sang, .sang, // 05–10
            .trua, .trua, .trua,                      // 11–13
            .chieu, .chieu, .chieu, .chieu,           // 14–17
            .toi, .toi, .toi, .toi, .toi,             // 18–22
            nil,                                      // 23 neutral
        ]
        #expect(expected.count == 24)
        for (hour, bucket) in expected.enumerated() {
            #expect(MealDaypart.at(hour: hour) == bucket)
        }
    }

    @Test func lateNightStretchStaysNeutral() {
        // 23:00–04:59 carries no meal guess, including around midnight.
        for hour in [23, 0, 1, 2, 3, 4] {
            #expect(MealDaypart.at(hour: hour) == nil)
        }
    }

    @Test func outOfRangeHoursStayNeutral() {
        #expect(MealDaypart.at(hour: -1) == nil)
        #expect(MealDaypart.at(hour: 24) == nil)
    }
}
