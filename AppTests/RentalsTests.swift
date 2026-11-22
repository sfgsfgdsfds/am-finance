import Testing
import SwiftData
import Foundation
import FinanceCore
@testable import AMFinance

/// Rental feature tests: the pure month math in `RentalSnapshot` runs
/// against plain value types (`RentalLeaseSpan`, `RentalPaymentEntry`),
/// while the posting, draft and model-mapping parts run against an
/// in-memory SwiftData store.
@MainActor
struct RentalsTests {

    private let calendar = AppCalendar.vietnam

    private func makeContext() throws -> ModelContext {
        ModelContext(try AppModelContainer.make(inMemory: true))
    }

    /// A moment in Asia/Ho_Chi_Minh.
    private func day(
        _ year: Int, _ month: Int, _ dayOfMonth: Int,
        _ hour: Int = 0, _ minute: Int = 0
    ) -> Date {
        calendar.date(from: DateComponents(
            year: year, month: month, day: dayOfMonth, hour: hour, minute: minute
        ))!
    }

    /// First day of a month — the shape `rentalPeriod` and month keys use.
    private func monthStart(_ year: Int, _ month: Int) -> Date {
        day(year, month, 1)
    }

    /// A lease span covering 2026-01 onward at 5_000_000/month, due day 5.
    private func span(
        rent: Int64 = 5_000_000,
        paymentDay: Int = 5,
        start: Date? = nil,
        end: Date? = nil
    ) -> RentalLeaseSpan {
        RentalLeaseSpan(
            tenantName: "Người thuê", monthlyRent: rent,
            paymentDay: paymentDay,
            startDate: start ?? day(2026, 1, 1),
            endDate: end
        )
    }

    private func rent(
        _ leaseID: UUID, _ year: Int, _ month: Int, _ amount: Int64
    ) -> RentalPaymentEntry {
        RentalPaymentEntry(
            leaseID: leaseID, period: monthStart(year, month),
            amount: amount, date: day(year, month, 5)
        )
    }

    // MARK: - Month status

    /// Every tag the list shows, evaluated for one month: paid, partial,
    /// unpaid and vacant.
    @Test func monthStatusPaidPartialUnpaidVacant() {
        let lease = span()
        let month = monthStart(2026, 3)

        let paid = RentalSnapshot.make(
            spans: [lease],
            payments: [rent(lease.id, 2026, 3, 5_000_000)],
            month: month, calendar: calendar
        )
        #expect(paid.status == .paid)
        #expect(paid.expected == 5_000_000)
        #expect(paid.collected == 5_000_000)
        #expect(paid.remaining == 0)

        let partial = RentalSnapshot.make(
            spans: [lease],
            payments: [rent(lease.id, 2026, 3, 2_000_000)],
            month: month, calendar: calendar
        )
        #expect(partial.status == .partial)
        #expect(partial.remaining == 3_000_000)

        let unpaid = RentalSnapshot.make(
            spans: [lease], payments: [], month: month, calendar: calendar
        )
        #expect(unpaid.status == .unpaid)
        #expect(unpaid.tenantName == "Người thuê")

        let vacant = RentalSnapshot.make(
            spans: [], payments: [], month: month, calendar: calendar
        )
        #expect(vacant.status == .vacant)
        #expect(vacant.expected == 0)
        #expect(vacant.leaseID == nil)
    }

    /// Overpaying a month is still "Đã thu" — nothing negative remains.
    @Test func overpaymentStaysPaid() {
        let lease = span()
        let month = RentalSnapshot.make(
            spans: [lease],
            payments: [rent(lease.id, 2026, 3, 8_000_000)],
            month: monthStart(2026, 3), calendar: calendar
        )
        #expect(month.status == .paid)
        #expect(month.remaining == 0)
    }

    // MARK: - Overdue days

