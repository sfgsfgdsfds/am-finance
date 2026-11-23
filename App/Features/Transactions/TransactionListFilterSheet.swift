import SwiftUI
import SwiftData
import FinanceCore

/// The filter form for the transactions list. Edits the shared
/// `TransactionListFilter` binding live, so the chips and the list update
/// as the user taps. Archived accounts/businesses stay selectable — their
/// history still exists. Category browsing lives on the scope strip, so
/// the sheet offers no competing category filter.
struct TransactionListFilterSheet: View {
    @Binding var filter: TransactionListFilter
    let accounts: [Account]
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
        businesses: try! context.fetch(FetchDescriptor<Business>())
    )
}
