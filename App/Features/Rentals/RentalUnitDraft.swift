import Foundation

/// Form state behind `RentalUnitEditView`: room name, advertised monthly
/// rent, optional business and note — plain values so validation and the
/// model mapping are unit-testable without SwiftUI or SwiftData.
struct RentalUnitDraft {
    var name = ""
    /// Advertised monthly rent (đồng ≥ 0); each lease carries its own.
    var listPrice: Int64 = 0
    /// The business the room belongs to; nil is a personal room.
    var business: Business?
    var note = ""
    var isArchived = false

    init(business: Business? = nil) {
        self.business = business
    }

    init(unit: RentalUnit) {
        name = unit.name
        listPrice = unit.listPrice
        business = unit.business
        note = unit.note
        isArchived = unit.isArchived
    }

    /// The trimmed name as it will be stored.
    var trimmedName: String {
        name.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// First problem found, or nil when the draft can be saved.
    func validate() -> RentalUnitDraftError? {
        if trimmedName.isEmpty { return .missingName }
        if listPrice < 0 { return .negativePrice }
        return nil
    }

    /// Writes the draft onto an existing room.
    func apply(to unit: RentalUnit) {
        unit.name = trimmedName
        unit.listPrice = listPrice
        unit.business = business
        unit.note = note.trimmingCharacters(in: .whitespacesAndNewlines)
        unit.isArchived = isArchived
    }

    /// Builds a new room for the create path.
    func makeUnit(sortOrder: Int) -> RentalUnit {
        RentalUnit(
            name: trimmedName,
            listPrice: listPrice,
            note: note.trimmingCharacters(in: .whitespacesAndNewlines),
            sortOrder: sortOrder,
            isArchived: isArchived,
            business: business
        )
    }
}

/// Why a room draft cannot be saved; each case carries a Vietnamese message.
enum RentalUnitDraftError: Error, Equatable {
    case missingName
    case negativePrice
}

extension RentalUnitDraftError: LocalizedError {
    var errorDescription: String? {
        switch self {
        case .missingName: return "Vui lòng nhập tên phòng."
        case .negativePrice: return "Giá phòng không thể âm."
        }
    }
}