    /// After the due day passes unpaid the row turns "Quá hạn N ngày".
    @Test func overdueDaysCountWholeDaysAfterDueDate() {
        let lease = span(paymentDay: 5)
        let month = RentalSnapshot.make(
            spans: [lease], payments: [],
            month: monthStart(2026, 11), calendar: calendar
        )
        // Due 05/11: still fine on the day itself, one day late on the 6th.
        #expect(month.overdueDays(now: day(2026, 11, 5, 23), calendar: calendar) == 0)
        #expect(month.overdueDays(now: day(2026, 11, 6), calendar: calendar) == 1)
        #expect(month.overdueDays(now: day(2026, 11, 25), calendar: calendar) == 20)

        // Paid or vacant rooms never show overdue.
        let paid = RentalSnapshot.make(
            spans: [lease], payments: [rent(lease.id, 2026, 11, 5_000_000)],
            month: monthStart(2026, 11), calendar: calendar
        )
        #expect(paid.overdueDays(now: day(2026, 11, 25), calendar: calendar) == 0)
        let vacant = RentalSnapshot.make(
            spans: [], payments: [], month: monthStart(2026, 11), calendar: calendar
        )
        #expect(vacant.overdueDays(now: day(2026, 11, 25), calendar: calendar) == 0)
    }

    // MARK: - Whole-month coverage

    /// A lease that starts and ends mid-year only expects rent for the
    /// months it touches — from its start month through its end month.
    @Test func midYearLeaseExpectsOnlyItsOwnMonths() {
        let lease = span(start: day(2026, 3, 10), end: day(2026, 8, 20))
        // February and September are outside — the room reads as vacant.
        let before = RentalSnapshot.make(
            spans: [lease], payments: [],
            month: monthStart(2026, 2), calendar: calendar
        )
        let after = RentalSnapshot.make(
            spans: [lease], payments: [],
            month: monthStart(2026, 9), calendar: calendar
        )
        #expect(before.status == .vacant)
        #expect(after.status == .vacant)

        // The start and end months themselves are covered — rent is never
        // prorated by days, the full rent is expected both times.
        for month in [3, 8] {
            let info = RentalSnapshot.make(
                spans: [lease], payments: [],
                month: monthStart(2026, month), calendar: calendar
            )
            #expect(info.status == .unpaid)
            #expect(info.expected == 5_000_000)
        }

        // The covered range is exactly March…August.
        let covered = RentalSnapshot.coveredMonths(
            of: lease, through: monthStart(2027, 1), calendar: calendar
        )
        #expect(covered.count == 6)
        #expect(covered.first == monthStart(2026, 3))
        #expect(covered.last == monthStart(2026, 8))
    }

    // MARK: - Payment day 31 in short months

    /// A due day of 31 clamps to the last day of a short month — February's
    /// overdue timer only starts on the 28th/29th, never the 31st.
    @Test func paymentDay31ClampsToFebruaryEnd() {
        let lease = span(paymentDay: 31)
        let february = RentalSnapshot.make(
            spans: [lease], payments: [],
            month: monthStart(2026, 2), calendar: calendar
        )
        // 2026 is not a leap year — the due date is the 28th.
        #expect(february.dueDate == day(2026, 2, 28))
        #expect(february.overdueDays(now: day(2026, 2, 28, 23), calendar: calendar) == 0)
        #expect(february.overdueDays(now: day(2026, 3, 2), calendar: calendar) == 2)

        // A normal length month keeps the 31st.
        let march = RentalSnapshot.make(
            spans: [lease], payments: [],
            month: monthStart(2026, 3), calendar: calendar
        )
        #expect(march.dueDate == day(2026, 3, 31))
    }

    // MARK: - Partial payments accumulate

    /// Two collections toward the same month sum up; the month is paid
    /// once the running total covers the rent.
    @Test func partialPaymentsAccumulate() {
        let lease = span()
        let payments = [
            rent(lease.id, 2026, 4, 1_500_000),
            rent(lease.id, 2026, 4, 2_000_000),
        ]
        let month = RentalSnapshot.make(
            spans: [lease], payments: payments,
            month: monthStart(2026, 4), calendar: calendar
        )
        #expect(month.collected == 3_500_000)
        #expect(month.status == .partial)
        #expect(month.remaining == 1_500_000)

        let toppedUp = RentalSnapshot.make(
            spans: [lease],
            payments: payments + [rent(lease.id, 2026, 4, 1_500_000)],
            month: monthStart(2026, 4), calendar: calendar
        )
        #expect(toppedUp.status == .paid)
    }

    /// Payments against a different lease never count toward this one.
    @Test func paymentsStayOnTheirOwnLease() {
        let lease = span()
        let other = RentalPaymentEntry(
            leaseID: UUID(), period: monthStart(2026, 4),
            amount: 9_000_000, date: .now
        )
        let month = RentalSnapshot.make(
            spans: [lease], payments: [other],
            month: monthStart(2026, 4), calendar: calendar
        )
        #expect(month.collected == 0)
        #expect(month.status == .unpaid)
    }

