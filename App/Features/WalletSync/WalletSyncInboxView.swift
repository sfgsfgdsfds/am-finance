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
///
/// The pending list is paged (`pageSize` rows at a time, loaded as the
/// list scrolls to the end) so a 2,000-row backlog does not fault every
/// row on open; suggestion chips are computed once per direction for the
/// whole list, not once per row.
struct WalletSyncInboxView: View {
    @Environment(\.modelContext) private var context
    @Query(sort: \LedgerCategory.sortOrder) private var categories: [LedgerCategory]
    @Query(sort: \Business.sortOrder) private var businesses: [Business]
    @Query(sort: \Account.sortOrder) private var accounts: [Account]
    /// The suggestion window — transactions of the last 90 days.
    @Query private var recent: [LedgerTransaction]

    private let ruleStore: any WalletSyncRuleStoring
    private static let pageSize = 60

    @State private var editing: LedgerTransaction?
    @State private var transferTarget: LedgerTransaction?
    @State private var ruleTarget: LedgerTransaction?
    /// The loaded prefix of pending rows, newest first.
    @State private var pending: [LedgerTransaction] = []
    /// Total pending rows in the store — `pending.count < total` means
    /// more pages exist.
    @State private var totalPending = 0

    init(ruleStore: (any WalletSyncRuleStoring)? = nil) {
        self.ruleStore = ruleStore ?? WalletSyncRuleStore()
        let cutoff = AppCalendar.vietnam.date(
            byAdding: .day,
            value: -WalletSyncSuggestions.windowDays,
            to: .now
        ) ?? .now
        var recentFetch = FetchDescriptor<LedgerTransaction>(
            predicate: #Predicate { $0.date >= cutoff },
            sortBy: [SortDescriptor(\.date, order: .reverse)]
        )
        recentFetch.relationshipKeyPathsForPrefetching = [\.category]
        _recent = Query(recentFetch)
    }

    private var ledger: LedgerBalanceStore {
        LedgerBalanceStores.shared(for: context.container)
    }

