import SwiftUI
import SwiftData
import Charts
import FinanceCore

/// "Mảng kinh doanh" — profit and loss per income stream (căn hộ dịch vụ,
/// làm web, chạy quảng cáo) for a month, quarter or year, kept separate
/// from personal spending. Pushed inside an existing NavigationStack — it
/// does not own one. Rows push `BusinessHubDetailView`; the toolbar "+"
/// opens `BusinessEditView` to add a stream.
struct BusinessHubView: View {
    @Query(sort: \Business.sortOrder) private var businesses: [Business]

    @State private var period: ReportsPeriod
    @State private var showsAdd = false

    init() {
        _period = State(initialValue: ReportsPeriod(calendar: AppCalendar.vietnam))
    }

    var body: some View {
        VStack(spacing: 0) {
            BusinessHubPeriodControls(period: $period)
            BusinessHubContent(
                period: period,
                businesses: businesses,
                onAdd: { showsAdd = true }
            )
        }
        .background(Color(.systemGroupedBackground))
        .navigationTitle("Mảng kinh doanh")
        .toolbar {
            ToolbarItem(placement: .navigationBarTrailing) {
                Button { showsAdd = true } label: {
                    Image(systemName: "plus")
                }
                .accessibilityLabel("Thêm mảng kinh doanh")
            }
        }
        .sheet(isPresented: $showsAdd) {
            BusinessEditView()
        }
    }
}

/// The period switcher both hub screens share: Tháng / Quý / Năm segments
/// (no Tuỳ chọn here) and previous/next chevrons around the period title —
/// the same control the reports tab renders.
struct BusinessHubPeriodControls: View {
    @Binding var period: ReportsPeriod

    private var calendar: Calendar { AppCalendar.vietnam }
    private let kinds: [ReportsPeriodKind] = [.month, .quarter, .year]

