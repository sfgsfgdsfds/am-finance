import Foundation
import FinanceCore

/// Debt totals for the "Nợ & Thẻ" header card: the sum of negative balances
/// over non-archived liability accounts, split into credit cards and loans.
/// Positive balances on liability kinds (a card in credit) count as 0 debt.
struct DebtsTotals: Equatable, Sendable {
    /// Debt carried on credit cards (đồng ≥ 0).
    var cardDebt: Int64 = 0
    /// Debt still owed on loans (đồng ≥ 0).
    var loanDebt: Int64 = 0
    /// `cardDebt + loanDebt`.
    var total: Int64 { cardDebt + loanDebt }

    /// One account's contribution — `balance` is signed, negative is owed.
    struct Input: Equatable, Sendable {
        var kind: AccountKind
        var balance: Int64
        var isArchived: Bool = false

        init(kind: AccountKind, balance: Int64, isArchived: Bool = false) {
            self.kind = kind
            self.balance = balance
            self.isArchived = isArchived
        }
    }

    static func make(accounts: [Input]) -> DebtsTotals {
        var totals = DebtsTotals()
        for account in accounts where !account.isArchived {
            let debt = max(0, saturatingNegate(account.balance))
            switch account.kind {
            case .creditCard: totals.cardDebt = saturatingAdd(totals.cardDebt, debt)
            case .loan: totals.loanDebt = saturatingAdd(totals.loanDebt, debt)
            default: break
            }
        }
        return totals
    }

    private static func saturatingAdd(_ a: Int64, _ b: Int64) -> Int64 {
        let (result, overflow) = a.addingReportingOverflow(b)
        return overflow ? .max : result
    }

    private static func saturatingNegate(_ value: Int64) -> Int64 {
        value == .min ? .max : -value
    }
}

/// Which liability an upcoming payment belongs to — drives the navigation
/// destination and the row's kind label.
enum DebtsUpcomingKind: Equatable, Sendable {
    case creditCard
    case loan

    /// Vietnamese label shown under the account name.
    var title: String {
        switch self {
        case .creditCard: return "Thẻ tín dụng"
        case .loan: return "Khoản vay"
        }
    }
}

/// One upcoming debt payment: a card statement not yet paid in full or a
/// loan's next installment. `daysUntilDue` is negative when overdue and
/// `statusText` is the matching Vietnamese countdown label.
struct DebtsUpcomingItem: Equatable, Identifiable, Sendable {
    let accountID: UUID
    let kind: DebtsUpcomingKind
    /// Amount still to pay (đồng ≥ 0).
    let amount: Int64
    let dueDate: Date
    /// Whole days until `dueDate`; negative means already overdue.
    let daysUntilDue: Int
    /// "Còn 5 ngày" / "Hôm nay" / "Quá hạn 3 ngày".
    let statusText: String
    /// Past due and still owing — the label turns the expense color.
    let isOverdue: Bool
    /// "dd/MM/yyyy" on the app calendar.
    let dueDateText: String

    var id: UUID { accountID }
}

/// Builds the "Sắp đến hạn" list from lightweight per-card and per-loan
/// values — the last closed statement's remainder and the next installment.
/// Pure: no SwiftData, so the ordering, window filter and labels are
/// testable without models.
enum DebtsUpcoming {

    /// A card's contribution: what is still owed on the last closed
    /// statement and when it is due. `amountDue == 0` (paid in full) is
    /// skipped by the builder.
    struct CardDue: Equatable, Sendable {
        var accountID: UUID
        var amountDue: Int64
        var dueDate: Date
        var isArchived: Bool = false

        init(accountID: UUID, amountDue: Int64, dueDate: Date, isArchived: Bool = false) {
            self.accountID = accountID
            self.amountDue = amountDue
            self.dueDate = dueDate
            self.isArchived = isArchived
        }
    }

    /// A loan's contribution: the next installment's total and due date.
    struct LoanDue: Equatable, Sendable {
        var accountID: UUID
        var installmentTotal: Int64
        var dueDate: Date
        var isArchived: Bool = false

        init(accountID: UUID, installmentTotal: Int64, dueDate: Date, isArchived: Bool = false) {
            self.accountID = accountID
            self.installmentTotal = installmentTotal
            self.dueDate = dueDate
            self.isArchived = isArchived
        }
    }

