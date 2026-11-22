import SwiftUI
import SwiftData
import FinanceCore

/// Editable state behind `WalletSyncRuleEditView` — plain values so
/// validation and the rule mapping stay testable without a view.
struct WalletSyncRuleDraft: Equatable {
    /// Which action the rule performs — the target id lives next to it.
    enum ActionKind: String, CaseIterable, Sendable {
        case category
        case business
        case transfer

        var displayName: String {
            switch self {
            case .category: return "Gán danh mục"
            case .business: return "Gán kinh doanh"
            case .transfer: return "Chuyển khoản nội bộ"
            }
        }
    }

    var keyword = ""
    var direction: WalletSyncRuleDirection = .any
    var actionKind: ActionKind = .category
    var categoryID: UUID?
    var businessID: UUID?
    var accountID: UUID?

    init() {}

    /// Create-mode prefill, e.g. from an inbox row's note and direction.
    init(keyword: String, direction: WalletSyncRuleDirection) {
        self.keyword = keyword
        self.direction = direction
    }

    /// Edit mode: every field copied off the stored rule.
    init(rule: WalletSyncRule) {
        keyword = rule.keyword
        direction = rule.direction
        switch rule.action {
        case .category(let id):
            actionKind = .category
            categoryID = id
        case .business(let id):
            actionKind = .business
            businessID = id
        case .transfer(let id):
            actionKind = .transfer
            accountID = id
        }
    }

    var trimmedKeyword: String {
        keyword.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// The stored action, or nil while the matching target is unchosen.
    var action: WalletSyncRuleAction? {
        switch actionKind {
        case .category:
            return categoryID.map { .category($0) }
        case .business:
            return businessID.map { .business($0) }
        case .transfer:
            return accountID.map { .transfer($0) }
        }
    }

    var isValid: Bool {
        !trimmedKeyword.isEmpty && action != nil
    }

    /// Builds the stored rule; `id` reuses the edited rule's id on edit.
    func makeRule(id: UUID = UUID()) -> WalletSyncRule? {
        guard isValid, let action else { return nil }
        return WalletSyncRule(
            id: id,
            keyword: trimmedKeyword,
            direction: direction,
            action: action
        )
    }
}

/// Sheet to create or edit one sync rule. Writes straight into the rule
/// store and reports the saved rule through `onSaved` — the inbox uses
/// that hook to re-apply rules to pending rows.
struct WalletSyncRuleEditView: View {
    @Environment(\.dismiss) private var dismiss
    @Query(sort: \LedgerCategory.sortOrder) private var categories: [LedgerCategory]
    @Query(sort: \Business.sortOrder) private var businesses: [Business]
    @Query(sort: \Account.sortOrder) private var accounts: [Account]

    private let ruleID: UUID?
    private let store: any WalletSyncRuleStoring
    private let onSaved: ((WalletSyncRule) -> Void)?
    @State private var draft: WalletSyncRuleDraft

    init(
        rule: WalletSyncRule? = nil,
        draft: WalletSyncRuleDraft? = nil,
        store: (any WalletSyncRuleStoring)? = nil,
        onSaved: ((WalletSyncRule) -> Void)? = nil
    ) {
        self.ruleID = rule?.id
        self.store = store ?? WalletSyncRuleStore()
        self.onSaved = onSaved
        _draft = State(initialValue: draft
            ?? rule.map { WalletSyncRuleDraft(rule: $0) }
            ?? WalletSyncRuleDraft())
    }

    private var isNew: Bool { ruleID == nil }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField("Từ khoá trong ghi chú", text: $draft.keyword)
                } header: {
                    Text("Từ khoá")
                } footer: {
                    Text("Khớp khi ghi chú ngân hàng chứa từ khoá này — không phân biệt hoa thường hay dấu.")
                }

                Section("Hướng tiền") {
                    Picker("Hướng tiền", selection: $draft.direction) {
                        ForEach(WalletSyncRuleDirection.allCases, id: \.self) { direction in
                            Text(direction.displayName).tag(direction)
                        }
                    }
                    .pickerStyle(.segmented)
                    .labelsHidden()
                }

                Section("Hành động") {
                    Picker("Hành động", selection: $draft.actionKind) {
                        ForEach(WalletSyncRuleDraft.ActionKind.allCases, id: \.self) { kind in
                            Text(kind.displayName).tag(kind)
                        }
                    }
                    .labelsHidden()
                }

                switch draft.actionKind {
                case .category:
                    categorySection
                case .business:
                    businessSection
                case .transfer:
                    transferSection
                }
            }
            .navigationTitle(isNew ? "Quy tắc mới" : "Sửa quy tắc")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Huỷ") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button(isNew ? "Thêm" : "Lưu", action: save)
                        .disabled(!draft.isValid)
                }
            }
        }
    }

    // MARK: - Action sections

    /// Direction-compatible categories: a money-in rule can only pick an
    /// income category (and vice versa); "Tất cả" offers both.
    private var visibleCategories: [LedgerCategory] {
        categories.filter { category in
            !category.isArchived
                && (draft.direction == .any
                    || (category.kind == .income) == (draft.direction == .moneyIn))
        }
    }

    private var categorySection: some View {
        Section("Danh mục") {
            Picker(selection: $draft.categoryID) {
                Text("Chọn danh mục").tag(UUID?.none)
                ForEach(visibleCategories, id: \.id) { category in
                    Label {
                        Text(category.name)
                    } icon: {
                        IconBadge(
                            symbol: category.icon,
                            colorHex: category.colorHex, size: 28)
                    }
                    .tag(category.id as UUID?)
                }
            } label: {
                Text("Danh mục")
            }
            .pickerStyle(.navigationLink)
        }
    }

    private var businessSection: some View {
        Section("Kinh doanh") {
            Picker(selection: $draft.businessID) {
                Text("Chọn mảng kinh doanh").tag(UUID?.none)
                ForEach(businesses.filter { !$0.isArchived }, id: \.id) { business in
                    Label {
                        Text(business.name)
                    } icon: {
                        IconBadge(
                            symbol: business.icon,
                            colorHex: business.colorHex, size: 28)
                    }
                    .tag(business.id as UUID?)
                }
            } label: {
                Text("Kinh doanh")
            }
            .pickerStyle(.navigationLink)
        }
    }

    private var transferSection: some View {
        Section {
            Picker(selection: $draft.accountID) {
                Text("Chọn tài khoản").tag(UUID?.none)
                ForEach(accounts.filter { !$0.isArchived }, id: \.id) { account in
                    Label {
                        Text(account.name)
                    } icon: {
                        IconBadge(
                            symbol: account.icon,
                            colorHex: account.colorHex, size: 28)
                    }
                    .tag(account.id as UUID?)
                }
            } label: {
                Text("Tài khoản đối ứng")
            }
            .pickerStyle(.navigationLink)
        } footer: {
            Text("Giao dịch khớp sẽ trở thành chuyển khoản nội bộ với tài khoản này.")
        }
    }

    private func save() {
        guard let rule = draft.makeRule(id: ruleID ?? UUID()) else { return }
        var rules = store.loadRules()
        if let index = rules.firstIndex(where: { $0.id == rule.id }) {
            rules[index] = rule
        } else {
            rules.append(rule)
        }
        store.saveRules(rules)
        onSaved?(rule)
        dismiss()
    }
}

#Preview {
    let container = try! AppModelContainer.make(inMemory: true)
    try! SeedData.seedIfNeeded(context: ModelContext(container))
    return WalletSyncRuleEditView(
        draft: WalletSyncRuleDraft(keyword: "GRAB", direction: .moneyOut))
        .modelContainer(container)
}
