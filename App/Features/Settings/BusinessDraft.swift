import Foundation

/// Edit-form state for a `Business` (an income stream such as "Căn hộ dịch
/// vụ"). Validation and model mapping live here — pure, no SwiftUI — so
/// tests can drive them without a view.
struct BusinessDraft: Equatable {
    var name: String
    var icon: String
    var colorHex: String
    var note: String

    init(
        name: String = "",
        icon: String = "",
        colorHex: String = "",
        note: String = ""
    ) {
        self.name = name
        self.icon = icon
        self.colorHex = colorHex
        self.note = note
    }

    /// Edit mapping: copies an existing model's fields into the form.
    init(business: Business) {
        self.init(
            name: business.name,
            icon: business.icon,
            colorHex: business.colorHex,
            note: business.note
        )
    }

    var trimmedName: String {
        name.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    var isValid: Bool {
        !trimmedName.isEmpty
    }

    /// True when another business already uses this name, ignoring case,
    /// diacritics and extra whitespace. Pass the edited model's id in
    /// `excludingID` so it does not match itself.
    func duplicateName(among businesses: [Business], excludingID: UUID? = nil) -> Bool {
        let folded = SettingsNameNormalizer.fold(trimmedName)
        guard !folded.isEmpty else { return false }
        return businesses.contains {
            $0.id != excludingID && SettingsNameNormalizer.fold($0.name) == folded
        }
    }

    /// Writes the draft onto an existing model.
    func apply(to business: Business) {
        business.name = trimmedName
        business.icon = icon
        business.colorHex = colorHex
        business.note = note.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Builds a new model for the create path.
    func makeBusiness(sortOrder: Int) -> Business {
        Business(
            name: trimmedName,
            icon: icon,
            colorHex: colorHex,
            note: note.trimmingCharacters(in: .whitespacesAndNewlines),
            sortOrder: sortOrder
        )
    }
}
