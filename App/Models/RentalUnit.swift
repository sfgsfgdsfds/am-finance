import Foundation
import SwiftData

/// A rentable room of a serviced-apartment business ("Phòng 101").
/// `listPrice` is the advertised monthly rent; the rent actually charged
/// lives on each `RentalLease` so a price change never rewrites history.
@Model
final class RentalUnit {
    var id: UUID = UUID()
    var name: String = ""
    /// Advertised monthly rent (đồng ≥ 0); each lease carries its own rent.
    var listPrice: Int64 = 0
    var note: String = ""
    var sortOrder: Int = 0
    var isArchived: Bool = false
    var createdAt: Date = Date.now

    /// The business this room belongs to — normally the serviced-apartment
    /// stream ("Căn hộ dịch vụ"); nil means personal.
    var business: Business?

    /// Tenancies over time. `.nullify` keeps the schema CloudKit-compatible
    /// — a deleted unit leaves leases behind with `unit == nil`, so unit
    /// deletion removes its leases explicitly first.
    @Relationship(deleteRule: .nullify, inverse: \RentalLease.unit)
    var leases: [RentalLease]? = []

    init(
        id: UUID = UUID(),
        name: String,
        listPrice: Int64 = 0,
        note: String = "",
        sortOrder: Int = 0,
        isArchived: Bool = false,
        business: Business? = nil
    ) {
        self.id = id
        self.name = name
        self.listPrice = listPrice
        self.note = note
        self.sortOrder = sortOrder
        self.isArchived = isArchived
        self.business = business
    }
}
