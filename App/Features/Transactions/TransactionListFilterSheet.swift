import SwiftUI
import SwiftData
import FinanceCore

/// The filter form for the transactions list. Edits the shared
/// `TransactionListFilter` binding live, so the chips and the list update
/// as the user taps. Archived accounts/categories/businesses stay
/// selectable — their history still exists.
struct TransactionListFilterSheet: View {
    @Binding var filter: TransactionListFilter
    let accounts: [Account]
    let categories: [LedgerCategory]
    let businesses: [Business]

    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            Form {
                Section("Loại giao dịch") {
                    Picker("Loại", selection: $filter.kind) {
                        Text("Tất cả").tag(TransactionKind?.none)
                        Text("Thu").tag(TransactionKind?.some(.income))
                        Text("Chi").tag(TransactionKind?.some(.expense))
                        Text("Chuyển").tag(TransactionKind?.some(.transfer))
                    }
                    .pickerStyle(.segmented)
                    .labelsHidden()
                }

                Section("Tài khoản") {
                    optionRow("Tất cả", selected: filter.accountID == nil) {
                        filter.accountID = nil
                    }
                    ForEach(accounts, id: \.id) { account in
                        optionRow(
                            account.name,
                            symbol: account.icon,
                            colorHex: account.colorHex,
                            selected: filter.accountID == account.id
                        ) {
                            filter.accountID = account.id
                        }
                    }
                }

                categorySection(kind: .expense, title: "Danh mục chi")
                categorySection(kind: .income, title: "Danh mục thu")

                Section("Kinh doanh") {
                    optionRow("Tất cả", selected: filter.business == .any) {
                        filter.business = .any
                    }
                    optionRow(
                        "Cá nhân",
                        symbol: "person.fill",
                        colorHex: "8E8E93",
                        selected: filter.business == .personal
                    ) {
                        filter.business = .personal
                    }
                    ForEach(businesses, id: \.id) { business in
                        optionRow(
                            business.name,
                            symbol: business.icon,
                            colorHex: business.colorHex,
                            selected: filter.business == .business(business.id)
                        ) {
                            filter.business = .business(business.id)
                        }
                    }
                }

                Section {
                    Toggle(
                        "Chỉ giao dịch chờ phân loại",
                        isOn: $filter.onlyNeedsReview
                    )
                }

                if filter.isActive {
                    Section {
                        Button(role: .destructive) {
                            filter.reset()
                        } label: {
                            Text("Xoá bộ lọc")
                                .frame(maxWidth: .infinity)
                        }
                    }
                }
            }
            .navigationTitle("Bộ lọc")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Xong") { dismiss() }
                }
            }
        }
        .presentationDetents([.medium, .large])
    }

    @ViewBuilder
    private func categorySection(kind: CategoryKind, title: String) -> some View {
        let rows = categories.filter { $0.kind == kind }
        if !rows.isEmpty {
            Section(title) {
                ForEach(rows, id: \.id) { category in
                    optionRow(
                        category.name,
                        symbol: category.icon,
                        colorHex: category.colorHex,
                        selected: filter.categoryID == category.id
                    ) {
                        filter.categoryID = category.id
                    }
                }
            }
        }
    }

    private func optionRow(
        _ title: String,
        symbol: String? = nil,
        colorHex: String = "",
        selected: Bool,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            HStack(spacing: 10) {
                if let symbol {
                    IconBadge(symbol: symbol, colorHex: colorHex, size: 26)
                }
                Text(title)
                    .foregroundStyle(.primary)
                Spacer()
                if selected {
                    Image(systemName: "checkmark")
                        .foregroundStyle(Color.accentColor)
                        .font(.body.weight(.semibold))
                }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}

#Preview {
    @Previewable @State var filter = TransactionListFilter(
        kind: .expense, onlyNeedsReview: true
    )
    let container = try! AppModelContainer.make(inMemory: true)
    let context = ModelContext(container)
    try! SeedData.seedIfNeeded(context: context)
    return TransactionListFilterSheet(
        filter: $filter,
        accounts: try! context.fetch(FetchDescriptor<Account>()),
        categories: try! context.fetch(FetchDescriptor<LedgerCategory>()),
        businesses: try! context.fetch(FetchDescriptor<Business>())
    )
}
