import SwiftUI
import SwiftData
import FinanceCore

/// Profit-and-loss for one income stream ("Căn hộ dịch vụ", "Làm web"…):
/// revenue, cost, profit and margin with the change versus the previous
/// period, category breakdowns, a twelve-month chart and the stream's
/// day-grouped transactions. Pushed from `BusinessHubView` inside an
/// existing NavigationStack — it does not own one.
struct BusinessHubDetailView: View {
    let business: Business

    @State private var period: ReportsPeriod
    @State private var showsEdit = false

    init(business: Business) {
        self.business = business
        _period = State(initialValue: ReportsPeriod(calendar: AppCalendar.vietnam))
    }

    var body: some View {
        VStack(spacing: 0) {
            BusinessHubPeriodControls(period: $period)
            BusinessHubDetailContent(period: period, business: business)
        }
        .background(Color(.systemGroupedBackground))
        .navigationTitle(business.name)
        .toolbar {
            ToolbarItem(placement: .navigationBarTrailing) {
                Button("Sửa") { showsEdit = true }
            }
        }
        .sheet(isPresented: $showsEdit) {
            BusinessEditView(business: business)
        }
    }
}

/// The data-owning body of the detail screen — re-initialized whenever the
/// period changes so its @Query refetches exactly the needed window
/// (previous period + twelve-month trend + current period). The business
/// filter applies in memory — an optional-id comparison, like the reports
/// drill-down does.
private struct BusinessHubDetailContent: View {
    let period: ReportsPeriod
    let business: Business

    @Query(sort: \LedgerCategory.sortOrder) private var categories: [LedgerCategory]
    @Query private var transactions: [LedgerTransaction]

    @State private var editing: LedgerTransaction?

