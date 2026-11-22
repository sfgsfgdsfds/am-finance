import Foundation
import FinanceCore

/// Row builders behind the collect sheet and the "Kết thúc hợp đồng"
/// action. A collection posts one income row per đồng received: the rent
/// part carries `rentalPeriod` = the covered month's first day so
/// `RentalSnapshot` counts it toward that month; the extra part
/// (utilities — "Điện, nước, dịch vụ") shares the same `rentalLease` but
/// gets `rentalPeriod = nil`, so it stays on the lease's payment history
/// without ever counting as rent for any month.
enum RentalActions {

    // MARK: - Row builders

    /// One income row into `receiver`: rent collected for `month`.
    /// `category` is the seeded "Tiền thuê phòng" row, nil when missing.
    /// `note` is the sheet's text — "Tiền Phòng 101 tháng 11/2026" by
    /// default (see `rentNote`).
    static func rentPayment(
        lease: RentalLease,
        month monthStart: Date,
        amount: Int64,
        date: Date,
        note: String,
        into receiver: Account,
        category: LedgerCategory?
    ) -> LedgerTransaction {
        LedgerTransaction(
            kind: .income,
            amount: amount,
            date: date,
            note: note,
            account: receiver,
            category: category,
            business: lease.unit?.business,
            rentalLease: lease,
            rentalPeriod: monthStart
        )
    }

    /// One income row into `receiver`: an extra charge collected together
    /// with rent (điện, nước, dịch vụ). It is deliberately written with
    /// `rentalPeriod = nil` — linked to the lease but never counted as the
    /// rent of any month.
    static func extraPayment(
        lease: RentalLease,
        amount: Int64,
        date: Date,
        note: String,
        into receiver: Account,
        category: LedgerCategory?
    ) -> LedgerTransaction {
        LedgerTransaction(
            kind: .income,
            amount: amount,
            date: date,
            note: note,
            account: receiver,
            category: category,
            business: lease.unit?.business,
            rentalLease: lease,
            rentalPeriod: nil
        )
    }

    /// "Kết thúc hợp đồng" — stamps the end date and deactivates the lease.
    /// The month containing `date` still expects rent; later months stop.
    static func end(lease: RentalLease, at date: Date) {
        lease.endDate = date
        lease.isActive = false
    }

    // MARK: - Notes

    /// "Tiền Phòng 101 tháng 11/2026" — the default rent note the collect
    /// sheet pre-fills (the room name carries its own casing).
    static func rentNote(
        unitName: String,
        month monthStart: Date,
        calendar: Calendar
    ) -> String {
        "Tiền \(unitName) \(monthTitle(of: monthStart, calendar: calendar))"
    }

    /// "Thu thêm Phòng 101 tháng 11/2026" — fallback for an empty extra
    /// note.
    static func extraNote(
        unitName: String,
        month monthStart: Date,
        calendar: Calendar
    ) -> String {
        "Thu thêm \(unitName) \(monthTitle(of: monthStart, calendar: calendar))"
    }

    /// "tháng 11/2026" — the trailing month part of both notes.
    static func monthTitle(of monthStart: Date, calendar: Calendar) -> String {
        let month = calendar.component(.month, from: monthStart)
        let year = calendar.component(.year, from: monthStart)
        return "tháng \(month)/\(year)"
    }

    // MARK: - Pickers and categories

    /// The income category rent is filed under — the seeded
    /// "Tiền thuê phòng", looked up by name so a renamed or deleted seed
    /// degrades to nil rather than trapping.
    static let rentCategoryName = "Tiền thuê phòng"

    static func rentCategory(in categories: [LedgerCategory]) -> LedgerCategory? {
        categories.first { $0.name == rentCategoryName && $0.kind == .income }
    }

    /// Accounts rent can be received into: non-archived cash, bank and
    /// e-wallet (`AccountKind.canPay`) — never a card, loan or receivable.
    static func receivers(_ accounts: [Account]) -> [Account] {
        accounts.filter { !$0.isArchived && $0.kind.canPay }
    }
}
