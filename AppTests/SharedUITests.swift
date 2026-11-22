import Testing
import Foundation
@testable import AMFinance

struct SharedUITests {

    private let calendar = AppCalendar.vietnam

    private func date(
        _ year: Int, _ month: Int, _ day: Int,
        _ hour: Int = 12, _ minute: Int = 0
    ) -> Date {
        calendar.date(from: DateComponents(
            year: year, month: month, day: day,
            hour: hour, minute: minute
        ))!
    }

    // MARK: - HexColor

    @Test func hexParsesValidSixDigits() {
        let rgb = HexColor.parse("FF9500")
        #expect(rgb != nil)
        #expect(rgb!.red == 1)
        #expect(abs(rgb!.green - 149.0 / 255.0) < 0.0001)
        #expect(rgb!.blue == 0)
    }

    @Test func hexAcceptsHashAndWhitespace() {
        let rgb = HexColor.parse("  #34c759 ")
        #expect(rgb != nil)
        #expect(abs(rgb!.red - 52.0 / 255.0) < 0.0001)
        #expect(abs(rgb!.green - 199.0 / 255.0) < 0.0001)
        #expect(abs(rgb!.blue - 89.0 / 255.0) < 0.0001)
    }

    @Test func hexRejectsInvalidInput() {
        #expect(HexColor.parse("") == nil)
        #expect(HexColor.parse("FF00") == nil)
        #expect(HexColor.parse("FF9500FF") == nil)
        #expect(HexColor.parse("GGGGGG") == nil)
        #expect(HexColor.parse("#") == nil)
    }

    // MARK: - AppDateFormat

    @Test func dayHeaderTodayYesterdayAndOlder() {
        // Sunday 22/11/2026, 14:05 in Asia/Ho_Chi_Minh.
        let now = date(2026, 11, 22, 14, 5)

        #expect(AppDateFormat.dayHeader(now, now: now, calendar: calendar) == "Hôm nay")
        // Same calendar day, earlier hour is still "Hôm nay".
        #expect(AppDateFormat.dayHeader(
            date(2026, 11, 22, 0, 1), now: now, calendar: calendar) == "Hôm nay")
        #expect(AppDateFormat.dayHeader(
            date(2026, 11, 21), now: now, calendar: calendar) == "Hôm qua")
        // Monday 16/11/2026 falls back to weekday + date.
        #expect(AppDateFormat.dayHeader(
            date(2026, 11, 16), now: now, calendar: calendar) == "Thứ Hai, 16/11/2026")
    }

    @Test func dayHeaderUsesCalendarTimeZone() {
        // A date that is "today" in Asia/Ho_Chi_Minh must not become
        // yesterday when rendered through this calendar.
        let now = date(2026, 11, 22, 23, 55)
        #expect(AppDateFormat.dayHeader(
            date(2026, 11, 22, 23, 50), now: now, calendar: calendar) == "Hôm nay")
    }

    @Test func monthTitleAndShortDateAndTime() {
        let day = date(2026, 11, 22, 14, 5)
        #expect(AppDateFormat.monthTitle(day, calendar: calendar) == "Tháng 11/2026")
        #expect(AppDateFormat.shortDate(day, calendar: calendar) == "22/11")
        #expect(AppDateFormat.time(day, calendar: calendar) == "14:05")
    }

    // MARK: - AmountKeypadState

    @Test func keypadAppendsDigits() {
        var state = AmountKeypadState()
        state.appendDigit(1)
        state.appendDigit(2)
        state.appendDigit(5)
        #expect(state.value == 125)
        // Typing on zero replaces it — "05" is just 5.
        var fresh = AmountKeypadState()
        fresh.appendDigit(0)
        fresh.appendDigit(5)
        #expect(fresh.value == 5)
    }

    @Test func keypadTripleZero() {
        var state = AmountKeypadState()
        state.appendDigit(1)
        state.appendDigit(2)
        state.appendDigit(5)
        state.appendTripleZero()
        #expect(state.value == 125_000)
        state.appendTripleZero()
        #expect(state.value == 125_000_000)
    }

    @Test func keypadTripleZeroOnZeroStaysZero() {
        var state = AmountKeypadState()
        state.appendTripleZero()
        #expect(state.value == 0)
    }

    @Test func keypadBackspaceReachesZero() {
        var state = AmountKeypadState(125)
        state.backspace()
        #expect(state.value == 12)
        state.backspace()
        #expect(state.value == 1)
        state.backspace()
        #expect(state.value == 0)
        state.backspace()
        #expect(state.value == 0)
    }

    @Test func keypadClear() {
        var state = AmountKeypadState(1_250_000)
        state.clear()
        #expect(state.value == 0)
    }

    @Test func keypadMaxDigitsGuard() {
        var state = AmountKeypadState()
        for _ in 0..<AmountKeypadState.maxDigits {
            state.appendDigit(9)
        }
        #expect(state.value == 9_999_999_999_999)
        state.appendDigit(9)
        #expect(state.value == 9_999_999_999_999)
        // "000" is refused too when it would overflow the limit.
        var eleven = AmountKeypadState(9_999_999_999)
        eleven.appendTripleZero()
        #expect(eleven.value == 9_999_999_999_000)
        eleven.appendTripleZero()
        #expect(eleven.value == 9_999_999_999_000)
    }

    @Test func keypadNeverNegative() {
        var state = AmountKeypadState(-500)
        #expect(state.value == 0)
        state.backspace()
        #expect(state.value == 0)
    }

    // MARK: - AppTheme palettes

    @Test func paletteAndSymbolsAreSizedForPickers() {
        #expect(AppTheme.palette.count == 12)
        #expect(AppTheme.symbols.count >= 40)
        #expect(Set(AppTheme.symbols).count == AppTheme.symbols.count)
        #expect(AppTheme.palette.allSatisfy { HexColor.parse($0) != nil })
    }
}
