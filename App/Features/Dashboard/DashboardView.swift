import SwiftUI
import SwiftData
import FinanceCore

/// "Tổng quan" tab root: one glance at net worth, this month's cash flow,
/// where the money went and how each business did. All aggregation lives in
/// `DashboardSnapshot`, fed by a six-month transaction window so the whole
/// table is never loaded; this view only renders the snapshot.
struct DashboardView: View {
    @Environment(\.modelContext) private var context

    @Query(sort: \Account.sortOrder) private var accounts: [Account]
    @Query(sort: \LedgerCategory.sortOrder) private var categories: [LedgerCategory]
    @Query(sort: \Business.sortOrder) private var businesses: [Business]
    /// Transactions of the last six calendar months, newest first — covers
    /// the month cards, the chart, top categories, business P&L and the
    /// latest-eight strip.
    @Query private var windowTransactions: [LedgerTransaction]
    @Query private var pendingReview: [LedgerTransaction]

    @State private var editing: LedgerTransaction?
    @State private var isCreating = false
    /// Cheap `fetchCount` (no rows loaded) so a user whose only transactions
    /// are older than six months is not greeted with the empty-state card.
    @State private var transactionCount = 0

    init() {
        let calendar = AppCalendar.vietnam
        let monthStart = ReportSummary.monthInterval(
            containing: .now, calendar: calendar
        ).start
        let windowStart = calendar.date(byAdding: .month, value: -5, to: monthStart)
            ?? monthStart
        _windowTransactions = Query(
            filter: #Predicate { $0.date >= windowStart },
            sort: \.date,
            order: .reverse
        )
        _pendingReview = Query(
            filter: #Predicate { $0.needsReview == true },
            sort: \.date,
            order: .reverse
        )
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                LazyVStack(spacing: 16) {
                    if snapshot.isEmpty {
                        DashboardWelcomeCard(onAddTransaction: {
                            isCreating = true
                        })
                    }
                    DashboardNetWorthCard(netWorth: snapshot.netWorth)
                    if !snapshot.isEmpty {
                        DashboardMonthCard(month: snapshot.month)
                        if !snapshot.accountChips.isEmpty {
                            DashboardAccountsCard(chips: snapshot.accountChips) { id in
                                accounts.first { $0.id == id }
                            }
                        }
                        if !upcomingItems.isEmpty {
                            DashboardUpcomingCard(items: upcomingItems) { id in
                                accounts.first { $0.id == id }
                            }
                        }
                        DashboardChartCard(months: snapshot.months)
                        if !snapshot.topExpenseCategories.isEmpty {
                            DashboardTopCategoriesCard(rows: snapshot.topExpenseCategories)
                        }
                        if !snapshot.businessResults.isEmpty {
                            DashboardBusinessCard(results: snapshot.businessResults)
                        }
                        if snapshot.pendingReviewCount > 0 {
                            DashboardPendingReviewBanner(count: snapshot.pendingReviewCount)
                        }
                        if !snapshot.recentItems.isEmpty {
                            DashboardRecentCard(items: snapshot.recentItems) { item in
                                editing = windowTransactions.first { $0.id == item.id }
                            }
                        }
                    }
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 8)
            }
            .background(Color(.systemGroupedBackground))
            // Keeps the last card clear of RootTabView's floating "+".
            .contentMargins(.bottom, 40, for: .scrollContent)
            .navigationTitle("Tổng quan")
            .toolbar {
                ToolbarItem(placement: .primaryAction) {
                    NavigationLink {
                        SettingsView()
                    } label: {
                        Image(systemName: "gearshape.fill")
                    }
                    .accessibilityLabel("Cài đặt")
                }
            }
            .sheet(item: $editing) { transaction in
                TransactionEditorView(transaction: transaction)
            }
            .sheet(isPresented: $isCreating) {
                TransactionEditorView()
            }
            .task(refreshTransactionCount)
            .onAppear(perform: refreshTransactionCount)
            .onChange(of: windowTransactions.count) { _, _ in
                refreshTransactionCount()
            }
            .onChange(of: pendingReview.count) { _, _ in
                refreshTransactionCount()
            }
        }
    }

    /// Debt payments due within the next 14 days (overdue ones included) —
    /// drives the "Sắp đến hạn" card, hidden when empty.
    private var upcomingItems: [DebtsUpcomingItem] {
        DebtsUpcomingMapper.items(
            for: accounts, now: .now, calendar: AppCalendar.vietnam, withinDays: 14
        )
    }

    // MARK: - Snapshot

    private var snapshot: DashboardSnapshot {
        DashboardSnapshot.make(
            entries: windowTransactions.map { transaction in
                ReportEntry(
                    date: transaction.date,
                    kind: transaction.kind,
                    amount: transaction.amount,
                    categoryID: transaction.category?.id,
                    businessID: transaction.business?.id
                )
            },
            recents: windowTransactions.prefix(8).map { transaction in
                DashboardSnapshot.RecentInput(
                    id: transaction.id,
                    kind: transaction.kind,
                    amount: transaction.amount,
                    date: transaction.date,
                    note: transaction.note,
                    accountName: transaction.account?.name ?? "",
                    toAccountName: transaction.toAccount?.name,
                    category: transaction.category.map {
                        DashboardSnapshot.Visual(
                            name: $0.name, icon: $0.icon, colorHex: $0.colorHex
                        )
                    }
                )
            },
            accounts: accounts.map { account in
                DashboardSnapshot.AccountInput(
                    id: account.id,
                    name: account.name,
                    isLiability: account.kind.isLiability,
                    icon: account.icon,
                    colorHex: account.colorHex,
                    balance: account.balance,
                    isArchived: account.isArchived,
                    sortOrder: account.sortOrder
                )
            },
            categories: Dictionary(uniqueKeysWithValues: categories.map {
                ($0.id, DashboardSnapshot.Visual(
                    name: $0.name, icon: $0.icon, colorHex: $0.colorHex
                ))
            }),
            businesses: Dictionary(uniqueKeysWithValues: businesses.map {
                ($0.id, DashboardSnapshot.Visual(
                    name: $0.name, icon: $0.icon, colorHex: $0.colorHex
                ))
            }),
            pendingReviewCount: pendingReview.count,
            hasAnyTransaction: transactionCount > 0
                || !windowTransactions.isEmpty
                || !pendingReview.isEmpty,
            now: .now,
            calendar: AppCalendar.vietnam
        )
    }

    private func refreshTransactionCount() {
        transactionCount = (try? context.fetchCount(
            FetchDescriptor<LedgerTransaction>()
        )) ?? 0
    }
}

