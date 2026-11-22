import SwiftUI
import SwiftData
import FinanceCore

/// One client receivable: what they still owe, how old the oldest unpaid
/// advance is, the four actions (advance, repayment, service fee,
/// write-off) as sheets, and the day-grouped history of movements.
/// Pushed inside an existing NavigationStack — it does not own one.
struct ReceivableDetailView: View {
    let account: Account

    @Environment(\.modelContext) private var context

    @State private var sheet: ReceivableSheetKind?

    init(account: Account) {
        self.account = account
    }

    private var ledger: LedgerBalanceStore {
        LedgerBalanceStores.shared(for: context.container)
    }

    private var snapshot: ReceivableSnapshot {
        ledger.receivableSnapshot(of: account)
    }

    var body: some View {
        List {
            Section {
                header
                    .frame(maxWidth: .infinity)
                    .listRowBackground(Color.clear)
            }

            Section("Ứng hộ") {
                LabeledContent("Tổng đã ứng") {
                    AmountText(amount: snapshot.totalAdvanced)
                }
                LabeledContent("Đã thu / xoá") {
                    AmountText(amount: snapshot.totalRepaid)
                }
                if snapshot.hasPrepaid {
                    LabeledContent("Khách ứng trước") {
                        Text(VND.format(snapshot.prepaid))
                            .monospacedDigit()
                            .foregroundStyle(.secondary)
                    }
                }
                LabeledContent(
                    "Khoản ứng cũ nhất",
                    value: oldestUnpaidText
                )
            }

            Section("Thao tác") {
                actionRow(
                    title: "Ứng tiền cho khách",
                    symbol: "arrow.up.right",
                    kind: .advance
                )
                actionRow(
                    title: "Khách hoàn tiền",
                    symbol: "arrow.down.left",
                    kind: .repayment
                )
                actionRow(
                    title: "Thu phí dịch vụ",
                    symbol: "briefcase.fill",
                    kind: .serviceFee
                )
                actionRow(
                    title: "Xoá nợ",
                    symbol: "xmark.circle.fill",
                    kind: .writeOff,
                    tint: AppTheme.expense,
                    disabled: snapshot.isSettled
                )
            }

            historySection
        }
        .listStyle(.insetGrouped)
        .navigationTitle(account.name)
        .sheet(item: $sheet) { kind in
            ReceivableActionSheet(account: account, kind: kind)
        }
    }

    // MARK: - Header

    private var header: some View {
        VStack(spacing: 8) {
            IconBadge(symbol: account.icon, colorHex: account.colorHex, size: 56)
            Text(account.business?.name ?? "Cá nhân")
                .font(.subheadline)
                .foregroundStyle(.secondary)
            if snapshot.hasPrepaid {
                Text("Khách ứng trước: \(VND.format(snapshot.prepaid))")
                    .font(.title.bold())
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
            } else {
                AmountText(amount: snapshot.outstanding)
                    .font(.title.bold())
                Text("Khách đang nợ")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }

    /// "45 ngày" — the age of the oldest unpaid advance, "—" when settled.
    private var oldestUnpaidText: String {
        guard let days = snapshot.oldestUnpaidAgeDays(now: .now) else { return "—" }
        return days <= 0 ? "Hôm nay" : "\(days) ngày"
    }

    // MARK: - Actions

    private func actionRow(
        title: String,
        symbol: String,
        kind: ReceivableSheetKind,
        tint: Color = .accentColor,
        disabled: Bool = false
    ) -> some View {
        Button {
            sheet = kind
        } label: {
            Label(title, systemImage: symbol)
        }
        .foregroundStyle(disabled ? Color.secondary : tint)
        .disabled(disabled)
    }

    // MARK: - History

    /// Movements touching this receivable — advances (transfers in,
    /// income), repayments (transfers out) and write-offs (expenses) —
    /// newest first.
    private var history: [LedgerTransaction] {
        var seen = Set<UUID>()
        return ((account.transactions ?? []) + (account.incomingTransfers ?? []))
            .filter { seen.insert($0.id).inserted }
            .sorted { $0.date > $1.date }
    }

    /// Consecutive day groups of `history` (already sorted desc).
    private var historyDays: [ReceivableHistoryDay] {
        let calendar = AppCalendar.vietnam
        var groups: [ReceivableHistoryDay] = []
        for transaction in history {
            let day = calendar.startOfDay(for: transaction.date)
            if groups.last?.day == day {
                groups[groups.count - 1].items.append(transaction)
            } else {
                groups.append(ReceivableHistoryDay(day: day, items: [transaction]))
            }
        }
        return groups
    }

    private var historySection: some View {
        Group {
            if historyDays.isEmpty {
                Section("Lịch sử") {
                    Text("Chưa có khoản ứng nào.")
                        .foregroundStyle(.secondary)
                }
            } else {
                ForEach(historyDays, id: \.day) { group in
                    Section(AppDateFormat.dayHeader(group.day, now: .now)) {
                        ForEach(group.items, id: \.id) { transaction in
                            historyRow(transaction)
                        }
                    }
                }
            }
        }
    }

    private func historyRow(_ transaction: LedgerTransaction) -> some View {
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
                Text(historyTitle(transaction, isSource: isSource))
                    .lineLimit(1)
                Text(historySubtitle(transaction, isSource: isSource))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            Spacer()
            AmountText(amount: delta)
        }
    }

    private func historyTitle(_ transaction: LedgerTransaction, isSource: Bool) -> String {
        if !transaction.note.isEmpty { return transaction.note }
        switch transaction.kind {
        case .transfer: return isSource ? "Khách hoàn tiền" : "Ứng tiền cho khách"
        case .expense: return "Xoá nợ"
        case .income: return "Ghi tăng nợ"
        }
    }

    private func historySubtitle(_ transaction: LedgerTransaction, isSource: Bool) -> String {
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

/// One calendar day of receivable history — a real type so the `ForEach`
/// has a key path to `day`.
struct ReceivableHistoryDay {
    let day: Date
    var items: [LedgerTransaction]
}

#Preview {
    let container = try! AppModelContainer.make(inMemory: true)
    let context = ModelContext(container)
    try! SeedData.seedIfNeeded(context: context)
    let cash = try! context.fetch(FetchDescriptor<Account>()).first!
    let ads = try! context.fetch(FetchDescriptor<Business>())
        .first { $0.name == "Chạy quảng cáo thuê" }!
    let client = Account(
        name: "Khách A — Spa", kind: .receivable, colorHex: "0A84FF"
    )
    client.business = ads
    context.insert(client)
    let calendar = AppCalendar.vietnam
    context.insert(LedgerTransaction(
        kind: .transfer, amount: 15_000_000,
        date: calendar.date(byAdding: .day, value: -45, to: .now)!,
        note: "Ứng chạy ads tháng 10", account: cash, toAccount: client))
    context.insert(LedgerTransaction(
        kind: .transfer, amount: 5_000_000,
        date: calendar.date(byAdding: .day, value: -10, to: .now)!,
        note: "Ứng thêm", account: cash, toAccount: client))
    context.insert(LedgerTransaction(
        kind: .transfer, amount: 8_000_000,
        date: calendar.date(byAdding: .day, value: -3, to: .now)!,
        note: "Khách trả đợt 1", account: client, toAccount: cash))
    return NavigationStack {
        ReceivableDetailView(account: client)
    }
    .modelContainer(container)
}
