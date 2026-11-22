import SwiftUI
import SwiftData
import FinanceCore

/// The reports tab ("Báo cáo"): where the money comes from and goes for any
/// period — month, quarter, year or a custom range — across everything,
/// personal spending only, or one business. Owns its NavigationStack;
/// category rows push a drilled-down, day-grouped transaction list.
struct ReportsView: View {
    @Query(sort: \Business.sortOrder) private var businesses: [Business]

    @State private var period: ReportsPeriod
    @State private var scope: ReportScope = .all

    init() {
        _period = State(initialValue: ReportsPeriod(calendar: AppCalendar.vietnam))
    }

    private var calendar: Calendar { AppCalendar.vietnam }

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                controls
                ReportsContent(
                    period: period, scope: scope, businesses: businesses)
            }
            .background(Color(.systemGroupedBackground))
            .navigationTitle("Báo cáo")
            .toolbar {
                ToolbarItem(placement: .navigationBarTrailing) {
                    scopeMenu
                }
            }
        }
    }

    // MARK: - Period controls

    private var controls: some View {
        VStack(spacing: 10) {
            Picker("Kỳ báo cáo", selection: $period.kind) {
                ForEach(ReportsPeriodKind.allCases, id: \.self) { kind in
                    Text(kind.displayName).tag(kind)
                }
            }
            .pickerStyle(.segmented)
            .accessibilityLabel("Kiểu kỳ báo cáo")

            HStack {
                shiftButton(-1, symbol: "chevron.left", label: "Kỳ trước")
                Spacer()
                Text(period.title(calendar: calendar))
                    .font(.headline)
                    .lineLimit(1)
                    .minimumScaleFactor(0.7)
                Spacer()
                shiftButton(1, symbol: "chevron.right", label: "Kỳ sau")
            }

            if period.kind == .custom {
                HStack {
                    DatePicker(
                        "Từ",
                        selection: $period.customStart,
                        in: ...period.customEnd,
                        displayedComponents: .date
                    )
                    Spacer()
                    DatePicker(
                        "Đến",
                        selection: $period.customEnd,
                        in: period.customStart...,
                        displayedComponents: .date
                    )
                }
                .datePickerStyle(.compact)
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
            period = period.shifted(by: offset, calendar: calendar)
        } label: {
            Image(systemName: symbol)
                .font(.headline)
                .frame(width: 36, height: 28)
                .contentShape(Rectangle())
        }
        .accessibilityLabel(label)
    }

    // MARK: - Scope menu

    private var scopeTitle: String {
        switch scope {
        case .all: return "Tất cả"
        case .personal: return "Cá nhân"
        case .anyBusiness: return "Kinh doanh"
        case .business(let id):
            return businesses.first { $0.id == id }?.name ?? "Kinh doanh"
        }
    }

    private var scopeMenu: some View {
        Menu {
            scopeItem("Tất cả", item: .all)
            scopeItem("Cá nhân", item: .personal)
            if !businesses.isEmpty {
                Divider()
                ForEach(businesses, id: \.id) { business in
                    scopeItem(business.name, item: .business(business.id))
                }
            }
        } label: {
            HStack(spacing: 4) {
                Text(scopeTitle)
                    .lineLimit(1)
                Image(systemName: "chevron.up.chevron.down")
                    .font(.caption2)
            }
        }
        .accessibilityLabel("Phạm vi báo cáo")
    }

    private func scopeItem(_ title: String, item: ReportScope) -> some View {
        Button {
            scope = item
        } label: {
            if scope == item {
                Label(title, systemImage: "checkmark")
            } else {
                Text(title)
            }
        }
    }
}

/// The data-owning body of the reports tab — re-initialized whenever the
/// period changes so its @Query refetches exactly the needed window
/// (previous period + 12-month trend + current period), never the table.
private struct ReportsContent: View {
    let period: ReportsPeriod
    let scope: ReportScope
    let businesses: [Business]

    @Query(sort: \LedgerCategory.sortOrder) private var categories: [LedgerCategory]
    @Query private var transactions: [LedgerTransaction]

