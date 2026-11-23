import Testing
import Foundation
import FinanceCore
@testable import AMFinance

/// The Vietnamese mealtime context embedded in the typed-capture
/// extraction prompt: `AIMealtime`'s non-overlapping daypart buckets
/// (05–10 sáng, 11–13 trưa, 14–17 chiều, 18–22 tối, otherwise neutral)
/// and the guardrails the system prompt must state. Every instant is
/// pinned in UTC — Vietnam is UTC+7, so 17:30 UTC is 00:30 the next day
/// there, and 2026-11-24 in Vietnam spans 2026-11-23 17:00 →
/// 2026-11-24 16:59 UTC.
struct AICaptureMealtimeTests {

    /// A Date built from UTC components.
    private func utc(
        _ year: Int, _ month: Int, _ day: Int,
        _ hour: Int, _ minute: Int = 0
    ) -> Date {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        return calendar.date(from: DateComponents(
            year: year, month: month, day: day,
            hour: hour, minute: minute))!
    }

    @Test func daypartBucketsMeetButNeverOverlap() {
        // sáng 05:00–10:59 VN = 22:00 → 03:59 UTC.
        #expect(AIMealtime.at(utc(2026, 11, 23, 22, 0)) == .sang)
        #expect(AIMealtime.at(utc(2026, 11, 24, 3, 59)) == .sang)
        // trưa 11:00–13:59 VN = 04:00 → 06:59 UTC.
        #expect(AIMealtime.at(utc(2026, 11, 24, 4, 0)) == .trua)
        #expect(AIMealtime.at(utc(2026, 11, 24, 6, 59)) == .trua)
        // chiều 14:00–17:59 VN = 07:00 → 10:59 UTC.
        #expect(AIMealtime.at(utc(2026, 11, 24, 7, 0)) == .chieu)
        #expect(AIMealtime.at(utc(2026, 11, 24, 10, 59)) == .chieu)
        // tối 18:00–22:59 VN = 11:00 → 15:59 UTC.
        #expect(AIMealtime.at(utc(2026, 11, 24, 11, 0)) == .toi)
        #expect(AIMealtime.at(utc(2026, 11, 24, 15, 59)) == .toi)
    }

    @Test func lateNightHoursStayNeutralIncludingNearVietnameseMidnight() {
        // Neutral 23:00–04:59 VN = 16:00 → 21:59 UTC.
        #expect(AIMealtime.at(utc(2026, 11, 24, 16, 0)) == nil)   // 23:00 VN
        // 17:30 UTC = 00:30 VN on 25/11 — just past Vietnamese midnight.
        #expect(AIMealtime.at(utc(2026, 11, 24, 17, 30)) == nil)
        #expect(AIMealtime.at(utc(2026, 11, 24, 21, 59)) == nil)  // 04:59 VN
    }

    @Test func promptAtBreakfastHourCarriesClockMealAndRules() {
        // 00:30 UTC = 07:30 VN → bữa sáng.
        let prompt = AITransactionExtraction.systemPrompt(for: .init(
            now: utc(2026, 11, 24, 0, 30),
            expenseCategories: ["Ăn uống", "Di chuyển"],
            incomeCategories: ["Lương & thù lao"],
            accounts: [(name: "Tiền mặt", kind: .cash)],
            businesses: []))
        // The capture instant drives both the date line and the clock.
        #expect(prompt.contains("24/11"))
        #expect(prompt.contains("07:30"))
        #expect(prompt.contains("đang trong bữa sáng"))
        // Non-overlapping boundaries are spelled out for the model.
        #expect(prompt.contains("05:00–10:59"))
        #expect(prompt.contains("11:00–13:59"))
        #expect(prompt.contains("14:00–17:59"))
        #expect(prompt.contains("18:00–22:59"))
        // Guardrails: typed food/drink only, explicit words win, earlier
        // dates stay neutral, receipts keep their printed times, and no
        // new categories are invented.
        #expect(prompt.contains("Phở sáng"))
        #expect(prompt.contains("không ghi đè"))
        #expect(prompt.contains("không đoán bữa theo giờ gửi"))
        #expect(prompt.contains("hoá đơn/bill"))
        #expect(prompt.contains("không tạo danh mục mới"))
    }

    @Test func promptAtNeutralHourClaimsNoCurrentMeal() {
        // 16:30 UTC = 23:30 VN → outside every bucket.
        let prompt = AITransactionExtraction.systemPrompt(for: .init(
            now: utc(2026, 11, 24, 16, 30),
            expenseCategories: ["Ăn uống"],
            incomeCategories: [],
            accounts: [],
            businesses: []))
        #expect(prompt.contains("23:30"))
        #expect(prompt.contains("ngoài khung bữa ăn"))
        #expect(!prompt.contains("đang trong bữa"))
    }

    @Test func promptAtLunchBoundaryReflectsThatBucket() {
        // 04:30 UTC = 11:30 VN → first minute of trưa is 11:00 VN.
        let prompt = AITransactionExtraction.systemPrompt(for: .init(
            now: utc(2026, 11, 24, 4, 30),
            expenseCategories: ["Ăn uống"],
            incomeCategories: [],
            accounts: [],
            businesses: []))
        #expect(prompt.contains("11:30"))
        #expect(prompt.contains("đang trong bữa trưa"))
    }
}
