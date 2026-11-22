import Foundation
import FinanceCore

/// Payment status of one room for one displayed month.
enum RentalMonthStatus: String, Equatable, Sendable {
    /// No lease covers the month — "Trống".
    case vacant
    /// A lease covers the month but nothing was collected — "Chưa thu",
    /// or "Quá hạn N ngày" once its due date passes.
    case unpaid
    /// Some of the month's rent was collected — "Thu một phần".
    case partial
    /// The month's rent is fully covered — "Đã thu".
    case paid
}

/// The lease facts the snapshot needs, as plain values so the month math
/// is testable without SwiftData.
///
/// Coverage is whole months only: a lease "covers" every calendar month
/// it touches — from the month containing `startDate` through the month
/// containing `endDate` (open-ended when nil) — and expects its full
/// `monthlyRent` for each. Rent is never prorated by days.
struct RentalLeaseSpan: Equatable, Sendable, Identifiable {
    var id: UUID
    var tenantName: String
    var monthlyRent: Int64
    /// Due day of month, 1...31 — clamped to the actual length of short
    /// months (the 31st becomes the 28th/29th in February).
    var paymentDay: Int
    var startDate: Date
    var endDate: Date?
    var isActive: Bool

    init(
        id: UUID = UUID(),
        tenantName: String,
        monthlyRent: Int64,
        paymentDay: Int,
        startDate: Date,
        endDate: Date? = nil,
        isActive: Bool = true
    ) {
        self.id = id
        self.tenantName = tenantName
        self.monthlyRent = monthlyRent
        self.paymentDay = paymentDay
        self.startDate = startDate
        self.endDate = endDate
        self.isActive = isActive
    }

    init(_ lease: RentalLease) {
        self.init(
            id: lease.id,
            tenantName: lease.tenantName,
            monthlyRent: lease.monthlyRent,
            paymentDay: lease.paymentDay,
            startDate: lease.startDate,
            endDate: lease.endDate,
            isActive: lease.isActive
        )
    }

    /// First day of the first covered month.
    func firstMonth(calendar: Calendar) -> Date {
        RentalSnapshot.monthStart(of: startDate, calendar: calendar)
    }

    /// First day of the last covered month; nil when open-ended.
    func lastMonth(calendar: Calendar) -> Date? {
        endDate.map { RentalSnapshot.monthStart(of: $0, calendar: calendar) }
    }

    /// True when the lease touches `month` (a month-start `Date`).
    /// `isActive` is deliberately ignored — an ended lease still owns its
    /// past months so their collected rent keeps counting.
    func covers(month monthStart: Date, calendar: Calendar) -> Bool {
        guard monthStart >= firstMonth(calendar: calendar) else { return false }
        if let last = lastMonth(calendar: calendar) {
            return monthStart <= last
        }
        return true
    }
}

/// One collected payment relevant to the snapshot: which lease it belongs
/// to, which month it covers and how much. `period == nil` marks an extra
/// charge (utilities…): it stays linked to the lease for history but never
/// counts toward any month's rent.
struct RentalPaymentEntry: Equatable, Sendable {
    var leaseID: UUID
    var period: Date?
    var amount: Int64
    var date: Date

    init(leaseID: UUID, period: Date?, amount: Int64, date: Date) {
        self.leaseID = leaseID
        self.period = period
        self.amount = amount
        self.date = date
    }

    init(_ transaction: LedgerTransaction) {
        self.init(
            leaseID: transaction.rentalLease?.id ?? UUID(),
            period: transaction.rentalPeriod,
            amount: transaction.amount,
            date: transaction.date
        )
    }
}