    // MARK: - Extras never count as rent

    /// A utilities row keeps its lease link but carries no `rentalPeriod`,
    /// so it lands in history without counting toward any month's rent.
    @Test func extrasWithNilPeriodDoNotCountAsRent() {
        let lease = span()
        let payments = [
            RentalPaymentEntry(leaseID: lease.id, period: nil,
                               amount: 700_000, date: .now),      // điện nước
            rent(lease.id, 2026, 5, 5_000_000),                     // rent
        ]
        let month = RentalSnapshot.make(
            spans: [lease], payments: payments,
            month: monthStart(2026, 5), calendar: calendar
        )
        #expect(month.collected == 5_000_000)
        #expect(month.status == .paid)

        // An extra alone leaves the month unpaid.
        let extrasOnly = RentalSnapshot.make(
            spans: [lease],
            payments: [RentalPaymentEntry(leaseID: lease.id, period: nil,
                                        amount: 700_000, date: .now)],
            month: monthStart(2026, 5), calendar: calendar
        )
        #expect(extrasOnly.status == .unpaid)
    }

    // MARK: - Oldest unpaid month

    /// The collect sheet opens on the oldest still-due month so back-paying
    /// always fills the first gap.
    @Test func oldestUnpaidMonthFindsTheFirstGap() {
        let lease = span()
        let now = day(2026, 4, 10)
        // January paid, February and March open, April not yet due but open.
        let payments = [rent(lease.id, 2026, 1, 5_000_000)]
        #expect(RentalSnapshot.oldestUnpaidMonth(
            of: lease, payments: payments, now: now, calendar: calendar
        ) == monthStart(2026, 2))

        // Once February is covered the gap moves to March.
        let more = payments + [rent(lease.id, 2026, 2, 5_000_000)]
        #expect(RentalSnapshot.oldestUnpaidMonth(
            of: lease, payments: more, now: now, calendar: calendar
        ) == monthStart(2026, 3))

        // Everything paid → nil; the default falls back to the current
        // month so a running lease still collects on time.
        let all = more + [
            rent(lease.id, 2026, 3, 5_000_000),
            rent(lease.id, 2026, 4, 5_000_000),
        ]
        #expect(RentalSnapshot.oldestUnpaidMonth(
            of: lease, payments: all, now: now, calendar: calendar
        ) == nil)
        #expect(RentalSnapshot.defaultCollectMonth(
            of: lease, payments: all, now: now, calendar: calendar
        ) == monthStart(2026, 4))
    }

    /// A lease starting next month still offers its first month — the
    /// tenant can pay ahead even though nothing is "due" yet.
    @Test func futureLeaseOffersItsFirstMonth() {
        let lease = span(start: day(2026, 8, 15))
        let months = RentalSnapshot.collectableMonths(
            of: lease, now: day(2026, 6, 10), calendar: calendar
        )
        #expect(months == [monthStart(2026, 8)])
        #expect(RentalSnapshot.defaultCollectMonth(
            of: lease, payments: [], now: day(2026, 6, 10), calendar: calendar
        ) == monthStart(2026, 8))
    }

    // MARK: - Ending a lease

    /// "Kết thúc hợp đồng" stamps the end month: that month still expects
    /// rent, every later month reads as vacant.
    @Test func endingALeaseStopsFutureExpectations() {
        let lease = span(start: day(2026, 1, 1), end: day(2026, 6, 20))
        let june = RentalSnapshot.make(
            spans: [lease], payments: [],
            month: monthStart(2026, 6), calendar: calendar
        )
        let july = RentalSnapshot.make(
            spans: [lease], payments: [],
            month: monthStart(2026, 7), calendar: calendar
        )
        #expect(june.status == .unpaid)
        #expect(july.status == .vacant)

        // The unpaid gap only runs through the end month.
        #expect(RentalSnapshot.oldestUnpaidMonth(
            of: lease, payments: [], now: day(2026, 9, 1), calendar: calendar
        ) == monthStart(2026, 1))
        let covered = RentalSnapshot.coveredMonths(
            of: lease, through: monthStart(2026, 12), calendar: calendar
        )
        #expect(covered.count == 6)
        #expect(covered.last == monthStart(2026, 6))
    }

    /// An ended lease keeps its past months — collected rent from before
    /// the end date still shows "Đã thu" in history.
    @Test func endedLeaseKeepsItsPastMonths() {
        let lease = RentalLeaseSpan(
            tenantName: "Cũ", monthlyRent: 5_000_000, paymentDay: 5,
            startDate: day(2026, 1, 1), endDate: day(2026, 3, 31),
            isActive: false
        )
        let month = RentalSnapshot.make(
            spans: [lease], payments: [rent(lease.id, 2026, 2, 5_000_000)],
            month: monthStart(2026, 2), calendar: calendar
        )
        #expect(month.status == .paid)
        #expect(month.tenantName == "Cũ")
    }

    // MARK: - Handover month

    /// Two leases touching the same month — the latest tenant owns it.
    @Test func newestLeaseWinsASharedMonth() {
        let old = RentalLeaseSpan(
            tenantName: "Cũ", monthlyRent: 4_000_000, paymentDay: 5,
            startDate: day(2026, 1, 1), endDate: day(2026, 3, 15),
            isActive: false
        )
        let new = span(rent: 5_000_000, start: day(2026, 3, 16))
        let month = RentalSnapshot.make(
            spans: [old, new], payments: [],
            month: monthStart(2026, 3), calendar: calendar
        )
        #expect(month.leaseID == new.id)
        #expect(month.expected == 5_000_000)
        #expect(month.tenantName == "Người thuê")
    }

    // MARK: - Board

    /// The header sums only non-archived rooms: occupancy, expected,
    /// collected and remaining.
    @Test func boardTotalsExcludeArchivedRooms() throws {
        let context = try makeContext()
        let occupied = RentalUnit(name: "Phòng 101", listPrice: 5_000_000)
        let vacantRoom = RentalUnit(name: "Phòng 102", listPrice: 4_000_000)
        let stored = RentalUnit(name: "Phòng 201", isArchived: true)
        for unit in [occupied, vacantRoom, stored] { context.insert(unit) }

        let active = RentalLease(
            tenantName: "Thuê", startDate: day(2026, 1, 1),
            monthlyRent: 5_000_000, paymentDay: 5, unit: occupied
        )
        let archived = RentalLease(
            tenantName: "Cũ", startDate: day(2026, 1, 1),
            monthlyRent: 9_000_000, paymentDay: 5, unit: stored
        )
        context.insert(active)
        context.insert(archived)
        try context.save()

        let month = monthStart(2026, 3)
        let (rows, summary) = RentalSnapshot.board(
            units: [occupied, vacantRoom, stored],
            month: month, calendar: calendar
        )
        #expect(rows.count == 3)
        #expect(summary.total == 2)
        #expect(summary.occupied == 1)
        #expect(summary.occupancyFraction == 0.5)
        #expect(summary.expected == 5_000_000)
        #expect(summary.remaining == 5_000_000)

        // Collecting the rent flips the board to fully collected.
        let payment = LedgerTransaction(
            kind: .income, amount: 5_000_000,
            rentalLease: active, rentalPeriod: month
        )
        context.insert(payment)
        try context.save()
        let after = RentalSnapshot.board(
            units: [occupied, vacantRoom, stored],
            month: month, calendar: calendar
        ).summary
        #expect(after.collected == 5_000_000)
        #expect(after.remaining == 0)
    }

    // MARK: - RentalActions: collecting posts income

    /// One tap posts a business income row: the seeded rent category, the
    /// lease, the covered month's first day, and the receiver's balance
    /// grows by the amount.
    @Test func collectPostsBusinessIncomeAndRaisesBalance() throws {
        let context = try makeContext()
        try SeedData.seedIfNeeded(context: context)

        let categories = try context.fetch(FetchDescriptor<LedgerCategory>())
        let apartment = try #require(
            try context.fetch(FetchDescriptor<Business>())
                .first { $0.name == "Căn hộ dịch vụ" }
        )
        let category = try #require(RentalActions.rentCategory(in: categories))
        #expect(category.name == "Tiền thuê phòng")
        #expect(category.kind == .income)

        let cash = Account(name: "Tiền mặt", kind: .cash, openingBalance: 1_000_000)
        let unit = RentalUnit(name: "Phòng 101", listPrice: 5_000_000, business: apartment)
        let lease = RentalLease(
            tenantName: "Người thuê", startDate: day(2026, 1, 1),
            monthlyRent: 5_000_000, paymentDay: 5, unit: unit
        )
        context.insert(cash)
        context.insert(unit)
        context.insert(lease)
        try context.save()

        let month = monthStart(2026, 11)
        let row = RentalActions.rentPayment(
            lease: lease, month: month, amount: 5_000_000,
            date: day(2026, 11, 5, 9, 30),
            note: RentalActions.rentNote(unitName: unit.name, month: month, calendar: calendar),
            into: cash, category: category
        )
        context.insert(row)
        try context.save()

        #expect(row.kind == .income)
        #expect(row.amount == 5_000_000)
        #expect(row.account?.id == cash.id)
        #expect(row.category?.id == category.id)
        #expect(row.business?.id == apartment.id)
        #expect(row.rentalLease?.id == lease.id)
        #expect(row.rentalPeriod == month)
        #expect(row.note == "Tiền Phòng 101 tháng 11/2026")
        #expect(cash.balance == 6_000_000)
        #expect(lease.payments?.contains { $0.id == row.id } == true)
    }

    /// The utilities part rides the same lease but keeps `rentalPeriod`
    /// nil — business income that never counts as any month's rent.
    @Test func extraPaymentStaysOffTheRentLedger() throws {
        let context = try makeContext()
        let cash = Account(name: "Tiền mặt", kind: .cash)
        let unit = RentalUnit(name: "Phòng 101", listPrice: 5_000_000)
        let lease = RentalLease(
            tenantName: "Thuê", startDate: day(2026, 1, 1),
            monthlyRent: 5_000_000, paymentDay: 5, unit: unit
        )
        context.insert(cash)
        context.insert(unit)
        context.insert(lease)
        try context.save()

        let extra = RentalActions.extraPayment(
            lease: lease, amount: 800_000, date: .now,
            note: "Điện, nước, dịch vụ", into: cash, category: nil
        )
        context.insert(extra)
        try context.save()

        #expect(extra.kind == .income)
        #expect(extra.rentalLease?.id == lease.id)
        #expect(extra.rentalPeriod == nil)
        #expect(cash.balance == 800_000)

        // And the month still reads as fully unpaid.
        let month = RentalSnapshot.make(
            unit: unit, month: monthStart(2026, 1), calendar: calendar
        )
        #expect(month.status == .unpaid)
        #expect(month.collected == 0)
    }

    /// Receivers are non-archived cash, bank and e-wallet — never a card,
    /// loan, receivable or archived account.
    @Test func receiversFilterToPayingAccounts() {
        let cash = Account(name: "Tiền mặt", kind: .cash)
        let bank = Account(name: "Ngân hàng", kind: .bank)
        let wallet = Account(name: "Momo", kind: .eWallet)
        let card = Account(name: "Thẻ", kind: .creditCard)
        let loan = Account(name: "Vay", kind: .loan)
        let client = Account(name: "Khách", kind: .receivable)
        let archived = Account(name: "Cũ", kind: .bank, isArchived: true)

        let eligible = RentalActions.receivers(
            [cash, bank, wallet, card, loan, client, archived]
        )
        #expect(Set(eligible.map(\.id)) == Set([cash.id, bank.id, wallet.id]))
    }

    /// "Kết thúc hợp đồng" stamps the end date and deactivates — the end
    /// month still expects rent.
    @Test func endLeaseStampsEndDateAndDeactivates() {
        let lease = RentalLease(
            tenantName: "Thuê", startDate: day(2026, 1, 1),
            monthlyRent: 5_000_000, paymentDay: 5
        )
        let end = day(2026, 6, 20)
        RentalActions.end(lease: lease, at: end)
        #expect(lease.endDate == end)
        #expect(!lease.isActive)
    }

    // MARK: - Drafts

    @Test func unitDraftValidatesAndMaps() {
        var invalid = RentalUnitDraft()
        invalid.name = "   "
        #expect(invalid.validate() == .missingName)
        invalid.name = "Phòng"
        invalid.listPrice = -1
        #expect(invalid.validate() == .negativePrice)

        var draft = RentalUnitDraft()
        draft.name = "  Phòng 101  "
        draft.listPrice = 5_000_000
        draft.note = " ban công "
        #expect(draft.validate() == nil)

        let unit = draft.makeUnit(sortOrder: 3)
        #expect(unit.name == "Phòng 101")
        #expect(unit.listPrice == 5_000_000)
        #expect(unit.note == "ban công")
        #expect(unit.sortOrder == 3)
        #expect(!unit.isArchived)

        // Editing writes back through the draft.
        draft.name = "Phòng 102"
        draft.isArchived = true
        draft.apply(to: unit)
        #expect(unit.name == "Phòng 102")
        #expect(unit.isArchived)

        let roundTrip = RentalUnitDraft(unit: unit)
        #expect(roundTrip.name == "Phòng 102")
        #expect(roundTrip.isArchived)
    }

    @Test func leaseDraftValidatesAndMaps() throws {
        let context = try makeContext()
        let unit = RentalUnit(name: "Phòng 101", listPrice: 5_000_000)
        context.insert(unit)

        var draft = RentalLeaseDraft()
        #expect(draft.validate() == .missingTenant)
        draft.tenantName = "Người thuê"
        draft.monthlyRent = -1
        #expect(draft.validate() == .negativeAmount)
        draft.monthlyRent = 5_000_000
        draft.paymentDay = 40
        #expect(draft.validate() == .invalidPaymentDay)
        draft.paymentDay = 5
        draft.hasEndDate = true
        draft.endDate = day(2025, 12, 31)
        draft.startDate = day(2026, 1, 1)
        #expect(draft.validate() == .endBeforeStart)

        draft.endDate = day(2026, 12, 31)
        draft.deposit = 5_000_000
        draft.tenantPhone = " 090 123 "
        #expect(draft.validate() == nil)

        let lease = draft.makeLease(unit: unit)
        #expect(lease.tenantName == "Người thuê")
        #expect(lease.tenantPhone == "090 123")
        #expect(lease.monthlyRent == 5_000_000)
        #expect(lease.deposit == 5_000_000)
        #expect(lease.paymentDay == 5)
        #expect(lease.isActive)
        #expect(lease.endDate == day(2026, 12, 31))
        #expect(lease.unit?.id == unit.id)

        // An open-ended draft stores nil; editing a lease never touches
        // isActive.
        draft.hasEndDate = false
        #expect(draft.effectiveEndDate == nil)
        lease.isActive = false
        draft.apply(to: lease)
        #expect(lease.endDate == nil)
        #expect(!lease.isActive)

        let roundTrip = RentalLeaseDraft(lease: lease)
        #expect(roundTrip.tenantName == "Người thuê")
        #expect(!roundTrip.hasEndDate)
    }

    // MARK: - Live-model snapshot

    /// The snapshot reads live models: a lease on a unit plus its rent rows
    /// drive status, collected and the covering lease.
    @Test func snapshotReadsLiveModels() throws {
        let context = try makeContext()
        let cash = Account(name: "Tiền mặt", kind: .cash)
        let unit = RentalUnit(name: "Phòng 101", listPrice: 5_000_000)
        let lease = RentalLease(
            tenantName: "Thuê A", tenantPhone: "090 123",
            startDate: day(2026, 1, 1), monthlyRent: 5_000_000,
            paymentDay: 5, unit: unit
        )
        context.insert(cash)
        context.insert(unit)
        context.insert(lease)
        let month = monthStart(2026, 2)
        context.insert(LedgerTransaction(
            kind: .income, amount: 3_000_000, account: cash,
            rentalLease: lease, rentalPeriod: month
        ))
        try context.save()

        let info = RentalSnapshot.make(unit: unit, month: month, calendar: calendar)
        #expect(info.status == .partial)
        #expect(info.collected == 3_000_000)
        #expect(info.leaseID == lease.id)
        #expect(info.tenantName == "Thuê A")
        #expect(RentalSnapshot.payments(of: unit).count == 1)
    }

    // MARK: - Phone URL

    @Test func phoneURLStripsEverythingButDigitsAndLeadingPlus() {
        #expect(RentalFormat.phoneURL("090 123 4567")?.absoluteString == "tel:0901234567")
        #expect(RentalFormat.phoneURL("+84 901-234-567")?.absoluteString == "tel:+84901234567")
        #expect(RentalFormat.phoneURL("") == nil)
        #expect(RentalFormat.phoneURL("abc") == nil)
    }
}
