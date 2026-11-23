import SwiftUI
import SwiftData
import FinanceCore

/// "Nợ & Thẻ" tab root: total debt split into credit cards and loans, the
/// upcoming payments across both kinds, then one section per kind with a
/// utilization/progress summary per account. Every number comes from
/// `CreditCardOverview` and `LoanPlan` so this screen always agrees with
/// the detail views it pushes to.
struct DebtsView: View {
    @Environment(\.modelContext) private var context
    @Query(sort: \Account.sortOrder) private var accounts: [Account]

    @State private var isCreating = false

    private let basisStore = LoanInterestBasisStore()

    private var ledger: LedgerBalanceStore {
        LedgerBalanceStores.shared(for: context.container)
    }

    private var cards: [Account] {
        accounts.filter { $0.kind == .creditCard && !$0.isArchived }
    }

    private var loans: [Account] {
        accounts.filter { $0.kind == .loan && !$0.isArchived }
    }

    private var totals: DebtsTotals {
        DebtsTotals.make(accounts: cards.map {
            DebtsTotals.Input(
                kind: .creditCard, balance: ledger.balance(of: $0))
        } + loans.map {
            DebtsTotals.Input(
                kind: .loan, balance: ledger.balance(of: $0))
        })
    }

    private var upcoming: [DebtsUpcomingItem] {
        DebtsUpcomingMapper.items(
            for: accounts, basisStore: basisStore,
            now: .now, calendar: AppCalendar.vietnam,
            balanceOf: { ledger.balance(of: $0) },
            cardEntriesOf: { ledger.creditCardEntries(of: $0) }
        )
    }

    var body: some View {
        NavigationStack {
            Group {
                if cards.isEmpty && loans.isEmpty {
                    EmptyStateView(
                        symbol: "creditcard.fill",
                        title: "Chưa có thẻ hay khoản vay",
                        message: "Thêm thẻ tín dụng hoặc khoản vay để theo dõi dư nợ, hạn thanh toán và lịch trả nợ.",
                        actionTitle: "Thêm tài khoản",
                        action: { isCreating = true }
                    )
                } else {
                    list
                }
            }
            .navigationTitle("Nợ & Thẻ")
            .toolbar {
                ToolbarItem(placement: .primaryAction) {
                    Button {
                        isCreating = true
                    } label: {
                        Image(systemName: "plus")
                    }
                    .accessibilityLabel("Thêm thẻ hoặc khoản vay")
                }
            }
            .sheet(isPresented: $isCreating) {
                AccountEditView()
            }
        }
    }

    // MARK: - List

    private var list: some View {
        List {
            Section {
                totalsCard
                    .listRowInsets(EdgeInsets(top: 8, leading: 4, bottom: 8, trailing: 4))
                    .listRowBackground(Color.clear)
            }

            if !upcoming.isEmpty {
                Section("Sắp đến hạn") {
                    ForEach(upcoming) { item in
                        if let account = accounts.first(where: { $0.id == item.accountID }) {
                            NavigationLink {
                                destination(for: item.kind, account: account)
                            } label: {
                                DebtsUpcomingRow(item: item, account: account)
                            }
                        }
                    }
                }
            }

            if !cards.isEmpty {
                Section("Thẻ tín dụng") {
                    ForEach(cards, id: \.id) { card in
                        NavigationLink {
                            CreditCardDetailView(account: card)
                        } label: {
                            cardRow(card)
                        }
                    }
                }
            }

            if !loans.isEmpty {
                Section("Khoản vay") {
                    ForEach(loans, id: \.id) { loan in
                        NavigationLink {
                            LoanDetailView(account: loan)
                        } label: {
                            loanRow(loan)
                        }
                    }
                }
            }
        }
        .listStyle(.insetGrouped)
        // Keeps the last card clear of RootTabView's floating "+".
        .contentMargins(.bottom, 40, for: .scrollContent)
    }

    @ViewBuilder
    private func destination(for kind: DebtsUpcomingKind, account: Account) -> some View {
        switch kind {
        case .creditCard: CreditCardDetailView(account: account)
        case .loan: LoanDetailView(account: account)
        }
    }

    // MARK: - Totals header

