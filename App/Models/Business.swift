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