    var body: some View {
        VStack(spacing: 10) {
            Picker("Kiểu kỳ", selection: $period.kind) {
                ForEach(kinds, id: \.self) { kind in
                    Text(kind.displayName).tag(kind)
                }
            }
            .pickerStyle(.segmented)
            .accessibilityLabel("Kiểu kỳ")

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
}

/// The data-owning body of the hub screen — re-initialized whenever the
/// period changes so its @Query refetches exactly the needed window
/// (previous period + six-month sparkline + current period), never the
/// whole table.
private struct BusinessHubContent: View {
    let period: ReportsPeriod
    let businesses: [Business]
    let onAdd: () -> Void

    @Query private var transactions: [LedgerTransaction]

    init(period: ReportsPeriod, businesses: [Business], onAdd: @escaping () -> Void) {
        self.period = period
        self.businesses = businesses
        self.onAdd = onAdd
        let fetch = BusinessHubSnapshot.fetchInterval(
            interval: period.interval(calendar: AppCalendar.vietnam),
            trendMonths: BusinessHubSnapshot.sparklineMonths,
            now: .now,
            calendar: AppCalendar.vietnam
        )
        let start = fetch.start
        let end = fetch.end
        _transactions = Query(FetchDescriptor<LedgerTransaction>(
            predicate: #Predicate { $0.date >= start && $0.date < end },
            sortBy: [SortDescriptor(\LedgerTransaction.date, order: .reverse)]
        ))
    }

    private var snapshot: BusinessHubSnapshot {
        BusinessHubSnapshot.make(
            entries: transactions.map {
                ReportEntry(
                    date: $0.date, kind: $0.kind, amount: $0.amount,
                    categoryID: $0.category?.id, businessID: $0.business?.id)
            },
            interval: period.interval(calendar: AppCalendar.vietnam),
            businesses: businesses.map {
                BusinessHubBusiness(
                    id: $0.id, name: $0.name, icon: $0.icon,
                    colorHex: $0.colorHex, sortOrder: $0.sortOrder,
                    isArchived: $0.isArchived)
            },
            now: .now,
            calendar: AppCalendar.vietnam
        )
    }

    private var businessesByID: [UUID: Business] {
        Dictionary(businesses.map { ($0.id, $0) }) { first, _ in first }
    }

    var body: some View {
        List {
            if !snapshot.isEmpty {
                BusinessHubSummarySection(snapshot: snapshot)

                Section {
                    ForEach(snapshot.streams) { stream in
                        if let business = businessesByID[stream.businessID] {
                            NavigationLink {
                                BusinessHubDetailView(business: business)
                            } label: {
                                BusinessHubStreamRow(stream: stream)
                            }
                        }
                    }
                } header: {
                    Text("Từng mảng")
                }

                Section {
                    LabeledContent {
                        AmountText(amount: snapshot.personalSpend, kind: .expense)
                    } label: {
                        Text("Chi tiêu cá nhân kỳ này")
                    }
                }
            }
        }
        .listStyle(.insetGrouped)
        // Keeps the last card clear of RootTabView's floating "+".
        .contentMargins(.bottom, 40, for: .scrollContent)
        .overlay {
            if snapshot.isEmpty { emptyState }
        }
    }

    private var emptyState: some View {
        EmptyStateView(
            symbol: "briefcase.fill",
            title: "Chưa có mảng kinh doanh",
            message: "Thêm mảng kinh doanh để xem doanh thu, chi phí và lãi lỗ của từng nguồn.",
            actionTitle: "Thêm mảng kinh doanh",
            action: onAdd
        )
    }
}

/// "Doanh thu / Chi phí / Lãi / Biên lãi" across every business together.
private struct BusinessHubSummarySection: View {
    let snapshot: BusinessHubSnapshot

    var body: some View {
        Section {
            HStack(alignment: .top, spacing: 8) {
                cell("Doanh thu", amount: snapshot.revenue, kind: .income)
                cell("Chi phí", amount: snapshot.cost, kind: .expense)
                cell("Lãi", amount: snapshot.profit, kind: nil)
                marginCell(snapshot.margin)
            }
            .padding(.vertical, 4)
        } header: {
            Text("Tổng quan")
        }
    }

    private func cell(
        _ title: String, amount: Int64, kind: TransactionKind?
    ) -> some View {
        VStack(spacing: 4) {
            Text(title)
                .font(.caption)
                .foregroundStyle(.secondary)
            AmountText(amount: amount, kind: kind, compact: true)
                .font(.subheadline.weight(.semibold))
                .lineLimit(1)
                .minimumScaleFactor(0.4)
        }
        .frame(maxWidth: .infinity)
    }

    private func marginCell(_ margin: Double) -> some View {
        VStack(spacing: 4) {
            Text("Biên lãi")
                .font(.caption)
                .foregroundStyle(.secondary)
            Text(margin.formatted(.percent.precision(.fractionLength(0...1))))
                .font(.subheadline.weight(.semibold))
                .monospacedDigit()
                .foregroundStyle(margin < 0 ? AppTheme.expense : .primary)
                .lineLimit(1)
                .minimumScaleFactor(0.4)
        }
        .frame(maxWidth: .infinity)
    }
}

/// One business card row: icon, name, revenue/cost, profit colored by sign,
/// margin percent and the six-month profit sparkline.
private struct BusinessHubStreamRow: View {
    let stream: BusinessHubStream

    var body: some View {
        HStack(spacing: 12) {
            IconBadge(symbol: stream.icon, colorHex: stream.colorHex, size: 40)
            VStack(alignment: .leading, spacing: 3) {
                Text(stream.name)
                    .lineLimit(1)
                Text("Thu \(VND.compact(stream.revenue)) · Chi \(VND.compact(stream.cost))")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .minimumScaleFactor(0.7)
                Text("Biên lãi \(stream.margin.formatted(.percent.precision(.fractionLength(0...1))))")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer(minLength: 8)
            VStack(alignment: .trailing, spacing: 6) {
                AmountText(amount: stream.profit)
                    .font(.subheadline.weight(.semibold))
                    .lineLimit(1)
                    .minimumScaleFactor(0.6)
                BusinessHubSparkline(profits: stream.sparkline)
            }
        }
        .padding(.vertical, 4)
    }
}

/// A tiny six-month profit line for a business card — no axes, colored by
/// the sign of the latest month's profit.
struct BusinessHubSparkline: View {
    let profits: [Int64]

    private var lineColor: Color {
        (profits.last ?? 0) < 0 ? AppTheme.expense : AppTheme.income
    }

    var body: some View {
        Chart {
            ForEach(Array(profits.enumerated()), id: \.offset) { point in
                LineMark(
                    x: .value("Tháng", point.offset),
                    y: .value("Lãi", Double(point.element))
                )
                .foregroundStyle(lineColor)
                AreaMark(
                    x: .value("Tháng", point.offset),
                    y: .value("Lãi", Double(point.element))
                )
                .foregroundStyle(lineColor.opacity(0.15))
            }
        }
        .chartXAxis(.hidden)
        .chartYAxis(.hidden)
        .chartLegend(.hidden)
        .frame(width: 72, height: 32)
        .accessibilityHidden(true)
    }
}

#Preview {
    let container = try! AppModelContainer.make(inMemory: true)
    let context = ModelContext(container)
    try! SeedData.seedIfNeeded(context: context)
    let cash = try! context.fetch(FetchDescriptor<Account>()).first!
    let categories = try! context.fetch(FetchDescriptor<LedgerCategory>())
    let businesses = try! context.fetch(FetchDescriptor<Business>())
    let apartment = businesses.first { $0.name == "Căn hộ dịch vụ" }!
    let web = businesses.first { $0.name == "Làm web" }!
    let ads = businesses.first { $0.name == "Chạy quảng cáo thuê" }!
    let service = categories.first { $0.name == "Doanh thu dịch vụ" }!
    let rent = categories.first { $0.name == "Tiền thuê phòng" }!
    let tools = categories.first { $0.name == "Công cụ & phần mềm" }!
    let adsCost = categories.first { $0.name == "Quảng cáo" }!
    let food = categories.first { $0.name == "Ăn uống" }!
    let calendar = AppCalendar.vietnam
    for offset in [-5, -4, -3, -2, -1, 0] {
        let day = calendar.date(byAdding: .month, value: offset, to: .now)!
        context.insert(LedgerTransaction(
            kind: .income, amount: 12_000_000, date: day,
            account: cash, category: rent, business: apartment))
        context.insert(LedgerTransaction(
            kind: .expense, amount: 3_500_000, date: day,
            account: cash, category: tools, business: apartment))
        context.insert(LedgerTransaction(
            kind: .income, amount: 8_000_000, date: day,
            account: cash, category: service, business: web))
        context.insert(LedgerTransaction(
            kind: .income, amount: 6_000_000, date: day,
            account: cash, category: service, business: ads))
        context.insert(LedgerTransaction(
            kind: .expense, amount: 7_000_000, date: day,
            account: cash, category: adsCost, business: ads))
        context.insert(LedgerTransaction(
            kind: .expense, amount: 450_000, date: day,
            account: cash, category: food))
    }
    return NavigationStack {
        BusinessHubView()
    }
    .modelContainer(container)
}