/// One room evaluated for one month: the covering lease's expected rent,
/// what was collected for that month, the clamped due date and the
/// resulting status.
struct RentalUnitMonth: Equatable, Sendable {
    /// The lease covering the month; nil when vacant.
    var leaseID: UUID?
    var tenantName: String?
    /// Full monthly rent of the covering lease; 0 when vacant.
    var expected: Int64
    /// Rent collected for this month on the covering lease.
    var collected: Int64
    /// The clamped due date inside the month; nil when vacant.
    var dueDate: Date?
    var status: RentalMonthStatus

    /// Rent still to collect for the month (đồng ≥ 0).
    var remaining: Int64 { max(0, expected - collected) }

    var isOccupied: Bool { status != .vacant }

    /// Whole days the payment is late: 0 until the day after `dueDate`.
    /// A month not yet due, a paid month and a vacant room all report 0.
    func overdueDays(now: Date, calendar: Calendar) -> Int {
        guard remaining > 0, let dueDate, dueDate < now else { return 0 }
        return calendar.dateComponents(
            [.day],
            from: calendar.startOfDay(for: dueDate),
            to: calendar.startOfDay(for: now)
        ).day ?? 0
    }
}

/// A unit's identity for board rows — plain values, no model graph.
struct RentalUnitInfo: Equatable, Sendable, Identifiable {
    var id: UUID
    var name: String
    var listPrice: Int64
    var sortOrder: Int
    var isArchived: Bool

    init(_ unit: RentalUnit) {
        id = unit.id
        name = unit.name
        listPrice = unit.listPrice
        sortOrder = unit.sortOrder
        isArchived = unit.isArchived
    }
}

/// One row of the month board: a room and its evaluated month.
struct RentalRoomRow: Equatable, Sendable {
    var unit: RentalUnitInfo
    var month: RentalUnitMonth
}

/// The list header for one displayed month: occupancy and money totals.
/// Archived rooms are excluded from every total — they sit in a collapsed
/// section and no longer take part in the business's month.
struct RentalBoard: Equatable, Sendable {
    var monthStart: Date
    /// Non-archived rooms whose month has a covering lease.
    var occupied: Int
    /// Non-archived rooms.
    var total: Int
    /// Sum of expected rent across occupied non-archived rooms.
    var expected: Int64
    /// Sum of collected rent across non-archived rooms.
    var collected: Int64
    /// Sum of per-room remainders.
    var remaining: Int64

    var occupancyFraction: Double {
        total > 0 ? Double(occupied) / Double(total) : 0
    }
}

/// Rent status math for rooms and months. Every function is pure: views
/// map live models once (`RentalLeaseSpan`, `RentalPaymentEntry`) and all
/// calendar work goes through `AppCalendar.vietnam`.
enum RentalSnapshot {

    /// First day of the month containing `date` at 00:00 local.
    static func monthStart(of date: Date, calendar: Calendar) -> Date {
        calendar.dateInterval(of: .month, for: date)?.start
            ?? calendar.startOfDay(for: date)
    }

    /// The lease a room's month belongs to. When several leases touch the
    /// same month (a mid-month change of tenant) the newest `startDate`
    /// wins — the latest tenant owns the handover month; `id` breaks ties
    /// deterministically.
    static func coveringLease(
        _ spans: [RentalLeaseSpan],
        month monthStart: Date,
        calendar: Calendar
    ) -> RentalLeaseSpan? {
        spans
            .filter { $0.covers(month: monthStart, calendar: calendar) }
            .sorted { lhs, rhs in
                lhs.startDate != rhs.startDate
                    ? lhs.startDate > rhs.startDate
                    : lhs.id.uuidString < rhs.id.uuidString
            }
            .first
    }

    /// The rent due date inside `monthStart`: `paymentDay` clamped to the
    /// month's length (the 31st becomes the last day of a short month).
    static func dueDate(
        of span: RentalLeaseSpan,
        month monthStart: Date,
        calendar: Calendar
    ) -> Date {
        let dayCount = calendar.range(of: .day, in: .month, for: monthStart)?.count ?? 31
        let day = min(max(1, span.paymentDay), dayCount)
        var components = calendar.dateComponents([.year, .month], from: monthStart)
        components.day = day
        return calendar.date(from: components) ?? monthStart
    }

