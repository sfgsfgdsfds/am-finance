import SwiftUI
import SwiftData
import FinanceCore

/// Manage auto-categorization rules: listed in priority order (the first
/// match wins), add, edit, drag to reorder, swipe to delete. Rules live in
/// UserDefaults — this view reads and writes them through the store.
/// Pushed inside an existing NavigationStack.
struct WalletSyncRulesView: View {
    @Query(sort: \LedgerCategory.sortOrder) private var categories: [LedgerCategory]
    @Query(sort: \Business.sortOrder) private var businesses: [Business]
    @Query(sort: \Account.sortOrder) private var accounts: [Account]

    private let store: any WalletSyncRuleStoring

    @State private var rules: [WalletSyncRule] = []
    @State private var editing: WalletSyncRule?
    @State private var showsAdd = false

    init(store: (any WalletSyncRuleStoring)? = nil) {
        self.store = store ?? WalletSyncRuleStore()
    }

    var body: some View {
        List {
            if rules.isEmpty {
                EmptyStateView(
                    symbol: "checklist",
                    title: "Chưa có quy tắc",
                    message: "Quy tắc tự động gán danh mục, gán kinh doanh hoặc đổi thành chuyển khoản nội bộ cho giao dịch khớp từ khoá."
                )
                .listRowSeparator(.hidden)
                .listRowBackground(Color.clear)
            } else {
                Section {
                    ForEach(rules) { rule in
                        row(rule)
                    }
                    .onMove(perform: move)
                    .onDelete(perform: delete)
                } footer: {
                    Text("Quy tắc trên được áp dụng trước — kéo để đổi thứ tự ưu tiên.")
                }
            }
        }
        .listStyle(.insetGrouped)
        .navigationTitle("Quy tắc tự động")
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button {
                    showsAdd = true
                } label: {
                    Label("Thêm quy tắc", systemImage: "plus")
                }
            }
            if rules.count > 1 {
                ToolbarItem(placement: .topBarTrailing) {
                    EditButton()
                }
            }
        }
        .onAppear(perform: reload)
        .sheet(isPresented: $showsAdd) {
            WalletSyncRuleEditView(store: store, onSaved: { _ in reload() })
        }
        .sheet(item: $editing) { rule in
            WalletSyncRuleEditView(
                rule: rule, store: store, onSaved: { _ in reload() })
        }
    }

    private func row(_ rule: WalletSyncRule) -> some View {
        Button {
            editing = rule
        } label: {
            HStack(spacing: 12) {
                IconBadge(
                    symbol: symbol(for: rule),
                    colorHex: targetExists(rule) ? "0A84FF" : "FF9500",
                    size: 32)
                VStack(alignment: .leading, spacing: 2) {
                    Text("\"\(rule.keyword)\"")
                        .foregroundStyle(.primary)
                    Text(subtitle(for: rule))
                        .font(.caption)
                        .foregroundStyle(
                            targetExists(rule) ? Color.secondary : Color.orange)
                }
                Spacer()
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .swipeActions(edge: .trailing) {
            Button(role: .destructive) {
                if let index = rules.firstIndex(of: rule) {
                    rules.remove(at: index)
                    persist()
                }
            } label: {
                Label("Xoá", systemImage: "trash")
            }
        }
    }

    private func symbol(for rule: WalletSyncRule) -> String {
        switch rule.action {
        case .category(let id):
            return categories.first { $0.id == id }?.icon ?? "tag.fill"
        case .business(let id):
            return businesses.first { $0.id == id }?.icon ?? "briefcase.fill"
        case .transfer:
            return "arrow.left.arrow.right"
        }
    }

    /// e.g. "Tiền ra · Danh mục: Ăn uống" — dead targets read "đã xoá".
    private func subtitle(for rule: WalletSyncRule) -> String {
        var parts: [String] = []
        if rule.direction != .any {
            parts.append(rule.direction.displayName)
        }
        switch rule.action {
        case .category(let id):
            let name = categories.first { $0.id == id }?.name ?? "đã xoá"
            parts.append("Danh mục: \(name)")
        case .business(let id):
            let name = businesses.first { $0.id == id }?.name ?? "đã xoá"
            parts.append("Kinh doanh: \(name)")
        case .transfer(let id):
            let name = accounts.first { $0.id == id }?.name ?? "đã xoá"
            parts.append("Chuyển khoản → \(name)")
        }
        return parts.joined(separator: " · ")
    }

    private func targetExists(_ rule: WalletSyncRule) -> Bool {
        switch rule.action {
        case .category(let id): return categories.contains { $0.id == id }
        case .business(let id): return businesses.contains { $0.id == id }
        case .transfer(let id): return accounts.contains { $0.id == id }
        }
    }

    private func move(from source: IndexSet, to destination: Int) {
        rules = SettingsReorder.moved(rules, from: source, to: destination)
        persist()
    }

    private func delete(at offsets: IndexSet) {
        rules.remove(atOffsets: offsets)
        persist()
    }

    private func persist() {
        store.saveRules(rules)
    }

    private func reload() {
        rules = store.loadRules()
    }
}

#Preview {
    let container = try! AppModelContainer.make(inMemory: true)
    let context = ModelContext(container)
    try! SeedData.seedIfNeeded(context: context)
    let categories = try! context.fetch(FetchDescriptor<LedgerCategory>())
    let store = WalletSyncInMemoryRuleStore(rules: [
        WalletSyncRule(
            keyword: "grab", direction: .moneyOut,
            action: .category(categories.first { $0.name == "Di chuyển" }!.id)),
        WalletSyncRule(
            keyword: "luong", direction: .moneyIn,
            action: .category(categories.first { $0.kind == .income }!.id)),
        WalletSyncRule(
            keyword: "deleted", direction: .any,
            action: .category(UUID())),
    ])
    return NavigationStack {
        WalletSyncRulesView(store: store)
    }
    .modelContainer(container)
}