    /// Sorted by due date (id breaks ties deterministically). `withinDays`
    /// bounds the list to payments due within that many days — already
    /// overdue items (negative day counts) always pass, since they are due
    /// too. Cards with `amountDue` 0 and loans with nothing left to pay
    /// are dropped.
    static func build(
        cards: [CardDue],
        loans: [LoanDue],
        now: Date,
        calendar: Calendar = AppCalendar.vietnam,
        withinDays: Int? = nil
    ) -> [DebtsUpcomingItem] {
        let today = calendar.startOfDay(for: now)
        var items: [DebtsUpcomingItem] = []

        for card in cards where !card.isArchived && card.amountDue > 0 {
            items.append(makeItem(
                accountID: card.accountID, kind: .creditCard,
                amount: card.amountDue, dueDate: card.dueDate,
                today: today, calendar: calendar
            ))
        }
        for loan in loans where !loan.isArchived && loan.installmentTotal > 0 {
            items.append(makeItem(
                accountID: loan.accountID, kind: .loan,
                amount: loan.installmentTotal, dueDate: loan.dueDate,
                today: today, calendar: calendar
            ))
        }

        if let withinDays {
            items.removeAll { $0.daysUntilDue > withinDays }
        }
        items.sort {
            ($0.dueDate, $0.accountID.uuidString) < ($1.dueDate, $1.accountID.uuidString)
        }
        return items
    }

    private static func makeItem(
        accountID: UUID, kind: DebtsUpcomingKind,
        amount: Int64, dueDate: Date,
        today: Date, calendar: Calendar
    ) -> DebtsUpcomingItem {
        let days = calendar.dateComponents(
            [.day], from: today, to: calendar.startOfDay(for: dueDate)
        ).day ?? 0
        return DebtsUpcomingItem(
            accountID: accountID,
            kind: kind,
            amount: amount,
            dueDate: dueDate,
            daysUntilDue: days,
            statusText: CreditCardOverview.dueStatusText(daysUntilDue: days),
            isOverdue: days < 0,
            dueDateText: LoanDateFormat.full(dueDate, calendar: calendar)
        )
    }
}

/// Maps live `Account` models to `DebtsUpcoming` inputs, reusing
/// `CreditCardOverview` and `LoanPlan` so every number matches the detail
/// screens. Shared by the debts tab and the dashboard card.
enum DebtsUpcomingMapper {
    /// `balanceOf`/`cardEntriesOf` default to the straightforward
    /// relationship walks; screens with a `LedgerBalanceStore` feed the
    /// cached variants so the map is O(1) per account.
    static func items(
        for accounts: [Account],
        basisStore: LoanInterestBasisStore = LoanInterestBasisStore(),
        now: Date,
        calendar: Calendar = AppCalendar.vietnam,
        withinDays: Int? = nil,
        balanceOf: (Account) -> Int64 = { $0.balance },
        cardEntriesOf: (Account) -> [CreditCardEntry] = { $0.creditCardEntries }
    ) -> [DebtsUpcomingItem] {
        var cards: [DebtsUpcoming.CardDue] = []
        var loans: [DebtsUpcoming.LoanDue] = []
        for account in accounts where !account.isArchived {
            switch account.kind {
            case .creditCard:
                guard let config = account.creditCardCycleConfig else { continue }
                let overview = CreditCardOverview.build(
                    openingBalance: account.openingBalance,
                    entries: cardEntriesOf(account),
                    config: config,
                    creditLimit: account.creditLimit,
                    now: now,
                    calendar: calendar
                )
                let statement = overview.lastStatement
                guard !statement.paidInFull else { continue }
                cards.append(DebtsUpcoming.CardDue(
                    accountID: account.id,
                    amountDue: statement.amountDue,
                    dueDate: statement.dueDate
                ))
            case .loan:
                guard let plan = LoanPlan(
                    account: account,
                    balance: balanceOf(account),
                    basis: basisStore.basis(for: account.id),
                    calendar: calendar
                ), let next = plan.nextInstallment else { continue }
                loans.append(DebtsUpcoming.LoanDue(
                    accountID: account.id,
                    installmentTotal: next.total,
                    dueDate: next.dueDate
                ))
            default:
                continue
            }
        }
        return DebtsUpcoming.build(
            cards: cards, loans: loans,
            now: now, calendar: calendar, withinDays: withinDays
        )
    }
}
