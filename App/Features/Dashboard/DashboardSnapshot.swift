import Foundation
import FinanceCore

/// Everything the dashboard cards display, computed once per render from
/// lightweight inputs — report entries, account balances and name lookups —
/// so all aggregation is testable without SwiftData or SwiftUI. The view
/// only renders this snapshot; every total comes from `ReportSummary`.
struct DashboardSnapshot: Equatable {

    // MARK: - Inputs

    /// Name/icon/color styling shared by categories and businesses, looked
    /// up by id so the snapshot never touches SwiftData models.
    struct Visual: Equatable, Sendable {
        var name: String = ""
        var icon: String = ""
        var colorHex: String = ""

        init(name: String = "", icon: String = "", colorHex: String = "") {
            self.name = name
            self.icon = icon
            self.colorHex = colorHex
        }
    }

    /// One account's contribution to net worth and the accounts strip.
    struct AccountInput: Equatable, Sendable {
        var id: UUID
        var name: String
        /// Credit cards and loans — balances are signed, negative is owed.
        var isLiability: Bool
        var icon: String
        var colorHex: String
        /// Signed balance: positive is owned, negative is owed (LedgerMath).
        var balance: Int64
        var isArchived: Bool
        var sortOrder: Int

        init(id: UUID, name: String, isLiability: Bool, icon: String = "",
             colorHex: String = "", balance: Int64, isArchived: Bool = false,
             sortOrder: Int = 0) {
            self.id = id
            self.name = name
            self.isLiability = isLiability
            self.icon = icon
            self.colorHex = colorHex
            self.balance = balance
            self.isArchived = isArchived
            self.sortOrder = sortOrder
        }
    }

    /// One recent transaction with relationship names already resolved.
    struct RecentInput: Equatable, Sendable {
        var id: UUID
        var kind: TransactionKind
        var amount: Int64
        var date: Date
        var note: String
        var accountName: String
        /// Destination account name — transfers only.
        var toAccountName: String?
        var category: Visual?

        init(id: UUID, kind: TransactionKind, amount: Int64, date: Date,
             note: String = "", accountName: String = "",
             toAccountName: String? = nil, category: Visual? = nil) {
            self.id = id
            self.kind = kind
            self.amount = amount
            self.date = date
            self.note = note
            self.accountName = accountName
            self.toAccountName = toAccountName
            self.category = category
        }
    }

    // MARK: - Outputs

    struct NetWorthSummary: Equatable, Sendable {
        var total: Int64
        var assets: Int64
        /// Sum of liability balances — negative or zero.
        var liabilities: Int64
    }

    /// The "Tháng này" card: totals, month-over-month percents and the
    /// personal/business split line.
    struct MonthSummary: Equatable, Sendable {
        var title: String
        var income: Int64
        var expense: Int64
        var net: Int64
        /// Fraction change vs the previous calendar month (0.25 = +25%);
        /// nil when the previous month had no income/expense to compare to.
        var incomeChangePercent: Double?
        var expenseChangePercent: Double?
        var personalExpense: Int64
        var businessIncome: Int64
        var businessExpense: Int64
    }

    /// One chip in the horizontally scrolling accounts strip.
    struct AccountChip: Equatable, Identifiable, Sendable {
        var id: UUID
        var name: String
        var icon: String
        var colorHex: String
        var balance: Int64
    }

    /// One bar group (income vs expense) of the six-month chart.
    struct MonthPoint: Equatable, Identifiable, Sendable {
        var monthStart: Date
        var income: Int64
        var expense: Int64

        var id: Date { monthStart }
    }

    /// One row of the top-expense-categories card. The last row may be the
    /// folded "Khác" bucket (`isOther`), `categoryID == nil` is uncategorized.
    struct CategoryRow: Equatable, Identifiable, Sendable {
        var categoryID: UUID?
        var name: String
        var icon: String
        var colorHex: String
        var total: Int64
        /// Fraction of the month's total expense, 0...1.
        var share: Double
        var isOther: Bool

        var id: String {
            isOther ? "__other" : (categoryID?.uuidString ?? "__uncategorized")
        }
    }

