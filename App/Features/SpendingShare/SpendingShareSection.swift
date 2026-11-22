import SwiftUI
import SwiftData
import FinanceCore

/// Reports-embeddable section: the spending-share donut for one period,
/// scope and kind, with the "Danh mục / Mảng" switch. Slice selection is
/// forwarded so the host can navigate — `onSelectCategory` receives the
/// category id (nil = "Chưa phân loại"), `onSelectBusiness` receives the
/// business id (nil = the "Cá nhân" slice). The folded "Khác" slice and
/// deselections forward nothing.
struct SpendingShareSection: View {
    let interval: ReportDateInterval
    let scope: ReportScope
    let kind: TransactionKind
    let onSelectCategory: ((UUID?) -> Void)?
    let onSelectBusiness: ((UUID?) -> Void)?

    @Query private var transactions: [LedgerTransaction]
    @Query(sort: \LedgerCategory.sortOrder) private var categories: [LedgerCategory]
    @Query(sort: \Business.sortOrder) private var businesses: [Business]

    @State private var mode: SpendingShareMode = .category
    @State private var result = SpendingShareResult()

    init(
        interval: ReportDateInterval,
        scope: ReportScope = .all,
        kind: TransactionKind,
        onSelectCategory: ((UUID?) -> Void)? = nil,
        onSelectBusiness: ((UUID?) -> Void)? = nil
    ) {
        self.interval = interval
        self.scope = scope
        self.kind = kind
        self.onSelectCategory = onSelectCategory
        self.onSelectBusiness = onSelectBusiness
        let start = interval.start
        let end = interval.end
        let kindRaw = kind.rawValue
        _transactions = Query(FetchDescriptor<LedgerTransaction>(
            predicate: #Predicate {
                $0.date >= start && $0.date < end && $0.kindRaw == kindRaw
            }
        ))
    }

    private var input: SpendingShareBuilder.Input {
        SpendingShareBuilder.Input(
            entries: transactions.map {
                ReportEntry(
                    date: $0.date, kind: $0.kind, amount: $0.amount,
                    categoryID: $0.category?.id,
                    businessID: $0.business?.id)
            },
            interval: interval,
            kind: kind,
            mode: mode,
            scope: scope,
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

    private var headerTitle: String {
        kind == .expense ? "Cơ cấu chi" : "Cơ cấu thu"
    }

    private var totalTitle: String {
        kind == .expense ? "Tổng chi" : "Tổng thu"
    }

    private var emptyCaption: String {
        kind == .expense
            ? "Không có chi tiêu nào trong kỳ này."
            : "Không có thu nhập nào trong kỳ này."
    }

    var body: some View {
        Section {
            SpendingShareModePicker(mode: $mode)
            if result.isEmpty {
                Text(emptyCaption)
                    .foregroundStyle(.secondary)
            } else {
                ShareDonutChart(
                    slices: donutSlices,
                    totalTitle: totalTitle,
                    kind: kind,
                    onSelect: forwardSelection
                )
                .padding(.vertical, 4)
            }
        } header: {
            Text(headerTitle)
        }
        .task(id: input.fingerprint) {
            await reload()
        }
    }

    /// Maps the donut's slice back to the richer builder slice and routes
    /// the ids to the host — "Khác" and deselections are not forwarded.
    private func forwardSelection(_ slice: ShareDonutSlice?) {
        guard let slice,
              let full = result.slices.first(where: { $0.id == slice.id }),
              !full.isOther
        else { return }
        switch mode {
        case .category:
            onSelectCategory?(full.categoryID)
        case .segment:
            onSelectBusiness?(full.businessID)
        }
    }

    private func reload() async {
        let snapshot = input
        let output = await Task.detached(priority: .userInitiated) {
            SpendingShareBuilder.compute(snapshot)
        }.value
        guard !Task.isCancelled else { return }
        result = output
    }
}

#Preview {
    let container = try! AppModelContainer.make(inMemory: true)
    let context = ModelContext(container)
    try! SeedData.seedIfNeeded(context: context)
    let cash = try! context.fetch(FetchDescriptor<Account>()).first!
    let categories = try! context.fetch(FetchDescriptor<LedgerCategory>())
    let web = try! context.fetch(FetchDescriptor<Business>())
        .first { $0.name == "Làm web" }!
    let named = { (name: String) in categories.first { $0.name == name } }
    context.insert(LedgerTransaction(
        kind: .expense, amount: 4_200_000,
        account: cash, category: named("Ăn uống")))
    context.insert(LedgerTransaction(
        kind: .expense, amount: 1_300_000,
        account: cash, category: named("Di chuyển")))
    context.insert(LedgerTransaction(
        kind: .expense, amount: 950_000,
        account: cash, category: named("Thuê mặt bằng"), business: web))
    context.insert(LedgerTransaction(
        kind: .expense, amount: 300_000,
        account: cash, business: web))
    let month = ReportSummary.monthInterval(
        containing: .now, calendar: AppCalendar.vietnam)
    return List {
        SpendingShareSection(
            interval: month, scope: .all, kind: .expense,
            onSelectCategory: { _ in },
            onSelectBusiness: { _ in })
    }
    .listStyle(.insetGrouped)
    .modelContainer(container)
}
