import Foundation
import SwiftData

/// An income stream such as a serviced apartment, web development or ad
/// agency work. A transaction with `business == nil` is personal.
@Model
final class Business {
    var id: UUID = UUID()
    var name: String = ""
    var icon: String = ""
    var colorHex: String = ""
    var note: String = ""
    var sortOrder: Int = 0
    var isArchived: Bool = false

    @Relationship(deleteRule: .nullify, inverse: \LedgerTransaction.business)
    var transactions: [LedgerTransaction]? = []

    @Relationship(deleteRule: .nullify, inverse: \RecurringRule.business)
    var recurringRules: [RecurringRule]? = []

    /// Client receivable accounts bound to this business ("Phải thu") —
    /// `.nullify` keeps the schema CloudKit-compatible: deleting a business
    /// leaves its receivable accounts behind as personal clients.
    @Relationship(deleteRule: .nullify, inverse: \Account.business)
    var accounts: [Account]? = []

    init(
        id: UUID = UUID(),
        name: String,
        icon: String = "",
        colorHex: String = "",
        note: String = "",
        sortOrder: Int = 0,
        isArchived: Bool = false
    ) {
        self.id = id
        self.name = name
        self.icon = icon
        self.colorHex = colorHex
        self.note = note
        self.sortOrder = sortOrder
        self.isArchived = isArchived
    }
}
