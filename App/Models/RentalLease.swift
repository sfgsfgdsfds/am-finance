import Foundation
import SwiftData

/// One tenancy on a `RentalUnit`: who rents the room, for how much and from
/// when. `endDate == nil` means open-ended; `isActive` goes false when the
/// contract is ended early ("Kết thúc hợp đồng"). `deposit` is information
/// only — it is never posted to the ledger.
@Model
final class RentalLease {
    var id: UUID = UUID()
    var tenantName: String = ""
    var tenantPhone: String = ""
    var startDate: Date = Date.now
    /// Last day of the tenancy; nil = open-ended.
    var endDate: Date?
    /// Monthly rent agreed for this lease (đồng ≥ 0).
    var monthlyRent: Int64 = 0
    /// Deposit held (đồng ≥ 0) — displayed, never posted to the ledger.
    var deposit: Int64 = 0
    /// Day of month rent is due, 1...31 (clamped in short months).
    var paymentDay: Int = 1
    var isActive: Bool = true
    var note: String = ""
    var createdAt: Date = Date.now

    /// The room this lease rents.
    var unit: RentalUnit?

    /// Rent collections posted against this lease. `.nullify` keeps the
    /// schema CloudKit-compatible — deleting a lease leaves the income rows
    /// behind with `rentalLease == nil`.
    @Relationship(deleteRule: .nullify, inverse: \LedgerTransaction.rentalLease)
    var payments: [LedgerTransaction]? = []

    init(
        id: UUID = UUID(),
        tenantName: String,
        tenantPhone: String = "",
        startDate: Date = .now,
        endDate: Date? = nil,
        monthlyRent: Int64 = 0,
        deposit: Int64 = 0,
        paymentDay: Int = 1,
        isActive: Bool = true,
        note: String = "",
        unit: RentalUnit? = nil
    ) {
        self.id = id
        self.tenantName = tenantName
        self.tenantPhone = tenantPhone
        self.startDate = startDate
        self.endDate = endDate
        self.monthlyRent = monthlyRent
        self.deposit = deposit
        self.paymentDay = paymentDay
        self.isActive = isActive
        self.note = note
        self.unit = unit
    }
}
