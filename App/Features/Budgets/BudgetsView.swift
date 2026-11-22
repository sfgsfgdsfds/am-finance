import SwiftUI
import SwiftData
import FinanceCore

/// The budgets screen ("Ngân sách"): monthly spending limits for the
/// overall personal spend and per expense category, evaluated against
/// the displayed month's expenses with warnings before a limit is
/// exceeded. Pushed inside an existing NavigationStack — it does not
/// create one. All evaluation comes from `BudgetsSnapshot`/`BudgetMath`.
struct BudgetsView: View {
    @Query(sort: \LedgerCategory.sortOrder) private var categories: [LedgerCategory]
    @Query(sort: \Budget.createdAt) private var budgets: [Budget]

    /// Always the first day of the displayed month — the switcher shifts it.
    @State private var monthAnchor: Date
    @State private var addShown = false
    @State private var editing: Budget?

    init() {
        let now = Date.now
        _monthAnchor = State(initialValue:
            AppCalendar.vietnam.dateInterval(of: .month, for: now)?.start ?? now)
    }

    var body: some View {
        BudgetsContent(
            monthAnchor: $monthAnchor,
            budgets: budgets,
            categories: categories,
            onAdd: { addShown = true },
            onEdit: { editing = $0 }
        )
        .navigationTitle("Ngân sách")
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button {
                    addShown = true
                } label: {
                    Image(systemName: "plus")
                }
                .accessibilityLabel("Thêm ngân sách")
            }
        }
        .sheet(isPresented: $addShown) {
            BudgetsEditSheet(month: monthAnchor)
        }
        .sheet(item: $editing) { budget in
            BudgetsEditSheet(budget: budget, month: monthAnchor)
        }
    }
}

/// The query-owning body of the budgets screen — re-initialized whenever
/// the displayed month changes so `@Query` refetches exactly that month's
/// expenses via a date-range predicate, never the whole table.
private struct BudgetsContent: View {
    @Query private var transactions: [LedgerTransaction]

    @Binding var monthAnchor: Date
    let budgets: [Budget]
    let categories: [LedgerCategory]
    let onAdd: () -> Void
    let onEdit: (Budget) -> Void