    init(period: ReportsPeriod, business: Business) {
        self.period = period
        self.business = business
        let fetch = BusinessHubSnapshot.fetchInterval(
            interval: period.interval(calendar: AppCalendar.vietnam),
            trendMonths: BusinessHubDetailSnapshot.trendMonths,
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

    private var interval: ReportDateInterval {
        period.interval(calendar: AppCalendar.vietnam)
    }

    /// Every fetched transaction belonging to this business — the window
    /// already covers the previous period and the twelve-month trend.
    private var businessTransactions: [LedgerTransaction] {
        transactions.filter { $0.business?.id == business.id }
    }

    private var snapshot: BusinessHubDetailSnapshot {
        BusinessHubDetailSnapshot.make(
            entries: businessTransactions.map {
                ReportEntry(
                    date: $0.date, kind: $0.kind, amount: $0.amount,
                    categoryID: $0.category?.id, businessID: $0.business?.id)
            },
            interval: interval,
            businessID: business.id,
            categories: Dictionary(
                uniqueKeysWithValues: categories.map {
                    ($0.id, ReportsEntityInfo(
                        name: $0.name, icon: $0.icon, colorHex: $0.colorHex))
                }),
            now: .now,
            calendar: AppCalendar.vietnam
        )
    }

    /// This business's transactions inside the displayed period — the
    /// day-grouped list at the bottom (transfers included; they never
    /// touch the totals).
    private var periodTransactions: [LedgerTransaction] {
        businessTransactions.filter { interval.contains($0.date) }
    }

    private var transactionsByID: [UUID: LedgerTransaction] {
        Dictionary(periodTransactions.map { ($0.id, $0) }) { first, _ in first }
    }

    /// This business's client receivable accounts ("Phải thu"), not archived.
    private var receivableAccounts: [Account] {
        (business.accounts ?? [])
            .filter { $0.kind == .receivable && !$0.isArchived }
    }

    /// What clients still owe this business — the receivables' positive
    /// balances summed.
    private var receivableOutstanding: Int64 {
        receivableAccounts.reduce(0) { $0 + max(0, $1.balance) }
    }

    private var sections: [TransactionListDaySection] {
        TransactionListGrouping.sections(
            for: periodTransactions.map { TransactionListRow(transaction: $0) })
    }

    var body: some View {
        List {
            BusinessHubDetailSummarySection(snapshot: snapshot)

            Section {
                NavigationLink {
                    ReceivablesView(business: business)
                } label: {
                    HStack(spacing: 12) {
                        IconBadge(
                            symbol: "person.badge.clock.fill",
                            colorHex: "FF9F0A", size: 32
                        )
                        VStack(alignment: .leading, spacing: 2) {
                            Text("Khách đang nợ")
                            Text("\(receivableAccounts.count) khách hàng")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        Spacer()
                        AmountText(amount: receivableOutstanding)
                    }
                }
            } header: {
                Text("Khoản ứng hộ khách")
            }

            BusinessHubDetailCategorySection(
                title: "Thu theo danh mục",
                kind: .income,
                rows: snapshot.revenueByCategory,
                emptyCaption: "Không có thu nhập nào trong kỳ này."
            )

            BusinessHubDetailCategorySection(
                title: "Chi theo danh mục",
                kind: .expense,
                rows: snapshot.costByCategory,
                emptyCaption: "Không có chi phí nào trong kỳ này."
            )

            ReportsTrendSection(points: snapshot.months)

            if sections.isEmpty {
                Section {
                    Text("Không có giao dịch nào trong kỳ này.")
                        .foregroundStyle(.secondary)
                } header: {
                    Text("Giao dịch")
                }
            } else {
                ForEach(sections) { section in
                    Section {
                        ForEach(section.rows) { row in
                            TransactionListRowView(row: row)
                                .contentShape(Rectangle())
                                .onTapGesture {
                                    editing = transactionsByID[row.id]
                                }
                        }
                    } header: {
                        HStack {
                            Text(AppDateFormat.dayHeader(section.day, now: .now))
                            Spacer()
                            if section.incomeTotal > 0 {
                                AmountText(
                                    amount: section.incomeTotal,
                                    kind: .income, compact: true)
                            }
                            if section.expenseTotal > 0 {
                                AmountText(
                                    amount: section.expenseTotal,
                                    kind: .expense, compact: true)
                            }
                        }
                        .font(.caption)
                        .textCase(nil)
                    }
                }
            }
        }
        .listStyle(.insetGrouped)
        // Keeps the last card clear of RootTabView's floating "+".
        .contentMargins(.bottom, 40, for: .scrollContent)
        .sheet(item: $editing) { transaction in
            TransactionEditorView(transaction: transaction)
        }
    }
}

/// "Doanh thu / Chi phí / Lãi / Biên lãi" for the period with the change
/// versus the equal-length previous period under each figure. Percent
/// changes are hidden when the previous value is 0.
private struct BusinessHubDetailSummarySection: View {
    let snapshot: BusinessHubDetailSnapshot

    var body: some View {
        Section {
            HStack(alignment: .top, spacing: 8) {
                cell("Doanh thu", amount: snapshot.current.income,
                     kind: .income, change: snapshot.revenueChange)
                cell("Chi phí", amount: snapshot.current.expense,
                     kind: .expense, change: snapshot.costChange)
                cell("Lãi", amount: snapshot.profit,
                     kind: nil, change: snapshot.profitChange)
                marginCell
            }
            .padding(.vertical, 4)
        } header: {
            Text("Tổng quan")
        }
    }

    private func cell(
        _ title: String, amount: Int64,
        kind: TransactionKind?, change: ReportChange
    ) -> some View {
        VStack(spacing: 4) {
            Text(title)
                .font(.caption)
                .foregroundStyle(.secondary)
            AmountText(amount: amount, kind: kind, compact: true)
                .font(.subheadline.weight(.semibold))
                .lineLimit(1)
                .minimumScaleFactor(0.4)
            changeLabel(change)
        }
        .frame(maxWidth: .infinity)
    }

    private var marginCell: some View {
        VStack(spacing: 4) {
            Text("Biên lãi")
                .font(.caption)
                .foregroundStyle(.secondary)
            Text(snapshot.margin
                .formatted(.percent.precision(.fractionLength(0...1))))
                .font(.subheadline.weight(.semibold))
                .monospacedDigit()
                .foregroundStyle(snapshot.margin < 0 ? AppTheme.expense : .primary)
                .lineLimit(1)
                .minimumScaleFactor(0.4)
            marginChangeLabel
        }
        .frame(maxWidth: .infinity)
    }

    @ViewBuilder private var marginChangeLabel: some View {
        if snapshot.previousMargin != 0 || snapshot.marginChange != 0 {
            let change = snapshot.marginChange
            HStack(spacing: 2) {
                Image(systemName: change > 0
                      ? "arrow.up" : change < 0 ? "arrow.down" : "minus")
                Text(abs(change)
                    .formatted(.percent.precision(.fractionLength(0...1))))
            }
            .font(.caption2)
            .foregroundStyle(.secondary)
        } else {
            Text("—")
                .font(.caption2)
                .foregroundStyle(.tertiary)
        }
    }

    @ViewBuilder private func changeLabel(_ change: ReportChange) -> some View {
        if let percent = change.percent {
            HStack(spacing: 2) {
                Image(systemName: percent > 0
                      ? "arrow.up" : percent < 0 ? "arrow.down" : "minus")
                Text(abs(percent).formatted(.percent.precision(.fractionLength(0...1))))
            }
            .font(.caption2)
            .foregroundStyle(.secondary)
        } else {
            Text("—")
                .font(.caption2)
                .foregroundStyle(.tertiary)
        }
    }
}

/// "Thu theo danh mục" / "Chi theo danh mục" — every category row with its
/// icon, amount and share of the kind's total.
private struct BusinessHubDetailCategorySection: View {
    let title: String
    let kind: TransactionKind
    let rows: [ReportsCategorySlice]
    let emptyCaption: String

    var body: some View {
        Section {
            if rows.isEmpty {
                Text(emptyCaption)
                    .foregroundStyle(.secondary)
            } else {
                ForEach(rows) { slice in
                    ReportsCategoryRowView(slice: slice, kind: kind)
                }
            }
        } header: {
            Text(title)
        }
    }
}

#Preview {
    let container = try! AppModelContainer.make(inMemory: true)
    let context = container.mainContext
    try! SeedData.seedIfNeeded(context: context)
    let cash = try! context.fetch(FetchDescriptor<Account>()).first!
    let categories = try! context.fetch(FetchDescriptor<LedgerCategory>())
    let apartment = try! context.fetch(FetchDescriptor<Business>())
        .first { $0.name == "Căn hộ dịch vụ" }!
    let rent = categories.first { $0.name == "Tiền thuê phòng" }!
    let tools = categories.first { $0.name == "Công cụ & phần mềm" }!
    let utilities = categories.first { $0.name == "Điện nước internet" }!
    let calendar = AppCalendar.vietnam
    for offset in [-11, -7, -5, -3, -2, -1, 0] {
        let day = calendar.date(byAdding: .month, value: offset, to: .now)!
        context.insert(LedgerTransaction(
            kind: .income, amount: 12_000_000, date: day,
            note: "Tiền phòng", account: cash, category: rent,
            business: apartment))
        context.insert(LedgerTransaction(
            kind: .expense, amount: 2_800_000, date: day,
            note: "Điện nước", account: cash, category: utilities,
            business: apartment))
    }
    context.insert(LedgerTransaction(
        kind: .expense, amount: 1_500_000, date: .now,
        note: "Phần mềm quản lý", account: cash, category: tools,
        business: apartment))
    return NavigationStack {
        BusinessHubDetailView(business: apartment)
    }
    .modelContainer(container)
}