    /// Profit and loss of one business for the month.
    struct BusinessResult: Equatable, Identifiable, Sendable {
        var businessID: UUID
        var name: String
        var icon: String
        var colorHex: String
        var revenue: Int64
        var cost: Int64
        /// revenue - cost; negative is a loss.
        var profit: Int64

        var id: UUID { businessID }
    }

    /// One row of the recent-transactions card — display strings are
    /// precomputed so the view stays a plain renderer.
    struct RecentItem: Equatable, Identifiable, Sendable {
        var id: UUID
        var kind: TransactionKind
        var amount: Int64
        var date: Date
        /// Category name, "Chuyển khoản" for transfers, kind name as fallback.
        var title: String
        /// "note · account (→ destination) · dd/MM".
        var subtitle: String
        var icon: String
        var colorHex: String
    }

    // MARK: - Snapshot fields

    let netWorth: NetWorthSummary
    let month: MonthSummary
    let accountChips: [AccountChip]
    /// Six (or `monthCount`) monthly points, oldest first; zero-filled.
    let months: [MonthPoint]
    let topExpenseCategories: [CategoryRow]
    /// Only businesses with activity this month — empty hides the card.
    let businessResults: [BusinessResult]
    let pendingReviewCount: Int
    let recentItems: [RecentItem]
    /// True on a fresh install (no transactions at all) → the welcome card.
    let isEmpty: Bool

    // MARK: - Builder

    /// Builds the snapshot. `entries` only needs to cover the six-month
    /// window (the builder filters by interval itself); `hasAnyTransaction`
    /// should come from a cheap count over the whole table so users whose
    /// only transactions are older than the window are not shown the
    /// welcome card.
    static func make(
        entries: [ReportEntry],
        recents: [RecentInput] = [],
        accounts: [AccountInput] = [],
        categories: [UUID: Visual] = [:],
        businesses: [UUID: Visual] = [:],
        pendingReviewCount: Int = 0,
        hasAnyTransaction: Bool,
        now: Date,
        calendar: Calendar,
        monthCount: Int = 6,
        topCategoryLimit: Int = 5
    ) -> DashboardSnapshot {
        let current = ReportSummary.monthInterval(containing: now, calendar: calendar)
        let previousStart = calendar.date(byAdding: .month, value: -1, to: current.start)
            ?? current.start
        let previous = ReportDateInterval(start: previousStart, end: current.start)

        let totals = ReportSummary.totals(entries: entries, in: current)
        let previousTotals = ReportSummary.totals(entries: entries, in: previous)
        let split = ReportSummary.splitByOwnership(entries: entries, in: current)
        let month = MonthSummary(
            title: AppDateFormat.monthTitle(current.start, calendar: calendar),
            income: totals.income,
            expense: totals.expense,
            net: totals.net,
            incomeChangePercent: ReportChange(
                current: totals.income, previous: previousTotals.income
            ).percent,
            expenseChangePercent: ReportChange(
                current: totals.expense, previous: previousTotals.expense
            ).percent,
            personalExpense: split.personal.expense,
            businessIncome: split.business.income,
            businessExpense: split.business.expense
        )

        var assets: Int64 = 0
        var liabilities: Int64 = 0
        for account in accounts where !account.isArchived {
            if account.isLiability {
                liabilities = saturatingAdd(liabilities, account.balance)
            } else {
                assets = saturatingAdd(assets, account.balance)
            }
        }
        let netWorth = NetWorthSummary(
            total: saturatingAdd(assets, liabilities),
            assets: assets,
            liabilities: liabilities
        )

        let chips = accounts
            .filter { !$0.isArchived }
            .sorted {
                $0.sortOrder == $1.sortOrder
                    ? $0.name < $1.name
                    : $0.sortOrder < $1.sortOrder
            }
            .map {
                AccountChip(id: $0.id, name: $0.name, icon: $0.icon,
                            colorHex: $0.colorHex, balance: $0.balance)
            }

        let months = ReportSummary.monthly(
            entries: entries, months: monthCount, endingAt: now, calendar: calendar
        ).map {
            MonthPoint(monthStart: $0.monthStart, income: $0.income, expense: $0.expense)
        }

        let categoryRows = ReportSummary.topCategories(
            entries: entries, in: current, kind: .expense, limit: topCategoryLimit
        ).map { row -> CategoryRow in
            let visual: Visual
            if row.isOther {
                visual = Self.otherVisual
            } else if let categoryID = row.categoryID {
                visual = categories[categoryID] ?? Self.uncategorizedVisual
            } else {
                visual = Self.uncategorizedVisual
            }
            return CategoryRow(
                categoryID: row.categoryID,
                name: visual.name, icon: visual.icon, colorHex: visual.colorHex,
                total: row.total, share: row.share, isOther: row.isOther
            )
        }

        let businessResults = ReportSummary.byBusiness(entries: entries, in: current)
            .map { result -> BusinessResult in
                let visual = businesses[result.businessID] ?? Self.businessVisual
                return BusinessResult(
                    businessID: result.businessID,
                    name: visual.name, icon: visual.icon, colorHex: visual.colorHex,
                    revenue: result.revenue, cost: result.cost, profit: result.profit
                )
            }

        let recentItems = recents.map { input -> RecentItem in
            let visual: Visual
            switch input.kind {
            case .transfer:
                visual = Self.transferVisual
            case .income, .expense:
                let fallback = Self.visual(for: input.kind)
                let resolved = input.category ?? fallback
                visual = Visual(
                    name: resolved.name.isEmpty ? fallback.name : resolved.name,
                    icon: resolved.icon.isEmpty ? fallback.icon : resolved.icon,
                    colorHex: resolved.colorHex.isEmpty ? fallback.colorHex : resolved.colorHex
                )
            }
            return RecentItem(
                id: input.id, kind: input.kind, amount: input.amount, date: input.date,
                title: visual.name,
                subtitle: recentSubtitle(input, calendar: calendar),
                icon: visual.icon, colorHex: visual.colorHex
            )
        }

        return DashboardSnapshot(
            netWorth: netWorth,
            month: month,
            accountChips: chips,
            months: months,
            topExpenseCategories: categoryRows,
            businessResults: businessResults,
            pendingReviewCount: pendingReviewCount,
            recentItems: recentItems,
            isEmpty: !hasAnyTransaction
        )
    }

