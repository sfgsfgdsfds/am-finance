import SwiftUI
import SwiftData
import FinanceCore

/// One account: balance header, kind-specific info (credit card / loan), and
/// the 50 most recent transactions touching the account — as source or as
/// transfer destination — grouped by day.
struct AccountDetailView: View {
    let account: Account

    @State private var isEditing = false
    @State private var isAnchoring = false

    init(account: Account) {
        self.account = account
    }

    var body: some View {
        List {
            Section {
                balanceHeader
                    .frame(maxWidth: .infinity)
                    .listRowBackground(Color.clear)
            }

            if account.kind == .creditCard { creditCardInfo }
            if account.kind == .loan { loanInfo }

            Section {
                if account.kind == .receivable {
                    NavigationLink {
                        ReceivableDetailView(account: account)
                    } label: {
                        Label(
                            "Chi tiết khoản phải thu",
                            systemImage: "person.badge.clock.fill")
                    }
                }
                NavigationLink {
                    BalanceTrendView(account: account)
                } label: {
                    Label("Lịch sử số dư", systemImage: "chart.line.uptrend.xyaxis")
                }
                Button {
                    isAnchoring = true
                } label: {
                    Label("Đặt số dư thực tế", systemImage: "checkmark.circle")
                }
            } header: {
                Text("Số dư")
            }

            if !account.note.isEmpty {
                Section("Ghi chú") {
                    Text(account.note)
                }
            }

            transactionsSection
        }
        .listStyle(.insetGrouped)
        .navigationTitle(account.name)
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button("Sửa") { isEditing = true }
            }
        }
        .sheet(isPresented: $isEditing) {
            AccountEditView(account: account)
        }
        .sheet(isPresented: $isAnchoring) {
            BalanceTrendAnchorSheet(account: account)
        }
    }

    // MARK: - Header

    private var balanceHeader: some View {
        VStack(spacing: 8) {
            IconBadge(symbol: account.icon, colorHex: account.colorHex, size: 56)
            Text(account.kind.displayName)
                .font(.subheadline)
                .foregroundStyle(.secondary)
            AmountText(amount: account.balance)
                .font(.title.bold())
            Text(account.kind.isLiability ? "Dư nợ hiện tại" : "Số dư hiện tại")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    // MARK: - Credit card

    /// Debt carried on the card — the account's negative balance, clamped.
    private var cardDebt: Int64 { max(0, -account.balance) }

    private var cardCycleConfig: CreditCardCycleConfig? {
        guard let statementDay = account.statementDay else { return nil }
        return CreditCardCycleConfig(
            statementDay: statementDay,
            graceDays: account.graceDays ?? 0
        )
    }

    private var creditCardInfo: some View {
        Section("Thông tin thẻ") {
            if let limit = account.creditLimit {
                LabeledContent("Hạn mức", value: VND.format(limit))
                LabeledContent("Đã dùng", value: VND.format(cardDebt))
                LabeledContent("Còn lại", value: VND.format(max(0, limit - cardDebt)))
            }
            if let config = cardCycleConfig {
                LabeledContent(
                    "Sao kê tiếp theo",
                    value: AccountDateFormat.full(
                        config.nextClosingDate(onOrAfter: .now, calendar: AppCalendar.vietnam)
                    )
                )
                LabeledContent(
                    "Hạn thanh toán",
                    value: AccountDateFormat.full(
                        config.nextDueDate(onOrAfter: .now, calendar: AppCalendar.vietnam)
                    )
                )
            }
            if account.creditLimit == nil && cardCycleConfig == nil {
                Text("Chưa có thông tin hạn mức hay chu kỳ sao kê.")
                    .foregroundStyle(.secondary)
            }
            NavigationLink {
                CreditCardDetailView(account: account)
            } label: {
                Label("Sao kê & thanh toán thẻ", systemImage: "doc.text.magnifyingglass")
            }
        }
    }

    // MARK: - Loan

    private var loanInfo: some View {
        Section("Thông tin khoản vay") {
            if let principal = account.loanPrincipal {
                LabeledContent("Số tiền gốc", value: VND.format(principal))
            }
            LabeledContent("Dư nợ còn lại", value: VND.format(max(0, -account.balance)))
            if let rate = account.loanAnnualRatePercent {
                LabeledContent(
                    "Lãi suất",
                    value: "\(rate.formatted(.number.precision(.fractionLength(0...2))))%/năm"
                )
            }
            if let term = account.loanTermMonths {
                LabeledContent("Kỳ hạn", value: "\(term) tháng")
            }
            if let startDate = account.loanStartDate {
                LabeledContent("Ngày giải ngân", value: AccountDateFormat.full(startDate))
            }
            if let paymentDay = account.loanPaymentDay {
                LabeledContent("Ngày trả hằng tháng", value: "Ngày \(paymentDay)")
            }
            if let methodRaw = account.loanMethodRaw,
               let method = LoanMethod(rawValue: methodRaw) {
                LabeledContent("Phương thức", value: method.displayName)
            }
            NavigationLink {
                LoanDetailView(account: account)
            } label: {
                Label("Lịch trả nợ", systemImage: "calendar")
            }
        }
    }

    // MARK: - Transactions

    /// Transactions where this account is the source, merged with transfers
    /// where it is the destination — newest first, capped at 50.
    private var recentTransactions: [LedgerTransaction] {
        var seen = Set<UUID>()
        let merged = (account.transactions ?? []) + (account.incomingTransfers ?? [])
        return merged
            .filter { seen.insert($0.id).inserted }
            .sorted { $0.date > $1.date }
            .prefix(50)
            .map { $0 }
    }

    /// Consecutive day groups of `recentTransactions` (already sorted desc).
    private var transactionDays: [AccountTransactionDay] {
        let calendar = AppCalendar.vietnam
        var groups: [AccountTransactionDay] = []
        for transaction in recentTransactions {
            let day = calendar.startOfDay(for: transaction.date)
            if groups.last?.day == day {
                groups[groups.count - 1].items.append(transaction)
            } else {
                groups.append(AccountTransactionDay(day: day, items: [transaction]))
            }
        }
        return groups
    }

    private var transactionsSection: some View {
        Group {
            if transactionDays.isEmpty {
                Section("Giao dịch") {
                    Text("Chưa có giao dịch nào.")
                        .foregroundStyle(.secondary)
                }
            } else {
                ForEach(transactionDays, id: \.day) { group in
                    Section(AppDateFormat.dayHeader(group.day, now: .now)) {
                        ForEach(group.items, id: \.id) { transaction in
                            transactionRow(transaction)
                        }
                    }
                }
            }
        }
    }

    private func transactionRow(_ transaction: LedgerTransaction) -> some View {
        let isSource = transaction.account === account
        let role: LedgerMath.Role = isSource ? .source : .destination
        let delta = LedgerMath.delta(
            kind: transaction.kind, amount: transaction.amount, role: role
        )
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
            AmountText(amount: delta)
        }
    }

    private func transactionTitle(_ transaction: LedgerTransaction) -> String {
        if !transaction.note.isEmpty { return transaction.note }
        return transaction.category?.name ?? transaction.kind.displayName
    }

    private func transactionSubtitle(_ transaction: LedgerTransaction, isSource: Bool) -> String {
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
}

/// One calendar day of transactions in the detail list — a real type so the
/// `ForEach` has a key path to `day`.
struct AccountTransactionDay {
    let day: Date
    var items: [LedgerTransaction]
}

#Preview("Tài khoản tiền mặt") {
    let container = try! AppModelContainer.make(inMemory: true)
    let context = ModelContext(container)
    let account = Account(
        name: "Tiền mặt", kind: .cash,
        openingBalance: 5_000_000, colorHex: "34C759"
    )
    context.insert(account)
    context.insert(LedgerTransaction(
        kind: .expense, amount: 120_000, note: "Ăn trưa", account: account
    ))
    context.insert(LedgerTransaction(
        kind: .income, amount: 2_000_000, date: .now.addingTimeInterval(-86_400),
        note: "Lương", account: account
    ))
    return NavigationStack {
        AccountDetailView(account: account)
    }
    .modelContainer(container)
}

#Preview("Thẻ tín dụng") {
    let container = try! AppModelContainer.make(inMemory: true)
    let context = ModelContext(container)
    let card = Account(
        name: "Thẻ Visa", kind: .creditCard,
        openingBalance: -3_500_000, colorHex: "FF9500"
    )
    card.creditLimit = 30_000_000
    card.statementDay = 25
    card.graceDays = 15
    context.insert(card)
    return NavigationStack {
        AccountDetailView(account: card)
    }
    .modelContainer(container)
}
