import Testing
import FinanceCore

struct AMFinanceTests {
    @Test func financeCoreIsLinked() {
        #expect(VND.format(1_250_000) == "1.250.000 ₫")
        #expect(VND.parse("1,2tr") == 1_200_000)
    }
}
