import Testing
@testable import FinanceCore

struct VNDFormatTests {
    @Test func zeroAndSmallAmounts() {
        #expect(VND.format(0) == "0 ₫")
        #expect(VND.format(999) == "999 ₫")
        #expect(VND.format(1_000) == "1.000 ₫")
    }

    @Test func thousandsGrouping() {
        #expect(VND.format(1_250_000) == "1.250.000 ₫")
        #expect(VND.format(1_000_000_000) == "1.000.000.000 ₫")
        #expect(VND.format(12_345_678_901) == "12.345.678.901 ₫")
    }

    @Test func negativeAmounts() {
        #expect(VND.format(-999) == "-999 ₫")
        #expect(VND.format(-1_250_000) == "-1.250.000 ₫")
    }

    @Test func extremeValues() {
        #expect(VND.format(Int64.max) == "9.223.372.036.854.775.807 ₫")
        #expect(VND.format(Int64.min) == "-9.223.372.036.854.775.808 ₫")
    }
}

struct VNDCompactTests {
    @Test func belowThousandFallsBackToFull() {
        #expect(VND.compact(0) == "0 ₫")
        #expect(VND.compact(850) == "850 ₫")
    }

    @Test func thousands() {
        #expect(VND.compact(500_000) == "500 k")
        #expect(VND.compact(1_500) == "1,5 k")
        #expect(VND.compact(9_999) == "10 k")
    }

    @Test func millionsAndBillions() {
        #expect(VND.compact(1_200_000) == "1,2 tr")
        #expect(VND.compact(25_000_000) == "25 tr")
        #expect(VND.compact(1_250_000) == "1,3 tr")  // rounds half-up
        #expect(VND.compact(3_500_000_000) == "3,5 tỷ")
        #expect(VND.compact(2_000_000_000) == "2 tỷ")
    }

    @Test func negativeAndCarry() {
        #expect(VND.compact(-1_200_000) == "-1,2 tr")
        #expect(VND.compact(999_950_000) == "1 tỷ")  // carry bumps tier
    }
}

struct VNDParseTests {
    @Test func rawAndGroupedDigits() {
        #expect(VND.parse("1250000") == 1_250_000)
        #expect(VND.parse("1.250.000") == 1_250_000)
        #expect(VND.parse("1,250,000") == 1_250_000)
        #expect(VND.parse("0") == 0)
    }

    @Test func magnitudeSuffixes() {
        #expect(VND.parse("500k") == 500_000)
        #expect(VND.parse("500K") == 500_000)
        #expect(VND.parse("1,2tr") == 1_200_000)
        #expect(VND.parse("1,2 tr") == 1_200_000)
        #expect(VND.parse("1.2tr") == 1_200_000)
        #expect(VND.parse("3,5 tỷ") == 3_500_000_000)
        #expect(VND.parse("2ty") == 2_000_000_000)
        #expect(VND.parse("5 triệu") == 5_000_000)
        #expect(VND.parse("10 nghìn") == 10_000)
    }

    @Test func currencyMarksAndSigns() {
        #expect(VND.parse("1.000đ") == 1_000)
        #expect(VND.parse("1000 vnd") == 1_000)
        #expect(VND.parse("-2tr") == -2_000_000)
        #expect(VND.parse("-1.250.000") == -1_250_000)
        #expect(VND.parse("  1.250.000  ") == 1_250_000)
    }

    @Test func fractionalSuffixValues() {
        #expect(VND.parse("1,25tr") == 1_250_000)
        #expect(VND.parse("1,234tr") == 1_234_000)
        #expect(VND.parse("0,5k") == 500)
    }

    @Test func rejectsGarbage() {
        #expect(VND.parse("") == nil)
        #expect(VND.parse("   ") == nil)
        #expect(VND.parse("abc") == nil)
        #expect(VND.parse("1tr2") == nil)          // bare digits after suffix: ambiguous
        #expect(VND.parse("1.2.3.4") == nil)        // invalid grouping
        #expect(VND.parse("-") == nil)
        #expect(VND.parse("1.250.000,5") == nil)    // trailing 1-digit group
    }

    @Test func rejectsOverflow() {
        #expect(VND.parse("99999999999tỷ") == nil)
        #expect(VND.parse("99999999999999999999") == nil)
    }
}
