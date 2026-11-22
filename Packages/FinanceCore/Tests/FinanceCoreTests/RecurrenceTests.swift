import Foundation
import Testing
@testable import FinanceCore

// All helpers are private so nothing collides with other test files.

private let cal: Calendar = {
    var c = Calendar(identifier: .gregorian)
    c.timeZone = TimeZone(identifier: "Asia/Ho_Chi_Minh")!
    return c
}()

/// Start-of-day (or a given time) in the test calendar.
private func ymd(_ year: Int, _ month: Int, _ day: Int,
                 hour: Int = 0, minute: Int = 0) -> Date {
    cal.date(from: DateComponents(year: year, month: month, day: day,
                                  hour: hour, minute: minute))!
}

struct RecurrenceFrequencyTests {
    @Test func rawValues() {
        #expect(RecurrenceFrequency.daily.rawValue == "daily")
        #expect(RecurrenceFrequency.weekly.rawValue == "weekly")
        #expect(RecurrenceFrequency.monthly.rawValue == "monthly")
        #expect(RecurrenceFrequency.yearly.rawValue == "yearly")
        #expect(RecurrenceFrequency.allCases.count == 4)
    }

    @Test func displayNames() {
        #expect(RecurrenceFrequency.daily.displayName == "Hằng ngày")
        #expect(RecurrenceFrequency.weekly.displayName == "Hằng tuần")
        #expect(RecurrenceFrequency.monthly.displayName == "Hằng tháng")
        #expect(RecurrenceFrequency.yearly.displayName == "Hằng năm")
    }
}

struct RecurrenceValidationTests {
    @Test func intervalBelowOneThrows() {
        #expect(throws: RecurrenceError.invalidInterval) {
            _ = try RecurrenceRule(frequency: .daily, interval: 0,
                                   startDate: ymd(2026, 1, 1), calendar: cal)
        }
        #expect(throws: RecurrenceError.invalidInterval) {
            _ = try RecurrenceRule(frequency: .weekly, interval: -2,
                                   startDate: ymd(2026, 1, 1), calendar: cal)
        }
    }

    @Test func endBeforeStartThrows() {
        #expect(throws: RecurrenceError.endBeforeStart) {
            _ = try RecurrenceRule(frequency: .daily,
                                   startDate: ymd(2026, 1, 10),
                                   endDate: ymd(2026, 1, 9),
                                   calendar: cal)
        }
    }

    @Test func endOnStartDayIsAllowed() throws {
        // An earlier same-day instant is still the same calendar day.
        let rule = try RecurrenceRule(frequency: .daily,
                                      startDate: ymd(2026, 1, 10, hour: 15),
                                      endDate: ymd(2026, 1, 10, hour: 8),
                                      calendar: cal)
        #expect(try rule.occurrences(in: ymd(2026, 1, 1)...ymd(2026, 1, 31),
                                     calendar: cal) == [ymd(2026, 1, 10)])
    }

    @Test func zeroMaximumOccurrencesThrows() {
        #expect(throws: RecurrenceError.invalidMaximumOccurrences) {
            _ = try RecurrenceRule(frequency: .daily,
                                   startDate: ymd(2026, 1, 1),
                                   maximumOccurrences: 0, calendar: cal)
        }
    }

    @Test func mutatedRuleIsRevalidated() throws {
        var rule = try RecurrenceRule(frequency: .daily,
                                      startDate: ymd(2026, 1, 1), calendar: cal)
        rule.interval = 0
        #expect(throws: RecurrenceError.invalidInterval) {
            _ = try rule.occurrences(in: ymd(2026, 1, 1)...ymd(2026, 1, 2),
                                     calendar: cal)
        }
        #expect(throws: RecurrenceError.invalidInterval) {
            _ = try rule.nextOccurrence(after: ymd(2026, 1, 1), calendar: cal)
        }
        #expect(throws: RecurrenceError.invalidInterval) {
            _ = try rule.missedOccurrences(after: ymd(2026, 1, 1),
                                         upTo: ymd(2026, 1, 2),
                                         limit: 5, calendar: cal)
        }
        #expect(throws: RecurrenceError.invalidInterval) {
            _ = try rule.index(of: ymd(2026, 1, 1), calendar: cal)
        }
    }
}

