import Foundation
import FinanceCore

/// Edit-form state for a `LedgerCategory`. Validation and model mapping live
/// here — pure, no SwiftUI — so tests can drive them without a view.
struct CategoryDraft: Equatable {
    var name: String
    var kind: CategoryKind
    var icon: String
    var colorHex: String

    init(
        name: String = "",
        kind: CategoryKind = .expense,
        icon: String = "",
        colorHex: String = ""
    ) {
        self.name = name
        self.kind = kind
        self.icon = icon
        self.colorHex = colorHex
    }

    /// Edit mapping: copies an existing model's fields into the form.
    init(category: LedgerCategory) {
        self.init(
            name: category.name,
            kind: category.kind,
            icon: category.icon,
            colorHex: category.colorHex
        )
    }

    var trimmedName: String {
        name.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    var isValid: Bool {
        !trimmedName.isEmpty
    }

    /// True when another category *of the same kind* already uses this name,
    /// ignoring case, diacritics and extra whitespace ("Ăn uống" == "an uong").
    /// Pass the edited model's id in `excludingID` so it does not match itself.
    func duplicateName(among categories: [LedgerCategory], excludingID: UUID? = nil) -> Bool {
        let folded = SettingsNameNormalizer.fold(trimmedName)
        guard !folded.isEmpty else { return false }
        return categories.contains {
            $0.id != excludingID
                && $0.kind == kind
                && SettingsNameNormalizer.fold($0.name) == folded
        }
    }

    /// Writes the draft onto an existing model. `kind` is chosen at creation
    /// time only and is deliberately not rewritten here.
    func apply(to category: LedgerCategory) {
        category.name = trimmedName
        category.icon = icon
        category.colorHex = colorHex
    }

    /// Builds a new model for the create path; `kind` comes from the draft.
    func makeCategory(sortOrder: Int) -> LedgerCategory {
        LedgerCategory(
            name: trimmedName,
            kind: kind,
            icon: icon,
            colorHex: colorHex,
            sortOrder: sortOrder
        )
    }
}
