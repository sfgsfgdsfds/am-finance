import Foundation
import SwiftData

/// A monthly spending cap ("hạn mức") in đồng. `category == nil` is the
/// overall monthly budget, which counts every expense of the month; the
/// evaluation math lives in `BudgetMath` (FinanceCore).
@Model
final class Budget {
    var id: UUID = UUID()
    /// Monthly cap in đồng.
    var monthlyLimit: Int64 = 0
    var isActive: Bool = true
    var note: String = ""
    var createdAt: Date = Date.now

    /// The expense category this cap watches; nil = overall budget.
    var category: LedgerCategory?

    init(
        id: UUID = UUID(),
        monthlyLimit: Int64,
        isActive: Bool = true,
        note: String = "",
        category: LedgerCategory? = nil
    ) {
        self.id = id
        self.monthlyLimit = monthlyLimit
        self.isActive = isActive
        self.note = note
        self.category = category
    }
}
