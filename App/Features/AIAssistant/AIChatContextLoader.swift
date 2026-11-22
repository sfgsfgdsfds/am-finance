import Foundation
import SwiftData
import FinanceCore

/// Collects the lightweight inputs `AIFinanceContextBuilder` needs from
/// SwiftData for the chosen scope. Every query uses a date-range predicate
/// or a tiny lookup table — never the whole transactions table. The async
/// entry point runs on a detached `ModelContext` (reads only), off the
/// main actor; the synchronous core is actor-agnostic so views and tests
/// can call it with their own context.
struct AIChatContextLoader: Sendable {
    let container: ModelContainer
    var calendar: Calendar = AppCalendar.vietnam
    /// Days ahead for "Sắp đến hạn" (debt dues + recurring occurrences).
    var upcomingDays = 30
    /// Cap on per-transaction lines — the newest come first.
    var transactionLineLimit = 120
    /// Cap on recurring-rule lines.
    var recurringLimit = 15

    init(container: ModelContainer) {
        self.container = container
    }

    /// The snapshot for `scope`, gathered on a detached context so the
    /// fetches and aggregations stay off the main actor.
    func snapshot(scope: AIChatScope, now: Date = .now) async throws -> AIFinanceSnapshot {
        let container = self.container
        let options = self
        return try await Task.detached(priority: .userInitiated) {
            let context = ModelContext(container)
            return try Self.makeSnapshot(
                in: context, scope: scope, now: now,
                calendar: options.calendar,
                upcomingDays: options.upcomingDays,
                transactionLineLimit: options.transactionLineLimit,
                recurringLimit: options.recurringLimit
            )
        }.value
    }