    var body: some View {
        // Suggestion chips per direction — computed once per body
        // evaluation instead of once per row (each access re-scanned the
        // 90-day window in the old code).
        let expenseSuggestions = WalletSyncSuggestions.top(
            kind: .expense, transactions: recent,
            categories: categories, now: .now)
        let incomeSuggestions = WalletSyncSuggestions.top(
            kind: .income, transactions: recent,
            categories: categories, now: .now)
        List {
            ForEach(sections) { section in
                Section(AppDateFormat.dayHeader(section.day, now: .now)) {
                    ForEach(section.rows) { row in
                        rowView(
                            row,
                            expenseSuggestions: expenseSuggestions,
                            incomeSuggestions: incomeSuggestions)
                    }
                }
            }
            if pending.count < totalPending {
                Section {
                    HStack {
                        Spacer()
                        ProgressView()
                            .accessibilityLabel("Đang tải thêm")
                        Spacer()
                    }
                    .onAppear(perform: loadNextPage)
                }
            }
        }
        .listStyle(.insetGrouped)
        .navigationTitle("Chờ phân loại")
        .overlay {
            if pending.isEmpty && totalPending == 0 {
                EmptyStateView(
                    symbol: "checkmark.tray.fill",
                    title: "Không còn gì chờ",
                    message: "Mọi giao dịch nhập từ ngân hàng đã được phân loại."
                )
            }
        }
        .task { refresh() }
        .onAppear(perform: refresh)
        // Any ledger save — local edits, an import finishing — re-reads
        // the loaded window so rows that were classified elsewhere drop
        // out and freshly pending rows appear.
        .onChange(of: ledger.changeCount) { _, _ in refresh() }
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
                drop(transaction.id)
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

    private func rowView(
        _ row: TransactionListRow,
        expenseSuggestions: [LedgerCategory],
        incomeSuggestions: [LedgerCategory]
    ) -> some View {
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
            suggestionChips(
                row,
                expenseSuggestions: expenseSuggestions,
                incomeSuggestions: incomeSuggestions)
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
    private func suggestionChips(
        _ row: TransactionListRow,
        expenseSuggestions: [LedgerCategory],
        incomeSuggestions: [LedgerCategory]
    ) -> some View {
        let suggestions = switch row.kind {
        case .income: incomeSuggestions
        case .expense: expenseSuggestions
        case .transfer: [LedgerCategory]()
        }
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

    // MARK: - Paging

    private static func pendingDescriptor(
        offset: Int, limit: Int
    ) -> FetchDescriptor<LedgerTransaction> {
        var descriptor = FetchDescriptor<LedgerTransaction>(
            predicate: #Predicate { $0.needsReview == true },
            sortBy: [SortDescriptor(\.date, order: .reverse)])
        descriptor.fetchOffset = offset
        descriptor.fetchLimit = limit
        return descriptor
    }

    /// (Re)loads the first page, keeping the currently loaded span so the
    /// scroll position is not lost when the ledger changes under us.
    private func refresh() {
        let limit = max(Self.pageSize, pending.count)
        pending = (try? context.fetch(
            Self.pendingDescriptor(offset: 0, limit: limit))) ?? []
        totalPending = WalletSyncEngine.pendingReviewCount(context: context)
    }

    private func loadNextPage() {
        guard pending.count < totalPending else { return }
        let more = (try? context.fetch(
            Self.pendingDescriptor(
                offset: pending.count, limit: Self.pageSize))) ?? []
        pending.append(contentsOf: more)
    }

    /// Drops a classified row locally — the store refresh reconciles the
    /// rest.
    private func drop(_ id: UUID) {
        if pending.contains(where: { $0.id == id }) {
            pending.removeAll { $0.id == id }
            totalPending = max(0, totalPending - 1)
        }
    }

    // MARK: - Actions

    private func markReviewed(_ id: UUID) {
        guard let transaction = transactionByID[id] else { return }
        transaction.needsReview = false
        transaction.updatedAt = .now
        try? context.save()
        drop(id)
    }

    private func applyCategory(_ category: LedgerCategory, to id: UUID) {
        guard let transaction = transactionByID[id],
              transaction.kind != .transfer else { return }
        transaction.category = category
        transaction.needsReview = false
        transaction.updatedAt = .now
        try? context.save()
        drop(id)
    }

    /// After a rule is created from a row: re-apply the whole rule list to
    /// every still-pending row — older rules keep their priority. Fetches
    /// all pending rows (not just the loaded page) since the user asked
    /// for a full pass.
    private func applyRulesToPending() {
        let rules = WalletSyncCompiledRules(rules: ruleStore.loadRules())
        let categoryMap = Dictionary(
            categories.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        let businessMap = Dictionary(
            businesses.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        let accountMap = Dictionary(
            accounts.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        let allPending = (try? context.fetch(
            FetchDescriptor<LedgerTransaction>(
                predicate: #Predicate { $0.needsReview == true }))) ?? []
        for transaction in allPending {
            rules.apply(
                to: transaction,
                categories: categoryMap,
                businesses: businessMap,
                accounts: accountMap)
        }
        try? context.save()
        refresh()
    }
}

/// Sheet listing accounts that can be the counterpart of an internal
/// transfer. Owns its NavigationStack.
struct WalletSyncTransferPicker: View {
    let accounts: [Account]
    let onPick: (Account) -> Void

    @Environment(\.dismiss) private var dismiss
    @Environment(\.modelContext) private var context

    private var ledger: LedgerBalanceStore {
        LedgerBalanceStores.shared(for: context.container)
    }

    var body: some View {
        NavigationStack {
            List(accounts, id: \.id) { account in
                HStack(spacing: 12) {
                    IconBadge(symbol: account.icon, colorHex: account.colorHex, size: 32)
                    Text(account.name)
                    Spacer()
                    AmountText(
                        amount: ledger.balance(of: account), compact: true)
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