    init(
        monthAnchor: Binding<Date>,
        budgets: [Budget],
        categories: [LedgerCategory],
        onAdd: @escaping () -> Void,
        onEdit: @escaping (Budget) -> Void
    ) {
        _monthAnchor = monthAnchor
        self.budgets = budgets
        self.categories = categories
        self.onAdd = onAdd
        self.onEdit = onEdit

        let interval = ReportSummary.monthInterval(
            containing: monthAnchor.wrappedValue,
            calendar: AppCalendar.vietnam
        )
        let start = interval.start
        let end = interval.end
        let expense = TransactionKind.expense.rawValue
        _transactions = Query(FetchDescriptor<LedgerTransaction>(
            predicate: #Predicate {
                $0.date >= start && $0.date < end && $0.kindRaw == expense
            },
            sortBy: [SortDescriptor(\LedgerTransaction.date)]
        ))
    }

    private var calendar: Calendar { AppCalendar.vietnam }

    private var snapshot: BudgetsSnapshot {
        BudgetsSnapshot.make(
            limits: budgets.map {
                .init(
                    id: $0.id, categoryID: $0.category?.id,
                    monthlyLimit: $0.monthlyLimit, isActive: $0.isActive,
                    note: $0.note
                )
            },
            spends: transactions.map {
                .init(
                    categoryID: $0.category?.id, date: $0.date,
                    amount: $0.amount, isBusiness: $0.business != nil
                )
            },
            categories: Dictionary(uniqueKeysWithValues: categories.map {
                ($0.id, BudgetsSnapshot.Visual(
                    name: $0.name, icon: $0.icon, colorHex: $0.colorHex))
            }),
            month: monthAnchor,
            now: .now,
            calendar: calendar
        )
    }

    /// Inactive budgets are excluded from evaluation but stay listed so
    /// they can be re-enabled from the editor.
    private var inactiveBudgets: [Budget] {
        budgets.filter { !$0.isActive }
    }

    var body: some View {
        VStack(spacing: 0) {
            monthHeader
            if snapshot.isEmpty && inactiveBudgets.isEmpty {
                EmptyStateView(
                    symbol: "chart.pie.fill",
                    title: "Chưa có ngân sách",
                    message: "Đặt hạn mức chi hàng tháng cho tổng chi tiêu cá nhân hoặc từng danh mục để được cảnh báo trước khi vượt.",
                    actionTitle: "Thêm ngân sách",
                    action: onAdd
                )
            } else {
                list
            }
        }
        .background(Color(.systemGroupedBackground))
    }

    // MARK: - Month header & summary

    private var monthHeader: some View {
        VStack(spacing: 12) {
            HStack {
                shiftButton(-1, symbol: "chevron.left", label: "Tháng trước")
                Spacer()
                Text(snapshot.monthTitle)
                    .font(.headline)
                    .lineLimit(1)
                    .minimumScaleFactor(0.7)
                Spacer()
                shiftButton(1, symbol: "chevron.right", label: "Tháng sau")
            }
            if !snapshot.isEmpty {
                summaryLines
            }
        }
        .padding(16)
        .background(
            Color(.secondarySystemGroupedBackground),
            in: RoundedRectangle(cornerRadius: 16)
        )
        .padding(.horizontal, 16)
        .padding(.top, 8)
        .padding(.bottom, 8)
    }

    private func shiftButton(
        _ offset: Int, symbol: String, label: String
    ) -> some View {
        Button {
            monthAnchor = calendar.date(
                byAdding: .month, value: offset, to: monthAnchor) ?? monthAnchor
        } label: {
            Image(systemName: symbol)
                .font(.headline)
                .frame(width: 36, height: 28)
                .contentShape(Rectangle())
        }
        .accessibilityLabel(label)
    }

    /// "Đã chi X / Y" progress line plus the per-status counts.
    private var summaryLines: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .firstTextBaseline) {
                Text("Đã chi")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                Spacer()
                Text(
                    "\(VND.compact(snapshot.totalSpent)) / " +
                    "\(VND.compact(snapshot.totalLimit))"
                )
                .font(.subheadline.weight(.semibold))
                .monospacedDigit()
            }
            ProgressView(value: totalFraction)
                .tint(BudgetsUI.color(for: totalStatus))
            HStack(spacing: 14) {
                statusCount(snapshot.okCount, title: "đúng hạn", status: .ok)
                statusCount(snapshot.warningCount, title: "sắp hết", status: .warning)
                statusCount(snapshot.exceededCount, title: "đã vượt", status: .exceeded)
            }
        }
    }

    private var totalFraction: Double {
        guard snapshot.totalLimit > 0 else { return 0 }
        return min(1, max(0,
            Double(snapshot.totalSpent) / Double(snapshot.totalLimit)))
    }

    private var totalStatus: BudgetStatus {
        BudgetsUI.status(spent: snapshot.totalSpent, limit: snapshot.totalLimit)
    }

    private func statusCount(
        _ count: Int, title: String, status: BudgetStatus
    ) -> some View {
        HStack(spacing: 4) {
            Circle()
                .fill(BudgetsUI.color(for: status))
                .frame(width: 8, height: 8)
            Text("\(count) \(title)")
        }
        .font(.caption)
        .foregroundStyle(.secondary)
        .opacity(count > 0 ? 1 : 0.4)
    }

    // MARK: - List

    private var list: some View {
        List {
            if let overall = snapshot.overall {
                Section {
                    rowButton(overall)
                }
            }
            if !snapshot.categories.isEmpty {
                Section("Theo danh mục") {
                    ForEach(snapshot.categories) { row in
                        rowButton(row)
                    }
                }
            }
            if !inactiveBudgets.isEmpty {
                Section("Đã tắt") {
                    ForEach(inactiveBudgets, id: \.id) { budget in
                        inactiveRow(budget)
                    }
                }
            }
            Section {
                Text(
                    "Ngân sách tổng chỉ tính chi tiêu cá nhân (không tính " +
                    "chi kinh doanh); ngân sách theo danh mục tính mọi " +
                    "khoản chi của danh mục đó."
                )
                .font(.caption)
                .foregroundStyle(.secondary)
                .listRowBackground(Color.clear)
            }
        }
        .listStyle(.insetGrouped)
        // Keeps the last row clear of RootTabView's floating "+".
        .contentMargins(.bottom, 40, for: .scrollContent)
    }

    private func rowButton(_ row: BudgetsSnapshot.Row) -> some View {
        Button {
            guard let budget = budgets.first(where: { $0.id == row.budgetID })
            else { return }
            onEdit(budget)
        } label: {
            BudgetsRowView(row: row)
        }
        .buttonStyle(.plain)
    }

    private func inactiveRow(_ budget: Budget) -> some View {
        Button {
            onEdit(budget)
        } label: {
            let visual = inactiveVisual(budget)
            HStack(spacing: 12) {
                IconBadge(symbol: visual.icon, colorHex: visual.colorHex, size: 36)
                VStack(alignment: .leading, spacing: 2) {
                    Text(visual.name)
                        .font(.subheadline.weight(.medium))
                        .lineLimit(1)
                    Text("Đã tắt")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Text(VND.compact(budget.monthlyLimit))
                    .font(.subheadline)
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
            }
        }
        .buttonStyle(.plain)
    }

    private func inactiveVisual(_ budget: Budget) -> BudgetsSnapshot.Visual {
        guard let category = budget.category else { return .overall }
        return .init(
            name: category.name, icon: category.icon, colorHex: category.colorHex)
    }
}