    /// Rent collected for `monthStart` on `leaseID` — payments tagged with
    /// a `rentalPeriod`; extras (nil period) are excluded by construction.
    static func collected(
        payments: [RentalPaymentEntry],
        leaseID: UUID,
        month monthStart: Date,
        calendar: Calendar
    ) -> Int64 {
        payments.reduce(Int64(0)) { total, entry in
            guard entry.leaseID == leaseID, let period = entry.period,
                  RentalSnapshot.monthStart(of: period, calendar: calendar) == monthStart
            else { return total }
            return total + max(0, entry.amount)
        }
    }

    /// Evaluates one room for `monthStart`: covering lease, expected rent,
    /// collected amount, clamped due date and status.
    static func make(
        spans: [RentalLeaseSpan],
        payments: [RentalPaymentEntry],
        month monthStart: Date,
        calendar: Calendar
    ) -> RentalUnitMonth {
        guard let lease = coveringLease(spans, month: monthStart, calendar: calendar) else {
            return RentalUnitMonth(
                leaseID: nil, tenantName: nil, expected: 0, collected: 0,
                dueDate: nil, status: .vacant
            )
        }
        let expected = max(0, lease.monthlyRent)
        let collected = collected(
            payments: payments, leaseID: lease.id,
            month: monthStart, calendar: calendar
        )
        let status: RentalMonthStatus =
            collected >= expected ? .paid
            : collected > 0 ? .partial
            : .unpaid
        return RentalUnitMonth(
            leaseID: lease.id,
            tenantName: lease.tenantName,
            expected: expected,
            collected: collected,
            dueDate: dueDate(of: lease, month: monthStart, calendar: calendar),
            status: status
        )
    }

    /// `make` against a live unit: its leases and their payments.
    static func make(
        unit: RentalUnit,
        month monthStart: Date,
        calendar: Calendar
    ) -> RentalUnitMonth {
        make(
            spans: spans(of: unit),
            payments: payments(of: unit),
            month: monthStart,
            calendar: calendar
        )
    }

    /// All rows for a displayed month plus the occupancy/money header.
    /// Rooms keep `sortOrder`; archived rooms appear in `archivedRows` and
    /// are excluded from every total.
    static func board(
        units: [RentalUnit],
        month monthStart: Date,
        calendar: Calendar
    ) -> (rows: [RentalRoomRow], summary: RentalBoard) {
        var occupied = 0, total = 0
        var expected: Int64 = 0, collected: Int64 = 0, remaining: Int64 = 0
        let rows = units
            .sorted { $0.sortOrder != $1.sortOrder ? $0.sortOrder < $1.sortOrder : $0.name < $1.name }
            .map { unit in
                RentalRoomRow(
                    unit: RentalUnitInfo(unit),
                    month: make(unit: unit, month: monthStart, calendar: calendar)
                )
            }
        for row in rows where !row.unit.isArchived {
            total += 1
            expected += row.month.expected
            collected += row.month.collected
            remaining += row.month.remaining
            if row.month.isOccupied { occupied += 1 }
        }
        return (rows, RentalBoard(
            monthStart: monthStart,
            occupied: occupied,
            total: total,
            expected: expected,
            collected: collected,
            remaining: remaining
        ))
    }

    /// The consecutive covered months of a lease, oldest first, capped at
    /// `upperBound` (a month start). An empty result means the lease only
    /// covers future months.
    static func coveredMonths(
        of span: RentalLeaseSpan,
        through upperBound: Date,
        calendar: Calendar
    ) -> [Date] {
        var months: [Date] = []
        var month = span.firstMonth(calendar: calendar)
        let last = span.lastMonth(calendar: calendar)
        while month <= upperBound, last == nil || month <= last! {
            months.append(month)
            guard let next = calendar.date(byAdding: .month, value: 1, to: month) else { break }
            month = next
        }
        return months
    }

