import SwiftUI
import SwiftData
import FinanceCore

/// Account list: a net-worth header card, one section per `AccountKind` with
/// a subtotal, and a collapsible "Đã lưu trữ" section. Pushed inside an
/// existing NavigationStack — it must not create its own.
struct AccountsListView: View {
    @Environment(\.modelContext) private var context
    @Query(sort: \Account.sortOrder) private var accounts: [Account]

    @State private var isCreating = false
    @State private var showsArchived = false
    @State private var pendingDelete: Account?

    init() {}

    var body: some View {
        Group {
            if accounts.isEmpty {
                EmptyStateView(
                    symbol: "creditcard.and.123",
                    title: "Chưa có tài khoản",
                    message: "Thêm tài khoản tiền mặt, ngân hàng, ví điện tử, thẻ tín dụng hoặc khoản vay để bắt đầu.",
                    actionTitle: "Thêm tài khoản",
                    action: { isCreating = true }
                )
            } else {
                list
            }
        }
        .navigationTitle("Tài khoản")
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button {
                    isCreating = true
                } label: {
                    Image(systemName: "plus")
                }
                .accessibilityLabel("Thêm tài khoản")
            }
        }
        .sheet(isPresented: $isCreating) {
            AccountEditView()
        }
        .alert(
            "Xoá tài khoản",
            isPresented: deleteAlertPresented,
            presenting: pendingDelete
        ) { account in
            if AccountGrouping.canDelete(account) {
                Button("Xoá", role: .destructive) {
                    context.delete(account)
                }
                Button("Huỷ", role: .cancel) {}
            } else {
                Button("Lưu trữ") {
                    account.isArchived = true
                }
                Button("Huỷ", role: .cancel) {}
            }
        } message: { account in
            if AccountGrouping.canDelete(account) {
                Text("Xoá \"\(account.name)\"? Thao tác này không thể hoàn tác.")
            } else {
                Text("\"\(account.name)\" đã có giao dịch nên không thể xoá. Bạn có thể lưu trữ để ẩn tài khoản này.")
            }
        }
    }

    private var deleteAlertPresented: Binding<Bool> {
        Binding(
            get: { pendingDelete != nil },
            set: { if !$0 { pendingDelete = nil } }
        )
    }

    private var archivedAccounts: [Account] {
        AccountGrouping.archived(from: accounts)
    }

    private var list: some View {
        List {
            Section {
                AccountNetWorthCard(accounts: accounts)
                    .listRowInsets(EdgeInsets(top: 8, leading: 4, bottom: 8, trailing: 4))
                    .listRowBackground(Color.clear)
            }

            ForEach(AccountGrouping.sections(from: accounts), id: \.kind) { section in
                Section {
                    ForEach(section.accounts, id: \.id) { account in
                        row(account)
                    }
                } header: {
                    HStack {
                        Text(section.kind.displayName)
                        Spacer()
                        AmountText(amount: section.subtotal)
                    }
                }
            }

            if !archivedAccounts.isEmpty {
                Section {
                    DisclosureGroup(isExpanded: $showsArchived) {
                        ForEach(archivedAccounts, id: \.id) { account in
                            row(account)
                        }
                    } label: {
                        HStack {
                            Text("Đã lưu trữ")
                            Spacer()
                            Text("\(archivedAccounts.count)")
                                .foregroundStyle(.secondary)
                                .monospacedDigit()
                        }
                    }
                }
            }
        }
        .listStyle(.insetGrouped)
    }

    private func row(_ account: Account) -> some View {
        NavigationLink {
            AccountDetailView(account: account)
        } label: {
            HStack(spacing: 12) {
                IconBadge(symbol: account.icon, colorHex: account.colorHex, size: 36)
                Text(account.name)
                Spacer()
                AmountText(amount: account.balance)
            }
        }
        .swipeActions(edge: .trailing, allowsFullSwipe: false) {
            Button(role: .destructive) {
                pendingDelete = account
            } label: {
                Label("Xoá", systemImage: "trash")
            }
            Button {
                account.isArchived.toggle()
            } label: {
                Label(
                    account.isArchived ? "Bỏ lưu trữ" : "Lưu trữ",
                    systemImage: account.isArchived ? "tray.and.arrow.up.fill" : "archivebox.fill"
                )
            }
            .tint(.orange)
        }
    }
}

/// Header card on the accounts list: total net worth plus the
/// assets/liabilities split. `NetWorth` skips archived accounts itself.
private struct AccountNetWorthCard: View {
    let accounts: [Account]

    var body: some View {
        VStack(spacing: 10) {
            Text("Tài sản ròng")
                .font(.subheadline)
                .foregroundStyle(.secondary)
            AmountText(amount: NetWorth.total(accounts))
                .font(.title.bold())

            HStack(spacing: 0) {
                column(title: "Tài sản", amount: NetWorth.assets(accounts))
                Divider().frame(height: 32)
                column(title: "Nợ", amount: NetWorth.liabilities(accounts))
            }
        }
        .padding(.vertical, 16)
        .padding(.horizontal, 12)
        .frame(maxWidth: .infinity)
        .background(
            Color(.secondarySystemGroupedBackground),
            in: RoundedRectangle(cornerRadius: 16)
        )
    }

    private func column(title: String, amount: Int64) -> some View {
        VStack(spacing: 2) {
            Text(title)
                .font(.caption)
                .foregroundStyle(.secondary)
            AmountText(amount: amount)
                .font(.headline)
        }
        .frame(maxWidth: .infinity)
    }
}

#Preview {
    let container = try! AppModelContainer.make(inMemory: true)
    let context = ModelContext(container)
    try! SeedData.seedIfNeeded(context: context)
    context.insert(Account(
        name: "Techcombank", kind: .bank,
        openingBalance: 25_000_000, colorHex: "0A84FF", sortOrder: 1
    ))
    let card = Account(
        name: "Thẻ Visa", kind: .creditCard,
        openingBalance: -3_500_000, colorHex: "FF9500", sortOrder: 2
    )
    card.creditLimit = 30_000_000
    context.insert(card)
    context.insert(Account(
        name: "Ví cũ", kind: .eWallet,
        openingBalance: 100_000, colorHex: "8E8E93", sortOrder: 3, isArchived: true
    ))
    return NavigationStack {
        AccountsListView()
    }
    .modelContainer(container)
}
