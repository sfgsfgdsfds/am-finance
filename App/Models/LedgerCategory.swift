import Foundation
import SwiftData
import FinanceCore

/// A category that classifies transactions as money out or money in.
/// Named `LedgerCategory` because `Category` clashes with ObjectiveC.
@Model
final class LedgerCategory {
    var id: UUID = UUID()
    var name: String = ""
    var kindRaw: String = CategoryKind.expense.rawValue
    var icon: String = ""
    var colorHex: String = ""
    var sortOrder: Int = 0
    var isArchived: Bool = false

    @Relationship(deleteRule: .nullify, inverse: \LedgerTransaction.category)
    var transactions: [LedgerTransaction]? = []

    /// `.nullify` keeps the schema CloudKit-compatible — cascade deletes
    /// can't sync — so a deleted category leaves its budgets behind with
    /// `category == nil` (they then read as overall budgets).
    @Relationship(deleteRule: .nullify, inverse: \Budget.category)
    var budgets: [Budget]? = []

    @Relationship(deleteRule: .nullify, inverse: \RecurringRule.category)
    var recurringRules: [RecurringRule]? = []

    init(
        id: UUID = UUID(),
        name: String,
        kind: CategoryKind,
        icon: String = "",
        colorHex: String = "",
        sortOrder: Int = 0,
        isArchived: Bool = false
    ) {
        self.id = id
        self.name = name
        self.kindRaw = kind.rawValue
        self.icon = icon
        self.colorHex = colorHex
        self.sortOrder = sortOrder
        self.isArchived = isArchived
    }

    var kind: CategoryKind {
        get { CategoryKind(rawValue: kindRaw) ?? .expense }
        set { kindRaw = newValue.rawValue }
    }
}