struct RecurrenceDailyTests {
    @Test func interval1() throws {
        let rule = try RecurrenceRule(frequency: .daily,
                                      startDate: ymd(2026, 1, 10),
                                      calendar: cal)
        #expect(try rule.occurrences(in: ymd(2026, 1, 10)...ymd(2026, 1, 14),
                                   calendar: cal)
                == [ymd(2026, 1, 10), ymd(2026, 1, 11), ymd(2026, 1, 12),
                    ymd(2026, 1, 13), ymd(2026, 1, 14)])
    }

    @Test func interval3() throws {
        let rule = try RecurrenceRule(frequency: .daily, interval: 3,
                                      startDate: ymd(2026, 1, 10),
                                      calendar: cal)
        #expect(try rule.occurrences(in: ymd(2026, 1, 1)...ymd(2026, 2, 1),
                                   calendar: cal)
                == [ymd(2026, 1, 10), ymd(2026, 1, 13), ymd(2026, 1, 16),
                    ymd(2026, 1, 19), ymd(2026, 1, 22), ymd(2026, 1, 25),
                    ymd(2026, 1, 28), ymd(2026, 1, 31)])
    }

    @Test func rangeEntirelyBeforeStartIsEmpty() throws {
        let rule = try RecurrenceRule(frequency: .daily,
                                      startDate: ymd(2026, 1, 10),
                                      calendar: cal)
        #expect(try rule.occurrences(in: ymd(2026, 1, 1)...ymd(2026, 1, 9),
                                   calendar: cal) == [])
    }
}

struct RecurrenceWeeklyTests {
    @Test func interval1() throws {
        // Monday Jan 5 2026.
        let rule = try RecurrenceRule(frequency: .weekly,
                                      startDate: ymd(2026, 1, 5),
                                      calendar: cal)
        #expect(try rule.occurrences(in: ymd(2026, 1, 1)...ymd(2026, 1, 31),
                                   calendar: cal)
                == [ymd(2026, 1, 5), ymd(2026, 1, 12), ymd(2026, 1, 19),
                    ymd(2026, 1, 26)])
    }

    @Test func interval2() throws {
        let rule = try RecurrenceRule(frequency: .weekly, interval: 2,
                                      startDate: ymd(2026, 1, 5),
                                      calendar: cal)
        #expect(try rule.occurrences(in: ymd(2026, 1, 1)...ymd(2026, 2, 28),
                                   calendar: cal)
                == [ymd(2026, 1, 5), ymd(2026, 1, 19), ymd(2026, 2, 2),
                    ymd(2026, 2, 16)])
    }
}

struct RecurrenceMonthlyTests {
    @Test func interval1() throws {
        let rule = try RecurrenceRule(frequency: .monthly,
                                      startDate: ymd(2026, 1, 15),
                                      calendar: cal)
        #expect(try rule.occurrences(in: ymd(2026, 1, 1)...ymd(2026, 5, 31),
                                   calendar: cal)
                == [ymd(2026, 1, 15), ymd(2026, 2, 15), ymd(2026, 3, 15),
                    ymd(2026, 4, 15), ymd(2026, 5, 15)])
    }

    @Test func interval3() throws {
        let rule = try RecurrenceRule(frequency: .monthly, interval: 3,
                                      startDate: ymd(2026, 1, 15),
                                      calendar: cal)
        #expect(try rule.occurrences(in: ymd(2026, 1, 1)...ymd(2027, 1, 31),
                                   calendar: cal)
                == [ymd(2026, 1, 15), ymd(2026, 4, 15), ymd(2026, 7, 15),
                    ymd(2026, 10, 15), ymd(2027, 1, 15)])
    }

    @Test func day31ClampsWithoutDriftAcrossLeapYear() throws {
        let rule = try RecurrenceRule(frequency: .monthly,
                                      startDate: ymd(2024, 1, 31),
                                      calendar: cal)
        #expect(try rule.occurrences(in: ymd(2024, 1, 1)...ymd(2025, 4, 30),
                                   calendar: cal)
                == [ymd(2024, 1, 31), ymd(2024, 2, 29),  // 2024 is a leap year
                    ymd(2024, 3, 31),  // no drift back to Mar 29
                    ymd(2024, 4, 30), ymd(2024, 5, 31), ymd(2024, 6, 30),
                    ymd(2024, 7, 31), ymd(2024, 8, 31), ymd(2024, 9, 30),
                    ymd(2024, 10, 31), ymd(2024, 11, 30), ymd(2024, 12, 31),
                    ymd(2025, 1, 31), ymd(2025, 2, 28),
                    ymd(2025, 3, 31), ymd(2025, 4, 30)])
    }

    @Test func interval2WithClamp() throws {
        // Every two months from Jan 31: Mar 31, May 31, Jul 31, Sep 30…
        let rule = try RecurrenceRule(frequency: .monthly, interval: 2,
                                      startDate: ymd(2026, 1, 31),
                                      calendar: cal)
        #expect(try rule.occurrences(in: ymd(2026, 1, 1)...ymd(2026, 11, 30),
                                   calendar: cal)
                == [ymd(2026, 1, 31), ymd(2026, 3, 31), ymd(2026, 5, 31),
                    ymd(2026, 7, 31), ymd(2026, 9, 30), ymd(2026, 11, 30)])
    }

    @Test func day30InFebruary() throws {
        let rule = try RecurrenceRule(frequency: .monthly,
                                      startDate: ymd(2025, 1, 30),
                                      calendar: cal)
        #expect(try rule.occurrences(in: ymd(2025, 1, 1)...ymd(2025, 4, 30),
                                   calendar: cal)
                == [ymd(2025, 1, 30), ymd(2025, 2, 28), ymd(2025, 3, 30),
                    ymd(2025, 4, 30)])
    }
}

