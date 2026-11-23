import Foundation
import FinanceCore

/// The browsing scope of the transactions list — which slice of the loaded
/// rows the list is showing. Picked in the always-visible scope strip; the
/// advanced `TransactionListFilter` is then ANDed on top inside that slice.
/// `unclassified` is the default: it doubles as the review queue for both
/// manual entries and imports.
enum TransactionListScope: Equatable {
    /// Non-transfer rows missing a category OR still flagged
    /// `needsReview` — an imported row the rules already assigned a
    /// category to stays in this queue until the review flag clears.
    case unclassified
    /// Every kind — the combined history. Also the only scope that shows
    /// the monthly Thu/Chi/Chênh lệch totals.
    case all
    /// Transfers only. A transfer never lands in the unclassified queue
    /// just for carrying no category.
    case transfers
    /// Non-transfer rows already classified into this category —
    /// `needsReview` rows stay in the unclassified queue until reviewed.
    case category(UUID)

    /// Whether `row` belongs to this scope.
    func matches(_ row: TransactionListRow) -> Bool {
        switch self {
        case .all:
            return true
        case .transfers:
            return row.kind == .transfer
        case .unclassified:
            return row.kind != .transfer
                && (row.categoryID == nil || row.needsReview)
        case .category(let id):
            return row.kind != .transfer
                && !row.needsReview
                && row.categoryID == id
        }
    }

    /// The combined-month aggregate only makes sense over every kind.
    var showsMonthTotals: Bool { self == .all }
}

/// One category tab in the scope strip — identity is the category id, so a
/// renamed category keeps its tab and its selection.
struct TransactionListScopeItem: Identifiable, Equatable {
    let id: UUID
    let name: String
    let icon: String
    let colorHex: String
}

/// Pure helpers for the scope strip: which category tabs exist for a slice
/// of history, and which scope to render when the selection went stale.
enum TransactionListScopes {

    /// One tab per category that actually appears on a classified
    /// (non-transfer, not `needsReview`) transaction in `transactions` —
    /// never one per seeded-but-unused category. Order follows
    /// `categories` (the sort-order query). `pinned` keeps a selected
    /// category's tab rendered when this slice has no rows for it, so the
    /// selection stays readable instead of silently unfiltering.
    static func categoryItems(
        in transactions: [LedgerTransaction],
        categories: [LedgerCategory],
        pinned: UUID? = nil
    ) -> [TransactionListScopeItem] {
        var used = Set<UUID>()
        for transaction in transactions {
            guard transaction.kind != .transfer,
                  !transaction.needsReview,
                  let id = transaction.category?.id else { continue }
            used.insert(id)
        }
        return categories.compactMap { category in
            guard used.contains(category.id) || category.id == pinned else {
                return nil
            }
            return TransactionListScopeItem(
                id: category.id, name: category.name,
                icon: category.icon, colorHex: category.colorHex
            )
        }
    }

    /// The scope to actually render: a `.category` selection whose
    /// category no longer exists at all (deleted — its rows were nullified
    /// into the unclassified queue) intentionally resets to
    /// `.unclassified`. A category that merely has no rows in this slice
    /// passes through so the strip can pin it and the empty state can
    /// still name it.
    static func resolving(
        _ scope: TransactionListScope,
        categories: [LedgerCategory]
    ) -> TransactionListScope {
        guard case .category(let id) = scope else { return scope }
        return categories.contains { $0.id == id } ? scope : .unclassified
    }
}