#Preview("Có dữ liệu") {
    let container = try! AppModelContainer.make(inMemory: true)
    let context = ModelContext(container)
    try! SeedData.seedIfNeeded(context: context)
    let account = try! context.fetch(FetchDescriptor<Account>()).first!
    account.openingBalance = 15_000_000
    let categories = try! context.fetch(FetchDescriptor<LedgerCategory>())
    let business = try! context.fetch(FetchDescriptor<Business>()).first!
    let named = { (name: String) in categories.first { $0.name == name } }
    context.insert(LedgerTransaction(
        kind: .income, amount: 20_000_000, note: "Lương",
        account: account, category: named("Lương & thù lao")
    ))
    context.insert(LedgerTransaction(
        kind: .income, amount: 6_000_000,
        date: .now.addingTimeInterval(-3 * 86_400),
        note: "Tiền phòng tháng này",
        account: account, category: named("Tiền thuê phòng"), business: business
    ))
    context.insert(LedgerTransaction(
        kind: .expense, amount: 450_000, note: "Ăn tối",
        account: account, category: named("Ăn uống")
    ))
    context.insert(LedgerTransaction(
        kind: .expense, amount: 300_000,
        date: .now.addingTimeInterval(-86_400), note: "Grab",
        account: account, category: named("Di chuyển"), needsReview: true
    ))
    context.insert(LedgerTransaction(
        kind: .expense, amount: 1_200_000,
        date: .now.addingTimeInterval(-40 * 86_400), note: "Hoá đơn điện",
        account: account, category: named("Hoá đơn")
    ))
    return DashboardView()
        .modelContainer(container)
}

#Preview("Trống") {
    let container = try! AppModelContainer.make(inMemory: true)
    try! SeedData.seedIfNeeded(context: ModelContext(container))
    return DashboardView()
        .modelContainer(container)
}