    init(period: ReportsPeriod, scope: ReportScope, businesses: [Business]) {
        self.period = period
        self.scope = scope
        self.businesses = businesses
        let fetch = period.fetchInterval(
            trendMonths: 12, calendar: AppCalendar.vietnam)
        let start = fetch.start
        let end = fetch.end
        _transactions = Query(FetchDescriptor<LedgerTransaction>(
            predicate: #Predicate { $0.date >= start && $0.date < end },
            sortBy: [SortDescriptor(\LedgerTransaction.date, order: .reverse)]
        ))
    }

    private var interval: ReportDateInterval {
        period.interval(calendar: AppCalendar.vietnam)
    }

    private var snapshot: ReportsSnapshot {
        let calendar = AppCalendar.vietnam
        let entries = transactions.map {
            ReportEntry(
                date: $0.date, kind: $0.kind, amount: $0.amount,
                categoryID: $0.category?.id, businessID: $0.business?.id)
        }
        return ReportsSnapshot.make(
            entries: entries,
            interval: interval,
            scope: scope,
            categories: Dictionary(
                uniqueKeysWithValues: categories.map {
                    ($0.id, ReportsEntityInfo(
                        name: $0.name, icon: $0.icon, colorHex: $0.colorHex))
                }),
            businesses: Dictionary(
                uniqueKeysWithValues: businesses.map {
                    ($0.id, ReportsEntityInfo(
                        name: $0.name, icon: $0.icon, colorHex: $0.colorHex))
                }),
            trendAnchor: period.trendAnchor(calendar: calendar),
            dailyInMonth: period.kind == .month ? interval.start : nil,
            calendar: calendar
        )
    }

    var body: some View {
        List {
            if !snapshot.isEmpty {
                ReportsSummarySection(comparison: snapshot.comparison)

                ReportsCategorySection(
                    title: "Chi theo danh mục",
                    kind: .expense,
                    rows: snapshot.expense,
                    chartRows: snapshot.expenseChart,
                    total: snapshot.comparison.current.expense,
                    emptyCaption: "Không có chi tiêu nào trong kỳ này.",
                    interval: interval,
                    scope: scope
                )

                ReportsCategorySection(
                    title: "Thu theo danh mục",
                    kind: .income,
                    rows: snapshot.income,
                    chartRows: snapshot.incomeChart,
                    total: snapshot.comparison.current.income,
                    emptyCaption: "Không có thu nhập nào trong kỳ này.",
                    interval: interval,
                    scope: scope
                )

                if scope == .all && !snapshot.businesses.isEmpty {
                    ReportsBusinessSection(results: snapshot.businesses)
                }

                ReportsTrendSection(points: snapshot.trend)

                if !snapshot.daily.isEmpty {
                    ReportsDailySection(days: snapshot.daily)
                }
            }
        }
        .listStyle(.insetGrouped)
        .contentMargins(.bottom, 40)
        .overlay {
            if snapshot.isEmpty { emptyState }
        }
    }

    private var emptyState: some View {
        EmptyStateView(
            symbol: "chart.bar",
            title: "Chưa có dữ liệu",
            message: "Không có thu hoặc chi nào trong kỳ này."
        )
    }
}

#Preview {
    let container = try! AppModelContainer.make(inMemory: true)
    let context = ModelContext(container)
    try! SeedData.seedIfNeeded(context: context)
    let cash = try! context.fetch(FetchDescriptor<Account>()).first!
    let categories = try! context.fetch(FetchDescriptor<LedgerCategory>())
    let businesses = try! context.fetch(FetchDescriptor<Business>())
    let food = categories.first { $0.name == "Ăn uống" }!
    let fuel = categories.first { $0.name == "Di chuyển" }!
    let salary = categories.first { $0.name == "Lương & thù lao" }!
    let web = businesses.first { $0.name == "Làm web" }!
    let calendar = AppCalendar.vietnam
    for offset in [0, -1, -2, -4] {
        let day = calendar.date(byAdding: .month, value: offset, to: .now)!
        context.insert(LedgerTransaction(
            kind: .expense, amount: 450_000, date: day,
            note: "Ăn uống", account: cash, category: food))
        context.insert(LedgerTransaction(
            kind: .expense, amount: 300_000, date: day,
            account: cash, category: fuel))
        context.insert(LedgerTransaction(
            kind: .income, amount: 15_000_000, date: day,
            account: cash, category: salary, business: web))
    }
    context.insert(LedgerTransaction(
        kind: .expense, amount: 2_000_000, date: .now,
        account: cash, business: web))
    return ReportsView()
        .modelContainer(container)
}