struct RecurrenceYearlyTests {
    @Test func interval1() throws {
        let rule = try RecurrenceRule(frequency: .yearly,
                                      startDate: ymd(2026, 3, 5),
                                      calendar: cal)
        #expect(try rule.occurrences(in: ymd(2026, 1, 1)...ymd(2029, 12, 31),
                                   calendar: cal)
                == [ymd(2026, 3, 5), ymd(2027, 3, 5), ymd(2028, 3, 5),
                    ymd(2029, 3, 5)])
    }

    @Test func interval5() throws {
        let rule = try RecurrenceRule(frequency: .yearly, interval: 5,
                                      startDate: ymd(2026, 3, 5),
                                      calendar: cal)
        #expect(try rule.occurrences(in: ymd(2026, 1, 1)...ymd(2040, 12, 31),
                                   calendar: cal)
                == [ymd(2026, 3, 5), ymd(2031, 3, 5), ymd(2036, 3, 5)])
    }

    @Test func february29ClampsTo28InCommonYears() throws {
        let rule = try RecurrenceRule(frequency: .yearly,
                                      startDate: ymd(2024, 2, 29),
                                      calendar: cal)
        #expect(try rule.occurrences(in: ymd(2024, 1, 1)...ymd(2029, 12, 31),
                                   calendar: cal)
                == [ymd(2024, 2, 29), ymd(2025, 2, 28), ymd(2026, 2, 28),
                    ymd(2027, 2, 28), ymd(2028, 2, 29), ymd(2029, 2, 28)])
    }
}