/// One evaluated budget row: badge and name, "đã chi / hạn mức", a
/// progress bar colored by `BudgetStatus`, the `BudgetMath` Vietnamese
/// message and the safe daily amount for the days left in the month.
struct BudgetsRowView: View {
    let row: BudgetsSnapshot.Row

    var body: some View {
        HStack(spacing: 12) {
            IconBadge(symbol: row.icon, colorHex: row.colorHex, size: 36)
            VStack(alignment: .leading, spacing: 4) {
                HStack(alignment: .firstTextBaseline) {
                    Text(row.name)
                        .font(.subheadline.weight(.medium))
                        .lineLimit(1)
                    Spacer(minLength: 8)
                    Text(
                        "\(VND.compact(row.progress.spent)) / " +
                        "\(VND.compact(row.progress.limit.monthlyLimit))"
                    )
                    .font(.subheadline.weight(.medium))
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
                }
                ProgressView(value: min(1, max(0, row.progress.fractionUsed)))
                    .tint(BudgetsUI.color(for: row.progress.status))
                HStack(alignment: .firstTextBaseline) {
                    Text(row.progress.message)
                        .font(.caption)
                        .foregroundStyle(BudgetsUI.color(for: row.progress.status))
                        .lineLimit(1)
                    Spacer(minLength: 8)
                    if row.progress.status != .exceeded,
                       row.progress.safeDailySpend > 0 {
                        Text("Tối đa \(VND.compact(row.progress.safeDailySpend))/ngày")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                }
            }
        }
        .accessibilityElement(children: .combine)
    }
}

/// Status → color mapping shared by the budgets list, the summary header
/// and the dashboard card. Green = đúng hạn, orange = sắp hết, red = vượt.
enum BudgetsUI {
    /// The same thresholds `BudgetMath.evaluate` applies (warning at 80%
    /// of the limit) — used by the summary header's aggregate bar.
    static func status(spent: Int64, limit: Int64) -> BudgetStatus {
        guard limit > 0 else { return .ok }
        if spent > limit { return .exceeded }
        return Double(spent) / Double(limit) >= 0.8 ? .warning : .ok
    }

    static func color(for status: BudgetStatus) -> Color {
        switch status {
        case .ok: return AppTheme.income
        case .warning: return Color(.systemOrange)
        case .exceeded: return AppTheme.expense
        }
    }
}

#Preview("Ngân sách") {
    let container = try! AppModelContainer.make(inMemory: true)
    let context = ModelContext(container)
    try! SeedData.seedIfNeeded(context: context)
    let cash = try! context.fetch(FetchDescriptor<Account>()).first!
    let categories = try! context.fetch(FetchDescriptor<LedgerCategory>())
    let business = try! context.fetch(FetchDescriptor<Business>()).first!
    let food = categories.first { $0.name == "Ăn uống" }!
    let fuel = categories.first { $0.name == "Di chuyển" }!
    context.insert(Budget(monthlyLimit: 12_000_000))
    context.insert(Budget(monthlyLimit: 4_000_000, category: food))
    context.insert(Budget(
        monthlyLimit: 1_000_000, note: "Đi làm mỗi ngày", category: fuel))
    let calendar = AppCalendar.vietnam
    context.insert(LedgerTransaction(
        kind: .expense, amount: 4_200_000,
        date: calendar.date(byAdding: .day, value: -4, to: .now)!,
        account: cash, category: food))
    context.insert(LedgerTransaction(
        kind: .expense, amount: 950_000,
        date: calendar.date(byAdding: .day, value: -2, to: .now)!,
        account: cash, category: fuel))
    context.insert(LedgerTransaction(
        kind: .expense, amount: 2_500_000, date: .now,
        account: cash, business: business))
    return NavigationStack {
        BudgetsView()
    }
    .modelContainer(container)
}

#Preview("Trống") {
    let container = try! AppModelContainer.make(inMemory: true)
    try! SeedData.seedIfNeeded(context: ModelContext(container))
    return NavigationStack {
        BudgetsView()
    }
    .modelContainer(container)
}
