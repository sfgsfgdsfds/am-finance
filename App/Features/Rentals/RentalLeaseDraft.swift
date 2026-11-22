import Foundation

/// Form state behind `RentalLeaseEditView`: tenant, rent, deposit, due day
/// and contract period — plain values so validation and the model mapping
/// are unit-testable without SwiftUI or SwiftData.
///
/// `hasEndDate`/`endDate` map onto the model's optional `endDate`: the
/// toggle being off means open-ended.
struct RentalLeaseDraft {
    var tenantName = ""
    var tenantPhone = ""
    var startDate = Date.now
    /// Whether `endDate` applies — false = open-ended lease.
    var hasEndDate = false
    var endDate = Date.now
    /// Agreed monthly rent (đồng ≥ 0).
    var monthlyRent: Int64 = 0
    /// Deposit held (đồng ≥ 0) — information only, never posted.
    var deposit: Int64 = 0
    /// Due day of month, 1...31 (clamped in short months downstream).
    var paymentDay = 5
    var note = ""

    init() {}

    init(lease: RentalLease) {
        tenantName = lease.tenantName
        tenantPhone = lease.tenantPhone
        startDate = lease.startDate
        hasEndDate = lease.endDate != nil
        endDate = lease.endDate ?? .now
        monthlyRent = lease.monthlyRent
        deposit = lease.deposit
        paymentDay = lease.paymentDay
        note = lease.note
    }

    /// The trimmed tenant name as it will be stored.
    var trimmedName: String {
        tenantName.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// `endDate` as the model stores it.
    var effectiveEndDate: Date? {
        hasEndDate ? endDate : nil
    }

    /// First problem found, or nil when the draft can be saved.
    func validate() -> RentalLeaseDraftError? {
        if trimmedName.isEmpty { return .missingTenant }
        if monthlyRent < 0 || deposit < 0 { return .negativeAmount }
        if !(1...31).contains(paymentDay) { return .invalidPaymentDay }
        if let end = effectiveEndDate, end < startDate { return .endBeforeStart }
        return nil
    }

    /// Writes the draft onto an existing lease. `isActive` is left alone —
    /// a lease is ended through `RentalActions.end`, not by editing.
    func apply(to lease: RentalLease) {
        lease.tenantName = trimmedName
        lease.tenantPhone = tenantPhone.trimmingCharacters(in: .whitespacesAndNewlines)
        lease.startDate = startDate
        lease.endDate = effectiveEndDate
        lease.monthlyRent = monthlyRent
        lease.deposit = deposit
        lease.paymentDay = paymentDay
        lease.note = note.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Builds a new active lease for `unit`.
    func makeLease(unit: RentalUnit) -> RentalLease {
        RentalLease(
            tenantName: trimmedName,
            tenantPhone: tenantPhone.trimmingCharacters(in: .whitespacesAndNewlines),
            startDate: startDate,
            endDate: effectiveEndDate,
            monthlyRent: monthlyRent,
            deposit: deposit,
            paymentDay: paymentDay,
            isActive: true,
            note: note.trimmingCharacters(in: .whitespacesAndNewlines),
            unit: unit
        )
    }
}

/// Why a lease draft cannot be saved; each case carries a Vietnamese message.
enum RentalLeaseDraftError: Error, Equatable {
    case missingTenant
    case negativeAmount
    case invalidPaymentDay
    case endBeforeStart
}

extension RentalLeaseDraftError: LocalizedError {
    var errorDescription: String? {
        switch self {
        case .missingTenant: return "Vui lòng nhập tên người thuê."
        case .negativeAmount: return "Số tiền không thể âm."
        case .invalidPaymentDay: return "Ngày trả hằng tháng phải từ 1 đến 31."
        case .endBeforeStart: return "Ngày kết thúc phải sau ngày bắt đầu."
        }
    }
}