struct RecurrenceBoundsTests {
    @Test func endDateIsInclusive() throws {
        let rule = try RecurrenceRule(frequency: .monthly,
                                      startDate: ymd(2026, 1, 15),
                                      endDate: ymd(2026, 4, 15),
                                      calendar: cal)
        #expect(try rule.occurrences(in: ymd(2026, 1, 1)...ymd(2026, 12, 31),
                                   calendar: cal)
                == [ymd(2026, 1, 15), ymd(2026, 2, 15), ymd(2026, 3, 15),
                    ymd(2026, 4, 15)])
        #expect(try rule.index(of: ymd(2026, 4, 15), calendar: cal) == 3)
        #expect(try rule.nextOccurrence(after: ymd(2026, 4, 15),
                                      calendar: cal) == nil)
    }

    @Test func endDateCutsMidDay() throws {
        // The end instant lands inside Apr 15 — its day still counts.
        let rule = try RecurrenceRule(frequency: .monthly,
                                      startDate: ymd(2026, 1, 15),
                                      endDate: ymd(2026, 4, 15, hour: 8),
                                      calendar: cal)
        #expect(try rule.occurrences(in: ymd(2026, 1, 1)...ymd(2026, 12, 31),
                                   calendar: cal).last == ymd(2026, 4, 15))
    }

    @Test func maximumOccurrences() throws {
        let rule = try RecurrenceRule(frequency: .monthly,
                                      startDate: ymd(2026, 1, 15),
                                      maximumOccurrences: 3, calendar: cal)
        #expect(try rule.occurrences(in: ymd(2026, 1, 1)...ymd(2026, 12, 31),
                                   calendar: cal)
                == [ymd(2026, 1, 15), ymd(2026, 2, 15), ymd(2026, 3, 15)])
        // Aligned but past the cap is not an occurrence.
        #expect(try rule.index(of: ymd(2026, 4, 15), calendar: cal) == nil)
        #expect(try rule.nextOccurrence(after: ymd(2026, 3, 15),
                                      calendar: cal) == nil)
    }

    @Test func endDateAndMaximumOccurrencesTogether() throws {
        // Whichever limit hits first wins — here the count.
        let rule = try RecurrenceRule(frequency: .weekly,
                                      startDate: ymd(2026, 1, 5),
                                      endDate: ymd(2026, 6, 30),
                                      maximumOccurrences: 2, calendar: cal)
        #expect(try rule.occurrences(in: ymd(2026, 1, 1)...ymd(2026, 12, 31),
                                   calendar: cal)
                == [ymd(2026, 1, 5), ymd(2026, 1, 12)])
    }

    @Test func rangeStartingBeforeRuleStart() throws {
        let rule = try RecurrenceRule(frequency: .weekly,
                                      startDate: ymd(2026, 1, 15),
                                      calendar: cal)
        #expect(try rule.occurrences(in: ymd(2025, 12, 1)...ymd(2026, 2, 28),
                                   calendar: cal)
                == [ymd(2026, 1, 15), ymd(2026, 1, 22), ymd(2026, 1, 29),
                    ymd(2026, 2, 5), ymd(2026, 2, 12), ymd(2026, 2, 19),
                    ymd(2026, 2, 26)])
    }
}

struct RecurrenceNextAndIndexTests {
    @Test func nextOccurrenceIsStrictlyAfter() throws {
        let rule = try RecurrenceRule(frequency: .monthly,
                                      startDate: ymd(2026, 1, 15),
                                      calendar: cal)
        // Same calendar day does not count, even early in the day.
        #expect(try rule.nextOccurrence(after: ymd(2026, 1, 15),
                                      calendar: cal) == ymd(2026, 2, 15))
        #expect(try rule.nextOccurrence(after: ymd(2026, 1, 15, hour: 0, minute: 1),
                                      calendar: cal) == ymd(2026, 2, 15))
        #expect(try rule.nextOccurrence(after: ymd(2026, 1, 14, hour: 23, minute: 59),
                                      calendar: cal) == ymd(2026, 1, 15))
        // Before the rule starts, the first occurrence is next.
        #expect(try rule.nextOccurrence(after: ymd(2025, 12, 1),
                                      calendar: cal) == ymd(2026, 1, 15))
    }

    @Test func nextOccurrenceThroughClampedMonth() throws {
        let rule = try RecurrenceRule(frequency: .monthly,
                                      startDate: ymd(2025, 1, 31),
                                      calendar: cal)
        #expect(try rule.nextOccurrence(after: ymd(2025, 1, 31),
                                      calendar: cal) == ymd(2025, 2, 28))
        #expect(try rule.nextOccurrence(after: ymd(2025, 2, 28),
                                      calendar: cal) == ymd(2025, 3, 31))
    }

    @Test func indexOfOccurrence() throws {
        let rule = try RecurrenceRule(frequency: .monthly,
                                      startDate: ymd(2025, 1, 31),
                                      calendar: cal)
        #expect(try rule.index(of: ymd(2025, 1, 31), calendar: cal) == 0)
        // The clamped February occurrence is index 1.
        #expect(try rule.index(of: ymd(2025, 2, 28), calendar: cal) == 1)
        #expect(try rule.index(of: ymd(2025, 3, 31), calendar: cal) == 2)
        // Any time of day on the occurrence day resolves.
        #expect(try rule.index(of: ymd(2025, 4, 30, hour: 23, minute: 30),
                             calendar: cal) == 3)
        // Not an occurrence.
        #expect(try rule.index(of: ymd(2025, 3, 30), calendar: cal) == nil)
        #expect(try rule.index(of: ymd(2025, 2, 27), calendar: cal) == nil)
        #expect(try rule.index(of: ymd(2024, 1, 31), calendar: cal) == nil)
    }
}

