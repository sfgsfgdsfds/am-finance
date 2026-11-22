import SwiftUI
import SwiftData
import FinanceCore

/// The "Danh mục / Mảng" segmented switch shared by `SpendingShareCard`
/// and `SpendingShareSection`.
struct SpendingShareModePicker: View {
    @Binding var mode: SpendingShareMode

    var body: some View {
        Picker("Nhóm theo", selection: $mode) {
            ForEach(SpendingShareMode.allCases, id: \.self) { mode in
                Text(mode.displayName).tag(mode)
            }
        }
        .pickerStyle(.segmented)
        .accessibilityLabel("Nhóm theo")
    }
}

/// Self-contained dashboard card: what the interval's expense money was
/// spent on — "Danh mục" (per category) or "Mảng" (personal vs each
/// business) — as a `ShareDonutChart`. Owns a month-scoped query (date
/// range + kind predicate, never the whole table) and runs the
/// aggregation off the main actor through `SpendingShareBuilder`.
struct SpendingShareCard: View {
    /// The reporting interval — defaults to the current calendar month.
    let interval: ReportDateInterval
    let title: String

    @Query private var transactions: [LedgerTransaction]
    @Query(sort: \LedgerCategory.sortOrder) private var categories: [LedgerCategory]
    @Query(sort: \Business.sortOrder) private var businesses: [Business]

    @State private var mode: SpendingShareMode = .category
    @State private var result = SpendingShareResult()

    init(
        interval: ReportDateInterval? = nil,
        title: String = "Cơ cấu chi tiêu"
    ) {
        self.interval = interval ?? ReportSummary.monthInterval(
            containing: .now, calendar: AppCalendar.vietnam)
        self.title = title
        let start = self.interval.start
        let end = self.interval.end
        let expense = TransactionKind.expense.rawValue
        _transactions = Query(FetchDescriptor<LedgerTransaction>(
            predicate: #Predicate {
                $0.date >= start && $0.date < end && $0.kindRaw == expense
            }
        ))
    }

    /// Plain Sendable values for the builder — the model→entry mapping
    /// stays on the main actor, the aggregation moves off it.
    private var input: SpendingShareBuilder.Input {
        SpendingShareBuilder.Input(
            entries: transactions.map {
                ReportEntry(
                    date: $0.date, kind: $0.kind, amount: $0.amount,
                    categoryID: $0.category?.id,
                    businessID: $0.business?.id)
            },
            interval: interval,
            kind: .expense,
            mode: mode,
            categories: Dictionary(uniqueKeysWithValues: categories.map {
                ($0.id, SpendingShareEntityInfo(
                    name: $0.name, icon: $0.icon, colorHex: $0.colorHex))
            }),
            businesses: Dictionary(uniqueKeysWithValues: businesses.map {
                ($0.id, SpendingShareEntityInfo(
                    name: $0.name, icon: $0.icon, colorHex: $0.colorHex))
            })
        )
    }

    private var donutSlices: [ShareDonutSlice] {
        result.slices.map {
            ShareDonutSlice(
                id: $0.id, name: $0.name,
                amount: $0.amount, colorHex: $0.colorHex)
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(title)
                .font(.headline)
            SpendingShareModePicker(mode: $mode)
            if result.isEmpty {
                emptyState
            } else {
                ShareDonutChart(
                    slices: donutSlices,
                    totalTitle: "Tổng chi",
                    kind: .expense
                )
            }
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            Color(.secondarySystemGroupedBackground),
            in: RoundedRectangle(cornerRadius: 16)
        )
        .task(id: input.fingerprint) {
            await reload()
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("spendingShare.card")
    }

    private var emptyState: some View {
        VStack(spacing: 8) {
            Image(systemName: "chart.pie")
                .font(.title2)
                .foregroundStyle(.secondary)
            Text("Không có chi tiêu nào trong kỳ này.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity)
        .frame(height: 120)
        .accessibilityElement(children: .combine)
    }

    /// Aggregates on a detached task; `.task(id:)` cancels a superseded
    /// run, so only the latest input ever lands in `result`.
    private func reload() async {
        let snapshot = input
        let output = await Task.detached(priority: .userInitiated) {
            SpendingShareBuilder.compute(snapshot)
        }.value
        guard !Task.isCancelled else { return }
        result = output
    }
}

#Preview("Có dữ liệu") {
    let container = try! AppModelContainer.make(inMemory: true)
    let context = ModelContext(container)
    try! SeedData.seedIfNeeded(context: context)
    let cash = try! context.fetch(FetchDescriptor<Account>()).first!
    let categories = try! context.fetch(FetchDescriptor<LedgerCategory>())
    let web = try! context.fetch(FetchDescriptor<Business>())
        .first { $0.name == "Làm web" }!
    let named = { (name: String) in categories.first { $0.name == name } }
    context.insert(LedgerTransaction(
        kind: .expense, amount: 4_200_000, note: "Ăn uống tháng này",
        account: cash, category: named("Ăn uống")))
    context.insert(LedgerTransaction(
        kind: .expense, amount: 1_300_000,
        account: cash, category: named("Di chuyển")))
    context.insert(LedgerTransaction(
        kind: .expense, amount: 950_000,
        account: cash, category: named("Nhà cửa")))
    context.insert(LedgerTransaction(
        kind: .expense, amount: 700_000,
        account: cash, category: named("Quảng cáo"), business: web))
    context.insert(LedgerTransaction(
        kind: .expense, amount: 300_000,
        account: cash, category: named("Hoá đơn"), business: web))
    return ScrollView {
        SpendingShareCard()
            .padding(16)
    }
    .background(Color(.systemGroupedBackground))
    .modelContainer(container)
}

#Preview("Trống") {
    let container = try! AppModelContainer.make(inMemory: true)
    try! SeedData.seedIfNeeded(context: ModelContext(container))
    return ScrollView {
        SpendingShareCard()
            .padding(16)
    }
    .background(Color(.systemGroupedBackground))
    .modelContainer(container)
}
