import SwiftUI
import SwiftData
import FinanceCore

/// One credit card: debt/limit header with a utilization bar, the last
/// closed statement (what to pay and by when), the open cycle, a "Trả nợ
/// thẻ" action and the card's transactions per cycle. Pushed inside an
/// existing `NavigationStack` — it must not create its own. All numbers come
/// from `CreditCardOverview`.
struct CreditCardDetailView: View {
    let account: Account

    @State private var showsPayment = false
    @State private var showsEdit = false
    @State private var selectedSegment = CreditCardCycleSegment.current

    init(account: Account) {
        self.account = account
    }

    var body: some View {
        Group {
            if let overview {
                detailList(overview)
            } else {
                EmptyStateView(
                    symbol: "creditcard.fill",
                    title: "Chưa thiết lập chu kỳ",
                    message: "Đặt ngày chốt sao kê và số ngày ân hạn để theo dõi kỳ sao kê, hạn thanh toán và trả nợ đúng hạn.",
                    actionTitle: "Thiết lập chu kỳ",
                    action: { showsEdit = true }
                )
            }
        }
        .navigationTitle(account.name)
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button("Trả nợ thẻ") { showsPayment = true }
                    .disabled(debt == 0)
            }
            ToolbarItem(placement: .secondaryAction) {
                Button("Sửa") { showsEdit = true }
            }
        }
        .sheet(isPresented: $showsPayment) {
            CreditCardPaymentSheet(card: account, plan: paymentPlan)
        }
        .sheet(isPresented: $showsEdit) {
            AccountEditView(account: account)
        }
    }

    // MARK: - Overview

    /// Debt on the card regardless of whether a cycle is configured.
    private var debt: Int64 { max(0, -account.balance) }

    private var overview: CreditCardOverview? {
        account.creditCardCycleConfig.map {
            CreditCardOverview.build(
                openingBalance: account.openingBalance,
                entries: account.creditCardEntries,
                config: $0,
                creditLimit: account.creditLimit,
                now: .now,
                calendar: AppCalendar.vietnam
            )
        }
    }

    private var paymentPlan: CreditCardPaymentPlan {
        CreditCardPaymentPlan(
            statementBalance: overview?.lastStatement.balance,
            statementDue: overview?.lastStatement.amountDue,
            minimumPayment: overview?.lastStatement.minimumPayment,
            totalDebt: debt
        )
    }

    // MARK: - List

    private func detailList(_ overview: CreditCardOverview) -> some View {
        List {
            headerSection(overview)
            statementSection(overview.lastStatement)
            openCycleSection(overview.openCycle)

            Section {
                Button {
                    showsPayment = true
                } label: {
                    Label("Trả nợ thẻ", systemImage: "arrow.right.circle.fill")
                        .font(.headline)
                        .frame(maxWidth: .infinity)
                }
                .disabled(overview.debt == 0)
            }

            transactionsSections(overview)
        }
        .listStyle(.insetGrouped)
    }

    // MARK: - Header: debt, limit, utilization

    private func headerSection(_ overview: CreditCardOverview) -> some View {
        Section {
            VStack(spacing: 8) {
                IconBadge(symbol: account.icon, colorHex: account.colorHex, size: 56)
                Text("Dư nợ hiện tại")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                AmountText(amount: overview.debt)
                    .font(.title.bold())
                if overview.creditBalance > 0 {
                    Text("Thẻ đang dư \(VND.format(overview.creditBalance))")
                        .font(.caption)
                        .foregroundStyle(AppTheme.income)
                }
            }
            .frame(maxWidth: .infinity)
            .listRowBackground(Color.clear)

            if let limit = overview.creditLimit, let available = overview.availableCredit {
                LabeledContent("Hạn mức", value: VND.format(limit))
                LabeledContent("Khả dụng", value: VND.format(available))
                VStack(alignment: .leading, spacing: 6) {
                    ProgressView(value: min(1, overview.utilization))
                        .tint(utilizationColor(overview.utilizationLevel))
                    Text("Đã dùng \(overview.utilizationText) hạn mức")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
        }
    }

    private func utilizationColor(_ level: CreditCardUtilizationLevel) -> Color {
        switch level {
        case .low: return AppTheme.transfer
        case .medium: return Color(.systemOrange)
        case .high: return AppTheme.expense
        }
    }

    // MARK: - Last closed statement

    private func statementSection(_ statement: CreditCardStatementInfo) -> some View {
        Section("Sao kê gần nhất") {
            LabeledContent("Kỳ sao kê", value: statement.periodText)
            LabeledContent("Dư nợ chốt kỳ", value: VND.format(statement.balance))

            if statement.paidSinceClosing > 0 {
                LabeledContent(
                    "Đã trả sau chốt",
                    value: VND.format(statement.paidSinceClosing)
                )
            }

            if statement.balance == 0 {
                Text("Kỳ này không phát sinh dư nợ.")
                    .foregroundStyle(.secondary)
            } else if statement.paidInFull {
                Label("Đã thanh toán đủ", systemImage: "checkmark.circle.fill")
                    .foregroundStyle(AppTheme.income)
            } else {
                LabeledContent {
                    Text(VND.format(statement.amountDue))
                        .fontWeight(.semibold)
                        .monospacedDigit()
                        .foregroundStyle(AppTheme.expense)
                } label: {
                    Text("Còn phải trả")
                }
                LabeledContent {
                    VStack(alignment: .trailing, spacing: 2) {
                        Text(statement.dueDateText)
                        Text(statement.dueStatusText)
                            .font(.caption)
                            .foregroundStyle(
                                statement.isOverdue ? AppTheme.expense : Color.secondary
                            )
                    }
                } label: {
                    Text("Hạn thanh toán")
                }
                LabeledContent(
                    "Tối thiểu (ước tính)",
                    value: VND.format(statement.minimumPayment)
                )
            }
        }
    }

    // MARK: - Open cycle

    private func openCycleSection(_ openCycle: CreditCardOpenCycleInfo) -> some View {
        Section("Kỳ hiện tại") {
            LabeledContent("Kỳ sao kê", value: openCycle.periodText)
            LabeledContent("Chi tiêu kỳ này", value: VND.format(openCycle.spending))
            LabeledContent {
                VStack(alignment: .trailing, spacing: 2) {
                    Text(openCycle.closingDateText)
                    Text(openCycle.closingStatusText)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            } label: {
                Text("Chốt sao kê")
            }
        }
    }

    // MARK: - Transactions per cycle

    /// The card's transactions inside `cycle`, newest first.
    private func transactions(in cycle: CreditCardCycle) -> [LedgerTransaction] {
        let calendar = AppCalendar.vietnam
        var seen = Set<UUID>()
        return ((account.transactions ?? []) + (account.incomingTransfers ?? []))
            .filter { seen.insert($0.id).inserted && cycle.contains($0.date, calendar: calendar) }
            .sorted { $0.date > $1.date }
    }

    private func delta(for transaction: LedgerTransaction) -> Int64 {
        let role: LedgerMath.Role = transaction.account === account ? .source : .destination
        return LedgerMath.delta(
            kind: transaction.kind, amount: transaction.amount, role: role
        )
    }

    private func transactionsSections(_ overview: CreditCardOverview) -> some View {
        let cycle = selectedSegment == .current
            ? overview.openCycle.cycle
            : overview.lastStatement.cycle
        let items = transactions(in: cycle)
        let groups = dayGroups(items)
        let spend = items.reduce(Int64(0)) { $0 + max(0, -delta(for: $1)) }
        let paid = items.reduce(Int64(0)) { $0 + max(0, delta(for: $1)) }

        return Group {
            Section("Giao dịch") {
                Picker("Kỳ sao kê", selection: $selectedSegment) {
                    ForEach(CreditCardCycleSegment.allCases, id: \.self) { segment in
                        Text(segment.title).tag(segment)
                    }
                }
                .pickerStyle(.segmented)

                if items.isEmpty {
                    Text("Chưa có giao dịch trong kỳ này.")
                        .foregroundStyle(.secondary)
                } else {
                    LabeledContent {
                        Text(VND.format(spend))
                            .monospacedDigit()
                            .foregroundStyle(AppTheme.expense)
                    } label: {
                        Text("Tổng chi")
                    }
                    LabeledContent {
                        Text(VND.format(paid))
                            .monospacedDigit()
                            .foregroundStyle(AppTheme.income)
                    } label: {
                        Text("Tổng trả")
                    }
                }
            }

            ForEach(groups, id: \.day) { group in
                Section(AppDateFormat.dayHeader(group.day, now: .now)) {
                    ForEach(group.items, id: \.id) { transaction in
                        transactionRow(transaction)
                    }
                }
            }
        }
    }

    private func transactionRow(_ transaction: LedgerTransaction) -> some View {
        let isSource = transaction.account === account
        return HStack(spacing: 12) {
            IconBadge(
                symbol: transaction.category?.icon ?? symbol(for: transaction.kind),
                colorHex: transaction.category?.colorHex ?? colorHex(for: transaction.kind),
                size: 32
            )
            VStack(alignment: .leading, spacing: 2) {
                Text(transactionTitle(transaction))
                    .lineLimit(1)
                Text(transactionSubtitle(transaction, isSource: isSource))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            Spacer()
            AmountText(amount: delta(for: transaction))
        }
    }

    private func transactionTitle(_ transaction: LedgerTransaction) -> String {
        if !transaction.note.isEmpty { return transaction.note }
        return transaction.category?.name ?? transaction.kind.displayName
    }

    private func transactionSubtitle(
        _ transaction: LedgerTransaction, isSource: Bool
    ) -> String {
        var parts = [AppDateFormat.time(transaction.date)]
        if transaction.kind == .transfer {
            if isSource, let destination = transaction.toAccount {
                parts.append("đến \(destination.name)")
            } else if !isSource, let source = transaction.account {
                parts.append("từ \(source.name)")
            }
        }
        return parts.joined(separator: " · ")
    }

    private func symbol(for kind: TransactionKind) -> String {
        switch kind {
        case .income: return "arrow.down.left"
        case .expense: return "arrow.up.right"
        case .transfer: return "arrow.left.arrow.right"
        }
    }

    private func colorHex(for kind: TransactionKind) -> String {
        switch kind {
        case .income: return "34C759"
        case .expense: return "FF3B30"
        case .transfer: return "64748B"
        }
    }

    /// Consecutive day groups over an already newest-first list.
    private func dayGroups(_ items: [LedgerTransaction]) -> [CreditCardDayGroup] {
        let calendar = AppCalendar.vietnam
        var groups: [CreditCardDayGroup] = []
        for transaction in items {
            let day = calendar.startOfDay(for: transaction.date)
            if groups.last?.day == day {
                groups[groups.count - 1].items.append(transaction)
            } else {
                groups.append(CreditCardDayGroup(day: day, items: [transaction]))
            }
        }
        return groups
    }
}

/// Which cycle the transaction list shows.
private enum CreditCardCycleSegment: CaseIterable {
    case current
    case previous

    var title: String {
        switch self {
        case .current: return "Kỳ này"
        case .previous: return "Kỳ trước"
        }
    }
}

/// One calendar day of card transactions — a real type so `ForEach` has a
/// key path to `day`.
private struct CreditCardDayGroup {
    let day: Date
    var items: [LedgerTransaction]
}

#Preview("Đầy đủ") {
    let container = try! AppModelContainer.make(inMemory: true)
    let context = ModelContext(container)
    try! SeedData.seedIfNeeded(context: context)
    let bank = Account(
        name: "Techcombank", kind: .bank,
        openingBalance: 25_000_000, colorHex: "0A84FF", sortOrder: 1
    )
    let card = Account(name: "Thẻ Visa", kind: .creditCard, colorHex: "FF9500", sortOrder: 2)
    card.creditLimit = 30_000_000
    card.statementDay = 20
    card.graceDays = 15
    context.insert(bank)
    context.insert(card)

    let calendar = AppCalendar.vietnam
    let config = card.creditCardCycleConfig!
    let closed = config.lastClosedCycle(asOf: .now, calendar: calendar)
    let paymentDay = min(
        calendar.date(byAdding: .day, value: 3, to: closed.end)!, .now
    )
    context.insert(LedgerTransaction(
        kind: .expense, amount: 2_400_000,
        date: calendar.date(byAdding: .day, value: -5, to: closed.end)!,
        note: "Mua sắm", account: card
    ))
    context.insert(LedgerTransaction(
        kind: .expense, amount: 850_000,
        date: calendar.date(byAdding: .day, value: -2, to: closed.end)!,
        note: "Hoá đơn điện", account: card
    ))
    context.insert(LedgerTransaction(
        kind: .transfer, amount: 1_000_000, date: paymentDay,
        note: "Trả nợ thẻ Thẻ Visa", account: bank, toAccount: card
    ))
    context.insert(LedgerTransaction(
        kind: .expense, amount: 350_000, date: .now,
        note: "Ăn trưa", account: card
    ))
    return NavigationStack {
        CreditCardDetailView(account: card)
    }
    .modelContainer(container)
}

#Preview("Chưa thiết lập") {
    let container = try! AppModelContainer.make(inMemory: true)
    let context = ModelContext(container)
    try! SeedData.seedIfNeeded(context: context)
    let card = Account(
        name: "Thẻ tín dụng", kind: .creditCard,
        openingBalance: -1_200_000, colorHex: "FF9500"
    )
    context.insert(card)
    return NavigationStack {
        CreditCardDetailView(account: card)
    }
    .modelContainer(container)
}
