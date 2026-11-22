import SwiftUI
import FinanceCore

/// A flattened, value-type snapshot of one `LedgerTransaction` — everything
/// the list needs to render, search, filter and group without touching the
/// model graph for every row.
struct TransactionListRow: Identifiable, Equatable {
    let id: UUID
    let kind: TransactionKind
    let amount: Int64
    let date: Date
    let note: String
    let needsReview: Bool
    let accountID: UUID?
    let accountName: String?
    let toAccountID: UUID?
    let toAccountName: String?
    let categoryID: UUID?
    let categoryName: String?
    let categoryIcon: String
    let categoryColorHex: String
    let businessID: UUID?
    let businessName: String?

    init(transaction: LedgerTransaction) {
        id = transaction.id
        kind = transaction.kind
        amount = transaction.amount
        date = transaction.date
        note = transaction.note
        needsReview = transaction.needsReview
        accountID = transaction.account?.id
        accountName = transaction.account?.name
        toAccountID = transaction.toAccount?.id
        toAccountName = transaction.toAccount?.name
        categoryID = transaction.category?.id
        categoryName = transaction.category?.name
        categoryIcon = transaction.category?.icon ?? ""
        categoryColorHex = transaction.category?.colorHex ?? ""
        businessID = transaction.business?.id
        businessName = transaction.business?.name
    }

    /// Memberwise init for tests and previews.
    init(
        id: UUID = UUID(),
        kind: TransactionKind,
        amount: Int64,
        date: Date,
        note: String = "",
        needsReview: Bool = false,
        accountID: UUID? = nil,
        accountName: String? = nil,
        toAccountID: UUID? = nil,
        toAccountName: String? = nil,
        categoryID: UUID? = nil,
        categoryName: String? = nil,
        categoryIcon: String = "",
        categoryColorHex: String = "",
        businessID: UUID? = nil,
        businessName: String? = nil
    ) {
        self.id = id
        self.kind = kind
        self.amount = amount
        self.date = date
        self.note = note
        self.needsReview = needsReview
        self.accountID = accountID
        self.accountName = accountName
        self.toAccountID = toAccountID
        self.toAccountName = toAccountName
        self.categoryID = categoryID
        self.categoryName = categoryName
        self.categoryIcon = categoryIcon
        self.categoryColorHex = categoryColorHex
        self.businessID = businessID
        self.businessName = businessName
    }

    /// Transfer badge color mirrors `AppTheme.transfer` (a Color, not hex).
    static let transferColorHex = "64748B"
    static let uncategorizedColorHex = "8E8E93"
    static let transferSymbol = "arrow.left.arrow.right"
    static let uncategorizedSymbol = "questionmark"

    /// Nil when there is no usable category name ("" treated as missing).
    var displayCategoryName: String? {
        guard let categoryName, !categoryName.isEmpty else { return nil }
        return categoryName
    }

    /// Category name, "Chuyển khoản" for transfers, else "Chưa phân loại".
    var title: String {
        if kind == .transfer { return "Chuyển khoản" }
        return displayCategoryName ?? "Chưa phân loại"
    }

    var badgeSymbol: String {
        if kind == .transfer { return Self.transferSymbol }
        return displayCategoryName == nil ? Self.uncategorizedSymbol : categoryIcon
    }

    var badgeColorHex: String {
        if kind == .transfer { return Self.transferColorHex }
        return displayCategoryName == nil ? Self.uncategorizedColorHex : categoryColorHex
    }

    /// "ghi chú · tài khoản · kinh doanh" — with "A → B" for transfers.
    var subtitle: String {
        var parts: [String] = []
        if !note.isEmpty { parts.append(note) }
        if kind == .transfer {
            let names = [accountName, toAccountName].compactMap { $0 }
            if !names.isEmpty { parts.append(names.joined(separator: " → ")) }
        } else if let accountName {
            parts.append(accountName)
        }
        if let businessName { parts.append(businessName) }
        return parts.joined(separator: " · ")
    }
}

/// One row in the transactions list: icon, title, subtitle and a signed,
/// colored amount with the time of day.
struct TransactionListRowView: View {
    let row: TransactionListRow

    var body: some View {
        HStack(spacing: 12) {
            IconBadge(symbol: row.badgeSymbol, colorHex: row.badgeColorHex, size: 40)

            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(row.title)
                        .font(.body)
                        .lineLimit(1)
                    if row.needsReview {
                        reviewTag
                    }
                }
                if !row.subtitle.isEmpty {
                    Text(row.subtitle)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }

            Spacer(minLength: 8)

            VStack(alignment: .trailing, spacing: 2) {
                AmountText(amount: row.amount, kind: row.kind)
                    .font(.subheadline.weight(.semibold))
                    .lineLimit(1)
                    .minimumScaleFactor(0.6)
                Text(AppDateFormat.time(row.date))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.vertical, 2)
    }

    private var reviewTag: some View {
        Text("Chờ phân loại")
            .font(.caption2.weight(.medium))
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(Color.orange.opacity(0.15), in: Capsule())
            .foregroundStyle(.orange)
            .lineLimit(1)
    }
}

#Preview {
    List {
        TransactionListRowView(row: TransactionListRow(
            kind: .expense, amount: 125_000, date: .now,
            note: "Ăn trưa", accountName: "Tiền mặt",
            categoryName: "Ăn uống", categoryIcon: "fork.knife",
            categoryColorHex: "FF9500"
        ))
        TransactionListRowView(row: TransactionListRow(
            kind: .transfer, amount: 2_000_000, date: .now,
            accountName: "Tiền mặt", toAccountName: "Ngân hàng"
        ))
        TransactionListRowView(row: TransactionListRow(
            kind: .income, amount: 5_000_000, date: .now,
            needsReview: true,
            accountName: "Ngân hàng", businessName: "Căn hộ dịch vụ"
        ))
    }
    .listStyle(.insetGrouped)
}