    private var totalsCard: some View {
        VStack(spacing: 10) {
            Text("Tổng dư nợ")
                .font(.subheadline)
                .foregroundStyle(.secondary)
            AmountText(amount: -totals.total)
                .font(.title.bold())
            HStack(spacing: 0) {
                column(title: "Thẻ tín dụng", amount: -totals.cardDebt)
                Divider().frame(height: 32)
                column(title: "Khoản vay", amount: -totals.loanDebt)
            }
        }
        .padding(.vertical, 16)
        .padding(.horizontal, 12)
        .frame(maxWidth: .infinity)
        .background(
            Color(.secondarySystemGroupedBackground),
            in: RoundedRectangle(cornerRadius: 16)
        )
        .accessibilityElement(children: .combine)
    }

    private func column(title: String, amount: Int64) -> some View {
        VStack(spacing: 2) {
            Text(title)
                .font(.caption)
                .foregroundStyle(.secondary)
            AmountText(amount: amount)
                .font(.headline)
        }
        .frame(maxWidth: .infinity)
    }

    // MARK: - Credit card rows

    private func overview(for card: Account) -> CreditCardOverview? {
        card.creditCardCycleConfig.map {
            CreditCardOverview.build(
                openingBalance: card.openingBalance,
                entries: ledger.creditCardEntries(of: card),
                config: $0,
                creditLimit: card.creditLimit,
                now: .now,
                calendar: AppCalendar.vietnam
            )
        }
    }

