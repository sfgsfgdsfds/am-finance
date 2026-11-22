import Foundation
import FinanceCore

/// What a new budget can watch — the overall personal spend or one
/// expense category. The create form only offers targets that do not
/// have a budget yet.
enum BudgetsTarget: Hashable, Sendable {
    case overall
    case category(UUID)

    /// Options for the create form: `.overall` first (when no budget has
    /// `category == nil`), then every non-archived expense category still
    /// without a budget, in the order `categories` arrives.
    static func available(
        categories: [LedgerCategory],
        budgetedCategoryIDs: Set<UUID?>
    ) -> [BudgetsTarget] {
        var result: [BudgetsTarget] = []
        if !budgetedCategoryIDs.contains(nil) {
            result.append(.overall)
        }
        for category in categories
        where !category.isArchived && category.kind == .expense
            && !budgetedCategoryIDs.contains(category.id) {
            result.append(.category(category.id))
        }
        return result
    }
}

/// Edit-form state for a `Budget` — amount in đồng, the active flag and
/// the note. Validation and model mapping live here (no SwiftUI) so
/// tests can drive them without a view; the watched `BudgetsTarget` is
/// chosen in the sheet and never changes on edit.
struct BudgetsDraft: Equatable {
    var amount: Int64
    var isActive: Bool
    var note: String

    init(amount: Int64 = 0, isActive: Bool = true, note: String = "") {
        self.amount = max(0, amount)
        self.isActive = isActive
        self.note = note
    }

    /// Edit mapping: copies an existing model's fields into the form.
    init(budget: Budget) {
        self.init(
            amount: budget.monthlyLimit,
            isActive: budget.isActive,
            note: budget.note
        )
    }

    var trimmedNote: String {
        note.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// A budget needs a strictly positive monthly limit.
    var isValid: Bool { amount > 0 }

    /// Writes the editable fields back onto an existing budget — the
    /// watched category is fixed at creation and deliberately not
    /// rewritten.
    func apply(to budget: Budget) {
        budget.monthlyLimit = amount
        budget.isActive = isActive
        budget.note = trimmedNote
    }

    /// Builds a new budget watching `category` (nil = the overall
    /// personal budget).
    func makeBudget(category: LedgerCategory?) -> Budget {
        Budget(
            monthlyLimit: amount,
            isActive: isActive,
            note: trimmedNote,
            category: category
        )
    }
}