struct RecurrenceMissedTests {
    @Test func missedSinceLastGenerated() throws {
        let rule = try RecurrenceRule(frequency: .monthly,
                                      startDate: ymd(2026, 1, 15),
                                      calendar: cal)
        #expect(try rule.missedOccurrences(after: ymd(2026, 2, 10),
                                         upTo: ymd(2026, 4, 20),
                                         limit: 10, calendar: cal)
                == [ymd(2026, 2, 15), ymd(2026, 3, 15), ymd(2026, 4, 15)])
    }

    @Test func lastGeneratedDayItselfIsNotMissed() throws {
        let rule = try RecurrenceRule(frequency: .monthly,
                                      startDate: ymd(2026, 1, 15),
                                      calendar: cal)
        // An occurrence dated the same day as `lastGenerated` was
        // already created; only later days count.
        #expect(try rule.missedOccurrences(after: ymd(2026, 2, 15),
                                         upTo: ymd(2026, 3, 14),
                                         limit: 10, calendar: cal) == [])
        #expect(try rule.missedOccurrences(after: ymd(2026, 2, 15),
                                         upTo: ymd(2026, 3, 15),
                                         limit: 10, calendar: cal)
                == [ymd(2026, 3, 15)])
    }

    @Test func nothingDue() throws {
        let rule = try RecurrenceRule(frequency: .monthly,
                                      startDate: ymd(2026, 1, 15),
                                      calendar: cal)
        // Window between two occurrences.
        #expect(try rule.missedOccurrences(after: ymd(2026, 1, 20),
                                         upTo: ymd(2026, 2, 10),
                                         limit: 10, calendar: cal) == [])
        // `now` before `lastGenerated`.
        #expect(try rule.missedOccurrences(after: ymd(2026, 2, 20),
                                         upTo: ymd(2026, 2, 10),
                                         limit: 10, calendar: cal) == [])
        // Zero limit.
        #expect(try rule.missedOccurrences(after: ymd(2026, 1, 1),
                                         upTo: ymd(2026, 3, 1),
                                         limit: 0, calendar: cal) == [])
        // Rule has not started yet.
        #expect(try rule.missedOccurrences(after: ymd(2025, 1, 1),
                                         upTo: ymd(2026, 1, 10),
                                         limit: 10, calendar: cal) == [])
        // Rule already ended.
        let ended = try RecurrenceRule(frequency: .monthly,
                                       startDate: ymd(2026, 1, 15),
                                       endDate: ymd(2026, 2, 15),
                                       calendar: cal)
        #expect(try ended.missedOccurrences(after: ymd(2026, 2, 15),
                                          upTo: ymd(2026, 12, 31),
                                          limit: 10, calendar: cal) == [])
    }

    @Test func manyMissedPeriodsHitSafetyLimit() throws {
        let rule = try RecurrenceRule(frequency: .daily,
                                      startDate: ymd(2026, 1, 1),
                                      calendar: cal)
        // 59 days missed; the cap returns the earliest ones in order.
        #expect(try rule.missedOccurrences(after: ymd(2026, 1, 1),
                                         upTo: ymd(2026, 3, 1),
                                         limit: 5, calendar: cal)
                == [ymd(2026, 1, 2), ymd(2026, 1, 3), ymd(2026, 1, 4),
                    ymd(2026, 1, 5), ymd(2026, 1, 6)])
    }

    @Test func missedOccurrencesRespectsRuleEnd() throws {
        let rule = try RecurrenceRule(frequency: .daily,
                                      startDate: ymd(2026, 1, 1),
                                      maximumOccurrences: 3, calendar: cal)
        #expect(try rule.missedOccurrences(after: ymd(2025, 12, 31),
                                         upTo: ymd(2026, 2, 1),
                                         limit: 10, calendar: cal)
                == [ymd(2026, 1, 1), ymd(2026, 1, 2), ymd(2026, 1, 3)])
    }
}