    // MARK: - Display helpers

    /// "0.25" → "+25%", "-0.08" → "-8%".
    static func percentText(_ percent: Double) -> String {
        let value = Int((percent * 100).rounded())
        return value > 0 ? "+\(value)%" : "\(value)%"
    }

    /// "0.4" → "40%" — share label on the top-categories bars.
    static func shareText(_ share: Double) -> String {
        "\(Int((share * 100).rounded()))%"
    }

    // MARK: - Private

    private static func recentSubtitle(_ input: RecentInput, calendar: Calendar) -> String {
        var parts: [String] = []
        if !input.note.isEmpty { parts.append(input.note) }
        var accountsPart = input.accountName
        if input.kind == .transfer,
           let destination = input.toAccountName, !destination.isEmpty {
            accountsPart += accountsPart.isEmpty ? destination : " → \(destination)"
        }
        if !accountsPart.isEmpty { parts.append(accountsPart) }
        parts.append(AppDateFormat.shortDate(input.date, calendar: calendar))
        return parts.joined(separator: " · ")
    }

    private static func saturatingAdd(_ a: Int64, _ b: Int64) -> Int64 {
        let (result, overflow) = a.addingReportingOverflow(b)
        return overflow ? (a < 0 ? .min : .max) : result
    }

    /// Default styling per transaction kind — same icon and color mapping
    /// the account history rows use.
    private static func visual(for kind: TransactionKind) -> Visual {
        switch kind {
        case .income: return Visual(name: "Thu", icon: "arrow.down.left", colorHex: "34C759")
        case .expense: return Visual(name: "Chi", icon: "arrow.up.right", colorHex: "FF3B30")
        case .transfer: return transferVisual
        }
    }

    private static let transferVisual = Visual(
        name: "Chuyển khoản", icon: "arrow.left.arrow.right", colorHex: "64748B"
    )
    private static let uncategorizedVisual = Visual(
        name: "Chưa phân loại", icon: "tag.fill", colorHex: "8E8E93"
    )
    private static let otherVisual = Visual(
        name: "Khác", icon: "ellipsis.circle.fill", colorHex: "8E8E93"
    )
    private static let businessVisual = Visual(
        name: "Kinh doanh", icon: "briefcase.fill", colorHex: "8E8E93"
    )
}