    private func cardRow(_ card: Account) -> some View {
        let debt = max(0, -ledger.balance(of: card))
        let cardOverview = overview(for: card)
        return HStack(spacing: 12) {
            IconBadge(symbol: card.icon, colorHex: card.colorHex, size: 36)
            VStack(alignment: .leading, spacing: 4) {
                HStack {
                    Text(card.name)
                        .font(.subheadline.weight(.medium))
                        .lineLimit(1)
                    Spacer()
                    Text(VND.format(debt))
                        .font(.subheadline.weight(.medium))
                        .monospacedDigit()
                        .foregroundStyle(debt > 0 ? AppTheme.expense : Color.secondary)
                }
                if let cardOverview, cardOverview.creditLimit != nil {
                    ProgressView(value: min(1, cardOverview.utilization))
                        .tint(utilizationColor(cardOverview.utilizationLevel))
                    Text("Đã dùng \(cardOverview.utilizationText) hạn mức")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                dueCaption(cardOverview)
            }
        }
    }

    @ViewBuilder
    private func dueCaption(_ overview: CreditCardOverview?) -> some View {
        if let overview {
            let statement = overview.lastStatement
            if statement.paidInFull {
                Text("Đã thanh toán đủ")
                    .font(.caption)
                    .foregroundStyle(AppTheme.income)
            } else {
                Text(
                    "Còn phải trả \(VND.compact(statement.amountDue)) · " +
                    "hạn \(statement.dueDateText) (\(statement.dueStatusText))"
                )
                .font(.caption)
                .foregroundStyle(statement.isOverdue ? AppTheme.expense : Color.secondary)
            }
        } else {
            Text("Chưa thiết lập chu kỳ sao kê")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    private func utilizationColor(_ level: CreditCardUtilizationLevel) -> Color {
        switch level {
        case .low: return AppTheme.transfer
        case .medium: return Color(.systemOrange)
        case .high: return AppTheme.expense
        }
    }

    // MARK: - Loan rows

    private func loanRow(_ loan: Account) -> some View {
        let balance = ledger.balance(of: loan)
        let plan = LoanPlan(
            account: loan,
            balance: balance,
            basis: basisStore.basis(for: loan.id),
            calendar: AppCalendar.vietnam
        )
        let remaining = plan?.remainingDebt ?? max(0, -balance)
        return HStack(spacing: 12) {
            IconBadge(symbol: loan.icon, colorHex: loan.colorHex, size: 36)
            VStack(alignment: .leading, spacing: 4) {
                HStack {
                    Text(loan.name)
                        .font(.subheadline.weight(.medium))
                        .lineLimit(1)
                    Spacer()
                    Text(VND.format(remaining))
                        .font(.subheadline.weight(.medium))
                        .monospacedDigit()
                        .foregroundStyle(remaining > 0 ? AppTheme.expense : Color.secondary)
                }
                if let plan {
                    if plan.isFullyRepaid {
                        Text("Đã trả hết khoản vay")
                            .font(.caption)
                            .foregroundStyle(AppTheme.income)
                    } else {
                        ProgressView(value: plan.progressFraction)
                            .tint(Color.accentColor)
                        Text("Đã trả \(Int((plan.progressFraction * 100).rounded()))% gốc")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        if let next = plan.nextInstallment {
                            Text(
                                "Kỳ \(next.index): \(VND.compact(next.total)) · " +
                                "hạn \(LoanDateFormat.full(next.dueDate))"
                            )
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        }
                    }
                } else {
                    Text("Chưa đủ thông tin khoản vay")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
        }
    }
}

/// One upcoming-payment row: account badge and name on the left, amount
/// and countdown on the right — the debts list's "Sắp đến hạn" section.
struct DebtsUpcomingRow: View {
    let item: DebtsUpcomingItem
    let account: Account

    var body: some View {
        HStack(spacing: 12) {
            IconBadge(symbol: account.icon, colorHex: account.colorHex, size: 36)
            VStack(alignment: .leading, spacing: 2) {
                Text(account.name)
                    .font(.subheadline.weight(.medium))
                    .lineLimit(1)
                Text("\(item.kind.title) · hạn \(item.dueDateText)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            Spacer()
            VStack(alignment: .trailing, spacing: 2) {
                Text(VND.format(item.amount))
                    .font(.subheadline.weight(.medium))
                    .monospacedDigit()
                Text(item.statusText)
                    .font(.caption)
                    .foregroundStyle(item.isOverdue ? AppTheme.expense : Color.secondary)
            }
        }
    }
}

#Preview("Nợ & Thẻ") {
    let container = try! AppModelContainer.make(inMemory: true)
    let context = ModelContext(container)
    try! SeedData.seedIfNeeded(context: context)

    let bank = Account(
        name: "Techcombank", kind: .bank,
        openingBalance: 25_000_000, colorHex: "0A84FF", sortOrder: 1
    )
    let card = Account(
        name: "Thẻ Visa", kind: .creditCard, colorHex: "FF9500", sortOrder: 2
    )
    card.creditLimit = 30_000_000
    card.statementDay = 20
    card.graceDays = 15
    let loan = Account(
        name: "Vay mua nhà", kind: .loan,
        openingBalance: -402_000_000, colorHex: "BF5AF2", sortOrder: 3
    )
    loan.loanPrincipal = 500_000_000
    loan.loanAnnualRatePercent = 8.4
    loan.loanTermMonths = 60
    loan.loanStartDate = AppCalendar.vietnam.date(byAdding: .month, value: -10, to: .now) ?? .now
    loan.loanPaymentDay = 15
    loan.loanMethodRaw = LoanMethod.annuity.rawValue
    for account in [bank, card, loan] { context.insert(account) }

    // A purchase inside the card's last closed cycle so the preview has a
    // statement due, plus a partial payment after closing.
    let calendar = AppCalendar.vietnam
    let closed = card.creditCardCycleConfig!.lastClosedCycle(asOf: .now, calendar: calendar)
    context.insert(LedgerTransaction(
        kind: .expense, amount: 2_400_000,
        date: calendar.date(byAdding: .day, value: -5, to: closed.end)!,
        note: "Mua sắm", account: card
    ))
    context.insert(LedgerTransaction(
        kind: .transfer, amount: 1_000_000,
        date: min(calendar.date(byAdding: .day, value: 3, to: closed.end)!, .now),
        note: "Trả nợ thẻ Thẻ Visa", account: bank, toAccount: card
    ))
    context.insert(LedgerTransaction(
        kind: .expense, amount: 350_000, date: .now,
        note: "Ăn trưa", account: card
    ))

    return DebtsView()
        .modelContainer(container)
}

#Preview("Trống") {
    let container = try! AppModelContainer.make(inMemory: true)
    try! SeedData.seedIfNeeded(context: ModelContext(container))
    return DebtsView()
        .modelContainer(container)
}
