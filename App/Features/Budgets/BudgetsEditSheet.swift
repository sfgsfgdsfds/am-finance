import SwiftUI
import SwiftData
import FinanceCore

/// Add/edit sheet for one `Budget` (nil = create). The watched target —
/// "Tổng chi tiêu cá nhân" or an expense category that has no budget
/// yet — is picked on create and stays fixed on edit. The amount is
/// typed on `AmountKeypad`; a chip fills the three-month average from
/// history. Owns its NavigationStack, like every sheet.
struct BudgetsEditSheet: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.modelContext) private var modelContext

    @Query(sort: \LedgerCategory.sortOrder) private var categories: [LedgerCategory]
    @Query(sort: \Budget.createdAt) private var budgets: [Budget]
    /// Expenses of the three calendar months preceding `month` — the
    /// suggestion chip's history window.
    @Query private var history: [LedgerTransaction]

    private let budget: Budget?
    /// A date inside the displayed month — the suggestion looks at the
    /// three calendar months before it.
    private let month: Date
    @State private var draft: BudgetsDraft
    @State private var target: BudgetsTarget
    @State private var deleteConfirmationShown = false

    init(budget: Budget? = nil, month: Date) {
        self.budget = budget
        self.month = month
        _draft = State(initialValue: budget.map(BudgetsDraft.init) ?? BudgetsDraft())
        _target = State(initialValue: .overall)
        let calendar = AppCalendar.vietnam
        let monthStart = ReportSummary.monthInterval(
            containing: month, calendar: calendar).start
        let windowStart = calendar.date(
            byAdding: .month, value: -3, to: monthStart) ?? monthStart
        let expense = TransactionKind.expense.rawValue
        _history = Query(FetchDescriptor<LedgerTransaction>(
            predicate: #Predicate {
                $0.date >= windowStart && $0.date < monthStart
                    && $0.kindRaw == expense
            }
        ))
    }

    private var isNew: Bool { budget == nil }

    private var budgetedCategoryIDs: Set<UUID?> {
        Set(budgets.map { $0.category?.id })
    }

    private var availableTargets: [BudgetsTarget] {
        BudgetsTarget.available(
            categories: categories, budgetedCategoryIDs: budgetedCategoryIDs)
    }

    private var canSave: Bool {
        draft.isValid && (!isNew || availableTargets.contains(target))
    }

    /// The scope the suggestion mirrors — the same counting rule the
    /// budget itself applies.
    private var suggestion: Int64? {
        let scope: BudgetsSuggestion.Scope
        if let budget {
            scope = budget.category.map { .category($0.id) } ?? .personal
        } else {
            switch target {
            case .overall: scope = .personal
            case .category(let id): scope = .category(id)
            }
        }
        return BudgetsSuggestion.monthlyAverage(
            spends: history.map {
                .init(
                    categoryID: $0.category?.id, date: $0.date,
                    amount: $0.amount, isBusiness: $0.business != nil)
            },
            scope: scope,
            forMonth: month,
            calendar: AppCalendar.vietnam
        )
    }

    private var countsPersonalOnly: Bool {
        if let budget { return budget.category == nil }
        return target == .overall
    }

    private var editedVisual: BudgetsSnapshot.Visual {
        if let category = budget?.category {
            return .init(
                name: category.name, icon: category.icon,
                colorHex: category.colorHex)
        }
        return .overall
    }

    var body: some View {
        NavigationStack {
            Form {
                targetSection
                amountSection
                Section {
                    Toggle("Đang áp dụng", isOn: $draft.isActive)
                    TextField("Ghi chú", text: $draft.note)
                }
                if !isNew {
                    Section {
                        Button(role: .destructive) {
                            deleteConfirmationShown = true
                        } label: {
                            Text("Xoá ngân sách")
                                .frame(maxWidth: .infinity)
                        }
                    }
                }
            }
            .navigationTitle(isNew ? "Ngân sách mới" : "Sửa ngân sách")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Huỷ") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button(isNew ? "Thêm" : "Lưu", action: save)
                        .disabled(!canSave)
                }
            }
            .confirmationDialog(
                "Xoá ngân sách này?",
                isPresented: $deleteConfirmationShown,
                titleVisibility: .visible
            ) {
                Button("Xoá ngân sách", role: .destructive, action: deleteBudget)
                Button("Huỷ", role: .cancel) {}
            } message: {
                Text("Thao tác này không thể hoàn tác.")
            }
            .onAppear(perform: normalizeTarget)
        }
    }

    // MARK: - Sections

    private var targetSection: some View {
        Section {
            if isNew {
                if availableTargets.isEmpty {
                    Text("Tất cả danh mục chi đều đã có ngân sách.")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                } else {
                    Picker(selection: $target) {
                        ForEach(availableTargets, id: \.self) { option in
                            targetLabel(option)
                                .tag(option)
                        }
                    } label: {
                        Text("Áp dụng cho")
                    }
                    .pickerStyle(.navigationLink)
                }
            } else {
                Label {
                    Text(editedVisual.name)
                } icon: {
                    IconBadge(
                        symbol: editedVisual.icon,
                        colorHex: editedVisual.colorHex, size: 28)
                }
            }
        } footer: {
            Text(countsPersonalOnly
                ? "Chỉ tính các khoản chi cá nhân (không gắn kinh doanh)."
                : "Tính mọi khoản chi của danh mục, kể cả chi tiêu kinh doanh.")
        }
    }

    @ViewBuilder
    private func targetLabel(_ option: BudgetsTarget) -> some View {
        switch option {
        case .overall:
            Label {
                Text("Tổng chi tiêu cá nhân")
            } icon: {
                IconBadge(
                    symbol: BudgetsSnapshot.Visual.overall.icon,
                    colorHex: BudgetsSnapshot.Visual.overall.colorHex, size: 28)
            }
        case .category(let id):
            if let category = categories.first(where: { $0.id == id }) {
                Label {
                    Text(category.name)
                } icon: {
                    IconBadge(
                        symbol: category.icon, colorHex: category.colorHex,
                        size: 28)
                }
            }
        }
    }

    private var amountSection: some View {
        Section {
            AmountKeypad(amount: $draft.amount)
                .padding(.vertical, 4)
                .listRowInsets(EdgeInsets(
                    top: 8, leading: 12, bottom: 8, trailing: 12))
            if let suggestion {
                Button {
                    draft.amount = suggestion
                } label: {
                    Text(
                        "Trung bình 3 tháng gần nhất: \(VND.format(suggestion))"
                    )
                    .font(.caption.weight(.medium))
                    .padding(.horizontal, 10)
                    .padding(.vertical, 6)
                    .background(Color.accentColor.opacity(0.12), in: Capsule())
                }
                .buttonStyle(.plain)
                .foregroundStyle(Color.accentColor)
                .accessibilityHint("Chạm để điền số tiền này")
            }
        } header: {
            Text("Hạn mức hàng tháng")
        }
    }

    // MARK: - Actions

    private var targetCategory: LedgerCategory? {
        guard case .category(let id) = target else { return nil }
        return categories.first { $0.id == id }
    }

    private func save() {
        guard canSave else { return }
        if let budget {
            draft.apply(to: budget)
        } else {
            modelContext.insert(draft.makeBudget(category: targetCategory))
        }
        try? modelContext.save()
        dismiss()
    }

    private func deleteBudget() {
        guard let budget else { return }
        modelContext.delete(budget)
        try? modelContext.save()
        dismiss()
    }

    /// Keeps the create-mode target inside the offered options — e.g.
    /// when the overall slot is already taken the picker's first entry
    /// wins instead.
    private func normalizeTarget() {
        guard isNew, !availableTargets.isEmpty,
              !availableTargets.contains(target) else { return }
        target = availableTargets[0]
    }
}

#Preview("Tạo mới") {
    let container = try! AppModelContainer.make(inMemory: true)
    let context = ModelContext(container)
    try! SeedData.seedIfNeeded(context: context)
    return BudgetsEditSheet(month: .now)
        .modelContainer(container)
}

#Preview("Sửa") {
    let container = try! AppModelContainer.make(inMemory: true)
    let context = ModelContext(container)
    try! SeedData.seedIfNeeded(context: context)
    let category = try! context.fetch(FetchDescriptor<LedgerCategory>())
        .first { $0.kind == .expense }!
    let budget = Budget(monthlyLimit: 4_000_000, category: category)
    context.insert(budget)
    return BudgetsEditSheet(budget: budget, month: .now)
        .modelContainer(container)
}
