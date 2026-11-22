import SwiftUI
import SwiftData
import FinanceCore

/// "Most used" categories behind the inbox's one-tap suggestion chips:
/// the categories used most often in the last `windowDays` days for a
/// direction, excluding archived ones and never-used ones.
enum WalletSyncSuggestions {
    static let windowDays = 90

    static func top(
        kind: CategoryKind,
        transactions: [LedgerTransaction],
        categories: [LedgerCategory],
        now: Date,
        days: Int = WalletSyncSuggestions.windowDays,
        limit: Int = 3,
        calendar: Calendar = AppCalendar.vietnam
    ) -> [LedgerCategory] {
        let cutoff = calendar.date(byAdding: .day, value: -days, to: now) ?? now
        let wanted: TransactionKind = kind == .income ? .income : .expense
        var counts: [UUID: Int] = [:]
        for transaction in transactions {
            guard transaction.kind == wanted,
                  transaction.date >= cutoff,
                  let id = transaction.category?.id
            else { continue }
            counts[id, default: 0] += 1
        }
        return Array(
            categories
                .filter { !$0.isArchived && $0.kind == kind && counts[$0.id] != nil }
                .sorted {
                    let left = counts[$0.id] ?? 0
                    let right = counts[$1.id] ?? 0
                    return left != right ? left > right : $0.sortOrder < $1.sortOrder
                }
                .prefix(limit))
    }
}

/// Fast triage for imported rows: one-tap category chips, swipe to clear,
/// convert to an internal transfer, or spawn an auto-rule from the note.
/// Pushed inside an existing NavigationStack — no stack of its own.
struct WalletSyncInboxView: View {
    @Environment(\.modelContext) private var context
    @Query(sort: \LedgerCategory.sortOrder) private var categories: [LedgerCategory]
    @Query(sort: \Business.sortOrder) private var businesses: [Business]
    @Query(sort: \Account.sortOrder) private var accounts: [Account]
    /// Pending rows, newest first.
    @Query private var pending: [LedgerTransaction]
    /// The suggestion window — transactions of the last 90 days.
    @Query private var recent: [LedgerTransaction]

    private let ruleStore: any WalletSyncRuleStoring

    @State private var editing: LedgerTransaction?
    @State private var transferTarget: LedgerTransaction?
    @State private var ruleTarget: LedgerTransaction?

    init(ruleStore: (any WalletSyncRuleStoring)? = nil) {
        self.ruleStore = ruleStore ?? WalletSyncRuleStore()
        let cutoff = AppCalendar.vietnam.date(
            byAdding: .day,
            value: -WalletSyncSuggestions.windowDays,
            to: .now
        ) ?? .now
        _pending = Query(
            filter: #Predicate { $0.needsReview == true },
            sort: \.date, order: .reverse)
        _recent = Query(
            filter: #Predicate { $0.date >= cutoff },
            sort: \.date, order: .reverse)
    }

    var body: some View {
        List {
            ForEach(sections) { section in
                Section(AppDateFormat.dayHeader(section.day, now: .now)) {
                    ForEach(section.rows) { row in
                        rowView(row)
                    }
                }
            }
        }
        .listStyle(.insetGrouped)
        .navigationTitle("Chờ phân loại")
        .overlay {
            if sections.isEmpty {
                EmptyStateView(
                    symbol: "checkmark.tray.fill",
                    title: "Không còn gì chờ",
                    message: "Mọi giao dịch nhập từ ngân hàng đã được phân loại."
                )
            }
        }
        .sheet(item: $editing) { transaction in
            TransactionEditorView(transaction: transaction)
        }
        .sheet(item: $transferTarget) { transaction in
            WalletSyncTransferPicker(
                accounts: accounts.filter {
                    !$0.isArchived && $0.id != transaction.account?.id
                }
            ) { picked in
                _ = WalletSyncTransfer.convert(transaction, with: picked)
                try? context.save()
            }
        }
        .sheet(item: $ruleTarget) { transaction in
            WalletSyncRuleEditView(
                draft: WalletSyncRuleDraft(
                    keyword: transaction.note,
                    direction: transaction.kind == .income ? .moneyIn : .moneyOut),
                store: ruleStore,
                onSaved: { _ in applyRulesToPending() }
            )
        }
    }

    // MARK: - Rows

    private var sections: [TransactionListDaySection] {
        TransactionListGrouping.sections(
            for: pending.map { TransactionListRow(transaction: $0) })
    }

    private var transactionByID: [UUID: LedgerTransaction] {
        Dictionary(pending.map { ($0.id, $0) }) { first, _ in first }
    }