    /// The synchronous core — must run on the actor `context` belongs to.
    static func makeSnapshot(
        in context: ModelContext,
        scope: AIChatScope,
        now: Date,
        calendar: Calendar,
        basisStore: LoanInterestBasisStore = LoanInterestBasisStore(),
        upcomingDays: Int = 30,
        transactionLineLimit: Int = 120,
        recurringLimit: Int = 15
    ) throws -> AIFinanceSnapshot {
        let interval = scope.interval(now: now, calendar: calendar)
        let start = interval.start
        let end = interval.end

        let transactions = try context.fetch(FetchDescriptor<LedgerTransaction>(
            predicate: #Predicate { $0.date >= start && $0.date < end },
            sortBy: [SortDescriptor(\LedgerTransaction.date, order: .reverse)]
        ))
        let categories = try context.fetch(FetchDescriptor<LedgerCategory>())
        let businesses = try context.fetch(FetchDescriptor<Business>())
        let accounts = try context.fetch(FetchDescriptor<Account>())
        let budgets = try context.fetch(FetchDescriptor<Budget>())

        let entries = transactions.map {
            ReportEntry(
                date: $0.date, kind: $0.kind, amount: $0.amount,
                categoryID: $0.category?.id, businessID: $0.business?.id)
        }

        var snapshot = AIFinanceSnapshot(
            periodLabel: scope.periodLabel(now: now, calendar: calendar),
            income: ReportSummary.totals(entries: entries, in: interval).income,
            expense: ReportSummary.totals(entries: entries, in: interval).expense
        )

        // Category totals (expense first, then income — the builder splits
        // by kind again anyway).
        let categoryNames = Dictionary(
            categories.map { ($0.id, $0.name) }, uniquingKeysWith: { a, _ in a })
        for kind in [CategoryKind.expense, .income] {
            let transactionKind: TransactionKind = kind == .income ? .income : .expense
            for row in ReportSummary.byCategory(
                entries: entries, in: interval, kind: transactionKind) {
                let name = row.categoryID
                    .flatMap { categoryNames[$0] } ?? "Chưa phân loại"
                snapshot.categories.append(.init(
                    name: name, kind: kind, amount: row.total))
            }
        }

        // Business profit/loss.
        let businessNames = Dictionary(
            businesses.map { ($0.id, $0.name) }, uniquingKeysWith: { a, _ in a })
        for result in ReportSummary.byBusiness(entries: entries, in: interval) {
            snapshot.businesses.append(.init(
                name: businessNames[result.businessID] ?? "Kinh doanh",
                income: result.revenue, expense: result.cost))
        }

        // Account balances (signed — liabilities go negative).
        let live = accounts.filter { !$0.isArchived }
        snapshot.accounts = live
            .sorted {
                $0.sortOrder == $1.sortOrder
                    ? $0.name < $1.name : $0.sortOrder < $1.sortOrder
            }
            .map {
                .init(name: $0.name, kind: $0.kind, balance: $0.balance)
            }

        // Budgets — the same scoping rules `BudgetsSnapshot` applies:
        // the overall limit counts personal spends only, a category limit
        // every spend of its category.
        let month = ReportsPeriod.monthInterval(containing: now, calendar: calendar)
        let spends = transactions.compactMap { transaction
            -> BudgetsSnapshot.SpendInput? in
            guard transaction.kind == .expense, month.contains(transaction.date)
            else { return nil }
            return BudgetsSnapshot.SpendInput(
                categoryID: transaction.category?.id,
                date: transaction.date,
                amount: transaction.amount,
                isBusiness: transaction.business != nil)
        }
        let visuals = Dictionary(
            categories.map {
                ($0.id, BudgetsSnapshot.Visual(
                    name: $0.name, icon: $0.icon, colorHex: $0.colorHex))
            },
            uniquingKeysWith: { a, _ in a })
        let budgetSnapshot = BudgetsSnapshot.make(
            limits: budgets.map {
                .init(id: $0.id, categoryID: $0.category?.id,
                      monthlyLimit: $0.monthlyLimit, isActive: $0.isActive,
                      note: $0.note)
            },
            spends: spends,
            categories: visuals,
            month: now, now: now, calendar: calendar
        )
        for row in budgetSnapshot.categories + [budgetSnapshot.overall].compactMap({ $0 }) {
            snapshot.budgets.append(.init(
                name: row.name,
                spent: row.progress.spent,
                limit: row.progress.limit.monthlyLimit))
        }

        // Upcoming dues: card statements and loan installments inside the
        // window, then recurring occurrences.
        let accountNames = Dictionary(
            live.map { ($0.id, $0.name) }, uniquingKeysWith: { a, _ in a })
        for item in DebtsUpcomingMapper.items(
            for: accounts, basisStore: basisStore,
            now: now, calendar: calendar, withinDays: upcomingDays) {
            snapshot.upcomingDues.append(.init(
                title: accountNames[item.accountID] ?? item.kind.title,
                date: item.dueDate, amount: item.amount))
        }

        let rules = try context.fetch(FetchDescriptor<RecurringRule>(
            predicate: #Predicate { $0.isActive == true }
        ))
        let ruleInputs = rules.map { RecurringUpcoming.Input(rule: $0) }
        let window = RecurringUpcoming.window(
            days: upcomingDays, now: now, calendar: calendar)
        for occurrence in RecurringUpcoming.occurrences(
            in: ruleInputs, window: window, now: now, calendar: calendar) {
            snapshot.upcomingDues.append(.init(
                title: occurrence.title, date: occurrence.date,
                amount: occurrence.amount))
        }

        // One "Định kỳ" line per active rule, soonest next occurrence first.
        let nextDates = RecurringUpcoming.nextOccurrences(
            of: ruleInputs, asOf: now, calendar: calendar)
        let sortedRules = rules.sorted { lhs, rhs in
            let l = nextDates[lhs.id] ?? .distantFuture
            let r = nextDates[rhs.id] ?? .distantFuture
            return l != r ? l < r : lhs.title < rhs.title
        }
        for rule in sortedRules.prefix(max(0, recurringLimit)) {
            let label = rule.recurrenceRule(calendar: calendar)?
                .summary(calendar: calendar) ?? ""
            snapshot.recurring.append(.init(
                name: rule.title, amount: rule.amount, scheduleLabel: label))
        }

        // Per-transaction lines, newest first, capped. Transfers read as
        // money leaving the source account ("A → B"), tagged "Chuyển khoản"
        // so the model never counts them as spending.
        for transaction in transactions.prefix(max(0, transactionLineLimit)) {
            var signedAmount = transaction.amount
            var categoryName = transaction.category?.name
            var accountName = transaction.account?.name
            switch transaction.kind {
            case .income:
                break
            case .expense:
                signedAmount = -signedAmount
            case .transfer:
                signedAmount = -signedAmount
                categoryName = "Chuyển khoản"
                let names = [transaction.account?.name, transaction.toAccount?.name]
                    .compactMap { $0 }
                accountName = names.isEmpty ? nil : names.joined(separator: " → ")
            }
            snapshot.transactions.append(.init(
                date: transaction.date,
                signedAmount: signedAmount,
                categoryName: categoryName,
                businessName: transaction.business?.name,
                accountName: accountName,
                note: transaction.note.isEmpty ? nil : transaction.note))
        }

        return snapshot
    }
}