struct RecurrenceTimeZoneTests {
    private var utc: Calendar {
        var c = Calendar(identifier: .gregorian)
        c.timeZone = TimeZone(identifier: "UTC")!
        return c
    }

    @Test func hoChiMinhDayBoundary() throws {
        // 16:30 UTC = 23:30 the same day in Asia/Ho_Chi_Minh;
        // 17:30 UTC = 00:30 the NEXT day.
        let lateNight = utc.date(from: DateComponents(
            year: 2026, month: 1, day: 5, hour: 16, minute: 30))!
        let pastMidnight = utc.date(from: DateComponents(
            year: 2026, month: 1, day: 5, hour: 17, minute: 30))!
        #expect(pastMidnight == ymd(2026, 1, 6, hour: 0, minute: 30))

        let rule = try RecurrenceRule(frequency: .daily,
                                      startDate: ymd(2026, 1, 6),
                                      calendar: cal)
        // The instant belongs to Jan 6 in HCM — it is the first
        // occurrence's day.
        #expect(try rule.index(of: pastMidnight, calendar: cal) == 0)
        // Still Jan 5 in HCM: not an occurrence, and the rule's first
        // occurrence is next.
        #expect(try rule.index(of: lateNight, calendar: cal) == nil)
        #expect(try rule.nextOccurrence(after: lateNight, calendar: cal)
                == ymd(2026, 1, 6))
        // A range ending at an instant inside Jan 6 HCM includes the
        // Jan 6 occurrence; one ending 23:59 HCM on Jan 5 does not.
        #expect(try rule.occurrences(in: ymd(2026, 1, 1)...pastMidnight,
                                   calendar: cal) == [ymd(2026, 1, 6)])
        #expect(try rule.occurrences(in: ymd(2026, 1, 1)...lateNight,
                                   calendar: cal) == [])
        // An occurrence on `now`'s own day counts as due.
        #expect(try rule.missedOccurrences(after: ymd(2026, 1, 1),
                                         upTo: pastMidnight,
                                         limit: 10, calendar: cal)
                == [ymd(2026, 1, 6)])
    }
}

struct RecurrenceSummaryTests {
    @Test func summaries() throws {
        #expect(try RecurrenceRule(frequency: .daily,
                                   startDate: ymd(2026, 1, 5),
                                   calendar: cal)
                .summary(calendar: cal) == "Hằng ngày")
        #expect(try RecurrenceRule(frequency: .daily, interval: 3,
                                   startDate: ymd(2026, 1, 5),
                                   calendar: cal)
                .summary(calendar: cal) == "Mỗi 3 ngày")
        #expect(try RecurrenceRule(frequency: .weekly,
                                   startDate: ymd(2026, 1, 5),
                                   calendar: cal)
                .summary(calendar: cal) == "Hằng tuần")
        #expect(try RecurrenceRule(frequency: .weekly, interval: 2,
                                   startDate: ymd(2026, 1, 5),
                                   calendar: cal)
                .summary(calendar: cal) == "Mỗi 2 tuần")
        #expect(try RecurrenceRule(frequency: .monthly,
                                   startDate: ymd(2026, 1, 5),
                                   calendar: cal)
                .summary(calendar: cal) == "Hằng tháng, ngày 5")
        #expect(try RecurrenceRule(frequency: .monthly, interval: 2,
                                   startDate: ymd(2026, 1, 15),
                                   calendar: cal)
                .summary(calendar: cal) == "Mỗi 2 tháng, ngày 15")
        #expect(try RecurrenceRule(frequency: .monthly,
                                   startDate: ymd(2026, 1, 31),
                                   calendar: cal)
                .summary(calendar: cal) == "Hằng tháng, ngày 31")
        #expect(try RecurrenceRule(frequency: .yearly,
                                   startDate: ymd(2026, 3, 5),
                                   calendar: cal)
                .summary(calendar: cal) == "Hằng năm, ngày 5 tháng 3")
        #expect(try RecurrenceRule(frequency: .yearly, interval: 2,
                                   startDate: ymd(2024, 2, 29),
                                   calendar: cal)
                .summary(calendar: cal) == "Mỗi 2 năm, ngày 29 tháng 2")
    }
}