    private func rowView(_ row: TransactionListRow) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .top, spacing: 12) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(row.note.isEmpty ? "Không có ghi chú" : row.note)
                        .font(.body)
                        .lineLimit(2)
                    Text(row.accountName ?? "")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer(minLength: 8)
                VStack(alignment: .trailing, spacing: 2) {
                    AmountText(amount: row.amount, kind: row.kind)
                        .font(.subheadline.weight(.semibold))
                    Text(AppDateFormat.time(row.date))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            suggestionChips(row)
        }
        .padding(.vertical, 2)
        .contentShape(Rectangle())
        .onTapGesture {
            if let transaction = transactionByID[row.id] {
                editing = transaction
            }
        }
        .swipeActions(edge: .leading, allowsFullSwipe: true) {
            Button {
                markReviewed(row.id)
            } label: {
                Label("Đã xem", systemImage: "checkmark")
            }
            .tint(.green)
        }
        .swipeActions(edge: .trailing, allowsFullSwipe: false) {
            Button {
                if let transaction = transactionByID[row.id] {
                    ruleTarget = transaction
                }
            } label: {
                Label("Tạo quy tắc", systemImage: "checklist")
            }
            .tint(.orange)
            Button {
                if let transaction = transactionByID[row.id] {
                    transferTarget = transaction
                }
            } label: {
                Label("Chuyển khoản nội bộ", systemImage: "arrow.left.arrow.right")
            }
            .tint(.blue)
        }
    }

    @ViewBuilder
    private func suggestionChips(_ row: TransactionListRow) -> some View {
        let kind: CategoryKind? = switch row.kind {
        case .income: .income
        case .expense: .expense
        case .transfer: nil
        }
        let suggestions = kind.map {
            WalletSyncSuggestions.top(
                kind: $0,
                transactions: recent,
                categories: categories,
                now: .now)
        } ?? []
        if !suggestions.isEmpty {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 8) {
                    ForEach(suggestions) { category in
                        Button {
                            applyCategory(category, to: row.id)
                        } label: {
                            Label(
                                category.name,
                                systemImage: category.icon.isEmpty
                                    ? AppTheme.fallbackSymbol : category.icon
                            )
                            .font(.caption.weight(.medium))
                            .padding(.horizontal, 10)
                            .padding(.vertical, 6)
                            .foregroundStyle(Color(hex: category.colorHex))
                            .background(
                                Color(hex: category.colorHex).opacity(0.15),
                                in: Capsule())
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
        }
    }

    // MARK: - Actions

    private func markReviewed(_ id: UUID) {
        guard let transaction = transactionByID[id] else { return }
        transaction.needsReview = false
        transaction.updatedAt = .now
        try? context.save()
    }

    private func applyCategory(_ category: LedgerCategory, to id: UUID) {
        guard let transaction = transactionByID[id],
              transaction.kind != .transfer else { return }
        transaction.category = category
        transaction.needsReview = false
        transaction.updatedAt = .now
        try? context.save()
    }

    /// After a rule is created from a row: re-apply the whole rule list to
    /// every still-pending row — older rules keep their priority.
    private func applyRulesToPending() {
        let rules = ruleStore.loadRules()
        let categoryMap = Dictionary(
            categories.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        let businessMap = Dictionary(
            businesses.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        let accountMap = Dictionary(
            accounts.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        for transaction in pending where transaction.needsReview {
            WalletSyncRuleApplier.apply(
                to: transaction,
                rules: rules,
                categories: categoryMap,
                businesses: businessMap,
                accounts: accountMap)
        }
        try? context.save()
    }
}

/// Sheet listing accounts that can be the counterpart of an internal
/// transfer. Owns its NavigationStack.
struct WalletSyncTransferPicker: View {
    let accounts: [Account]
    let onPick: (Account) -> Void

    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            List(accounts, id: \.id) { account in
                HStack(spacing: 12) {
                    IconBadge(symbol: account.icon, colorHex: account.colorHex, size: 32)
                    Text(account.name)
                    Spacer()
                    AmountText(amount: account.balance, compact: true)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
                .contentShape(Rectangle())
                .onTapGesture {
                    onPick(account)
                    dismiss()
                }
            }
            .listStyle(.insetGrouped)
            .navigationTitle("Chuyển khoản nội bộ")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Huỷ") { dismiss() }
                }
            }
        }
    }
}

#Preview {
    let container = try! AppModelContainer.make(inMemory: true)
    let context = ModelContext(container)
    try! SeedData.seedIfNeeded(context: context)
    let bank = Account(
        name: "VPBank *1234", kind: .bank,
        icon: "building.columns.fill", colorHex: "0A84FF")
    context.insert(bank)
    let categories = try! context.fetch(FetchDescriptor<LedgerCategory>())
    let food = categories.first { $0.name == "Ăn uống" }!
    // A categorized history so the suggestion chips have data.
    for index in 0..<4 {
        context.insert(LedgerTransaction(
            kind: .expense, amount: 120_000,
            date: .now.addingTimeInterval(Double(-index - 1) * 86_400),
            note: "Ăn trưa", account: bank, category: food))
    }
    let yesterday = AppCalendar.vietnam.date(
        byAdding: .day, value: -1, to: .now) ?? .now
    context.insert(LedgerTransaction(
        kind: .expense, amount: 155_000,
        note: "GRAB BIKE SGN", account: bank, needsReview: true))
    context.insert(LedgerTransaction(
        kind: .income, amount: 15_000_000, date: yesterday,
        note: "LUONG THANG 11", account: bank, needsReview: true))
    return NavigationStack {
        WalletSyncInboxView()
    }
    .modelContainer(container)
}