    /// Months the collect sheet offers: every covered month up to the
    /// current one — late payments for past months, no "pre-collection" of
    /// far-future months. A lease that only starts later still offers its
    /// first month so a first rent can be recorded ahead.
    static func collectableMonths(
        of span: RentalLeaseSpan,
        now: Date,
        calendar: Calendar
    ) -> [Date] {
        let currentMonth = monthStart(of: now, calendar: calendar)
        let months = coveredMonths(of: span, through: currentMonth, calendar: calendar)
        return months.isEmpty ? [span.firstMonth(calendar: calendar)] : months
    }

    /// The first covered month up to `now` whose rent is not fully
    /// collected; nil when every due month is paid (or the lease has no
    /// due month yet).
    static func oldestUnpaidMonth(
        of span: RentalLeaseSpan,
        payments: [RentalPaymentEntry],
        now: Date,
        calendar: Calendar
    ) -> Date? {
        let currentMonth = monthStart(of: now, calendar: calendar)
        for month in coveredMonths(of: span, through: currentMonth, calendar: calendar) {
            let collected = collected(
                payments: payments, leaseID: span.id,
                month: month, calendar: calendar
            )
            if collected < max(0, span.monthlyRent) { return month }
        }
        return nil
    }

    /// The month the collect sheet opens on: the oldest unpaid month, else
    /// the latest collectable month (the current one for a running lease).
    static func defaultCollectMonth(
        of span: RentalLeaseSpan,
        payments: [RentalPaymentEntry],
        now: Date,
        calendar: Calendar
    ) -> Date {
        oldestUnpaidMonth(of: span, payments: payments, now: now, calendar: calendar)
            ?? collectableMonths(of: span, now: now, calendar: calendar).last
            ?? monthStart(of: now, calendar: calendar)
    }

    /// The lease's payments, as snapshot entries — rent (tagged periods)
    /// and extras (nil) alike; `collected` does the filtering.
    static func payments(of lease: RentalLease) -> [RentalPaymentEntry] {
        (lease.payments ?? []).map(RentalPaymentEntry.init)
    }

    /// All payments across a unit's leases.
    static func payments(of unit: RentalUnit) -> [RentalPaymentEntry] {
        (unit.leases ?? []).flatMap(payments(of:))
    }

    /// A unit's leases as spans.
    static func spans(of unit: RentalUnit) -> [RentalLeaseSpan] {
        (unit.leases ?? []).map(RentalLeaseSpan.init)
    }

    /// The last `count` calendar months ending with the month containing
    /// `reference`, oldest first — the detail view's status grid range.
    static func recentMonths(
        count: Int,
        endingAt reference: Date,
        calendar: Calendar
    ) -> [Date] {
        guard count > 0 else { return [] }
        let last = monthStart(of: reference, calendar: calendar)
        return (0..<count).compactMap { index in
            calendar.date(byAdding: .month, value: index - (count - 1), to: last)
        }
    }
}

/// Small value helpers shared by the rental views.
enum RentalFormat {
    /// `tel:` URL for the tenant phone link; strips everything but digits
    /// and a leading "+" so "090 123 4567" still dials.
    static func phoneURL(_ phone: String) -> URL? {
        var number = phone.hasPrefix("+") ? "+" : ""
        number += phone.filter(\.isNumber)
        guard number.count > 1 else { return nil }
        return URL(string: "tel:\(number)")
    }

    /// "05/06/2026" — a lease start/end date at day precision.
    static func fullDate(_ date: Date, calendar: Calendar) -> String {
        let day = calendar.component(.day, from: date)
        let month = calendar.component(.month, from: date)
        let year = calendar.component(.year, from: date)
        return String(format: "%02d/%02d/%d", day, month, year)
    }
}
