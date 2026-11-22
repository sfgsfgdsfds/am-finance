import SwiftUI
import SwiftData
import FinanceCore

/// Compact dashboard card: the overall personal budget and the two
/// category budgets closest to — or over — their limit for the current
/// month. Self-contained (own queries) and renders nothing when there
/// is no active budget. Tapping pushes `BudgetsView`.
struct BudgetsSummaryCard: View {
    @Query(sort: \Budget.createdAt) private var budgets: [Budget]
    @Query(sort: \LedgerCategory.sortOrder) private var categories: [LedgerCategory]
    /// The current month's expenses — the window the card evaluates.
    @Query private var transactions: [LedgerTransaction]

    init() {
        let interval = ReportSummary.monthInterval(
            containing: .now, calendar: AppCalendar.vietnam)
        let start = interval.start
        let end = interval.end
        let expense = TransactionKind.expense.rawValue
        _transactions = Query(FetchDescriptor<LedgerTransaction>(
            predicate: #Predicate {
                $0.date >= start && $0.date < end && $0.kindRaw == expense
            }
        ))
    }

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
            month: .now,
            now: .now,
            calendar: AppCalendar.vietnam
        )
    }

    var body: some View {
        if !snapshot.isEmpty {
            NavigationLink {
                BudgetsView()
            } label: {
                VStack(alignment: .leading, spacing: 12) {
                    HStack {
                        Text("Ngân sách")
                            .font(.headline)
                        Spacer()
                        Image(systemName: "chevron.right")
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(.tertiary)
                    }
                    VStack(spacing: 14) {
                        if let overall = snapshot.overall {
                            BudgetsRowView(row: overall)
                        }
                        ForEach(snapshot.categories.prefix(2)) { row in
                            BudgetsRowView(row: row)
                        }
                    }
                }
                .padding(16)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(
                    Color(.secondarySystemGroupedBackground),
                    in: RoundedRectangle(cornerRadius: 16)
                )
            }
            .buttonStyle(.plain)
        }
    }
}

#Preview("Có ngân sách") {
    let container = try! AppModelContainer.make(inMemory: true)
    let context = ModelContext(container)
    try! SeedData.seedIfNeeded(context: context)
    let cash = try! context.fetch(FetchDescriptor<Account>()).first!
    let categories = try! context.fetch(FetchDescriptor<LedgerCategory>())
    let food = categories.first { $0.name == "Ăn uống" }!
    let fuel = categories.first { $0.name == "Di chuyển" }!
    context.insert(Budget(monthlyLimit: 12_000_000))
    context.insert(Budget(monthlyLimit: 4_000_000, category: food))
    context.insert(Budget(monthlyLimit: 1_000_000, category: fuel))
    context.insert(LedgerTransaction(
        kind: .expense, amount: 4_200_000, date: .now,
        account: cash, category: food))
    context.insert(LedgerTransaction(
        kind: .expense, amount: 950_000, date: .now,
        account: cash, category: fuel))
    return NavigationStack {
        ScrollView {
            BudgetsSummaryCard()
                .padding(16)
        }
        .background(Color(.systemGroupedBackground))
    }
    .modelContainer(container)
}

#Preview("Trống") {
    let container = try! AppModelContainer.make(inMemory: true)
    try! SeedData.seedIfNeeded(context: ModelContext(container))
    return NavigationStack {
        ScrollView {
            BudgetsSummaryCard()
                .padding(16)
        }
        .background(Color(.systemGroupedBackground))
    }
    .modelContainer(container)
}
