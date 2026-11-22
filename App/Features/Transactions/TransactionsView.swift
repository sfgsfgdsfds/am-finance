import SwiftUI
import SwiftData
import FinanceCore

/// The transactions tab: a month-by-month, searchable, filterable history
/// of every money movement. Owns its NavigationStack; adding, editing and
/// filtering all happen in sheets.
struct TransactionsView: View {
    @Environment(\.modelContext) private var modelContext

    @Query(sort: \Account.sortOrder) private var accounts: [Account]
    @Query(sort: \LedgerCategory.sortOrder) private var categories: [LedgerCategory]
    @Query(sort: \Business.sortOrder) private var businesses: [Business]

    /// Always the first day of the displayed month — the switcher shifts it.
    @State private var monthAnchor: Date
    @State private var searchText = ""
    @State private var filter = TransactionListFilter()
    @State private var filterShown = false
    @State private var addShown = false
    @State private var editing: LedgerTransaction?
    @State private var pendingDelete: LedgerTransaction?

    init() {
        let now = Date.now
        _monthAnchor = State(initialValue:
            AppCalendar.vietnam.dateInterval(of: .month, for: now)?.start ?? now)
    }

    private var searching: Bool {
        !TransactionListSearch.normalize(searchText).isEmpty
    }

    var body: some View {
        NavigationStack {
            TransactionListContent(
                monthAnchor: $monthAnchor,
                searching: searching,
                searchText: searchText,
                filter: $filter,
                accounts: accounts,
                categories: categories,
                businesses: businesses,
                onEdit: { editing = $0 },
                onDelete: { pendingDelete = $0 },
                onDuplicate: duplicate,
                onAdd: { addShown = true }
            )
            .navigationTitle("Giao dịch")
            .searchable(
                text: $searchText,
                prompt: "Tìm ghi chú, danh mục, số tiền…"
            )
            .toolbar {
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button { filterShown = true } label: {
                        Image(systemName: filter.isActive
                              ? "line.3.horizontal.decrease.circle.fill"
                              : "line.3.horizontal.decrease.circle")
                    }
                    .accessibilityLabel("Bộ lọc")
                }
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button { addShown = true } label: {
                        Image(systemName: "plus")
                    }
                    .accessibilityLabel("Thêm giao dịch")
                }
            }
            .sheet(isPresented: $addShown) {
                TransactionEditorView()
            }
            .sheet(item: $editing) { transaction in
                TransactionEditorView(transaction: transaction)
            }
            .sheet(isPresented: $filterShown) {
                TransactionListFilterSheet(
                    filter: $filter,
                    accounts: accounts,
                    categories: categories,
                    businesses: businesses
                )
            }
            .confirmationDialog(
                "Xoá giao dịch này?",
                isPresented: Binding(
                    get: { pendingDelete != nil },
                    set: { if !$0 { pendingDelete = nil } }
                ),
                titleVisibility: .visible
            ) {
                Button("Xoá giao dịch", role: .destructive) {
                    if let pendingDelete { delete(pendingDelete) }
                }
                Button("Huỷ", role: .cancel) {}
            } message: {
                Text("Thao tác này không thể hoàn tác.")
            }
        }
    }

    private func duplicate(_ transaction: LedgerTransaction) {
        TransactionListDuplicate.insert(of: transaction, into: modelContext)
        try? modelContext.save()
    }

    private func delete(_ transaction: LedgerTransaction) {
        LedgerTransactionDeletion.delete(transaction, in: modelContext)
        try? modelContext.save()
        pendingDelete = nil
    }
}

/// The query-owning body of the transactions tab. It is re-initialized with
/// a new month range or search mode so `@Query` refetches: without search
/// only the visible month is loaded (date-range predicate); while a search
/// text is present every month is scanned and the visible result is capped
/// at `TransactionListSearch.resultCap` rows.
struct TransactionListContent: View {
    @Query private var transactions: [LedgerTransaction]

    @Binding var monthAnchor: Date
    @Binding var filter: TransactionListFilter
    let searching: Bool
    let searchText: String
    let accounts: [Account]
    let categories: [LedgerCategory]
    let businesses: [Business]
    let onEdit: (LedgerTransaction) -> Void
    let onDelete: (LedgerTransaction) -> Void
    let onDuplicate: (LedgerTransaction) -> Void
    let onAdd: () -> Void

    init(
        monthAnchor: Binding<Date>,
        searching: Bool,
        searchText: String,
        filter: Binding<TransactionListFilter>,
        accounts: [Account],
        categories: [LedgerCategory],
        businesses: [Business],
        onEdit: @escaping (LedgerTransaction) -> Void,
        onDelete: @escaping (LedgerTransaction) -> Void,
        onDuplicate: @escaping (LedgerTransaction) -> Void,
        onAdd: @escaping () -> Void
    ) {
        _monthAnchor = monthAnchor
        _filter = filter
        self.searching = searching
        self.searchText = searchText
        self.accounts = accounts
        self.categories = categories
        self.businesses = businesses
        self.onEdit = onEdit
        self.onDelete = onDelete
        self.onDuplicate = onDuplicate
        self.onAdd = onAdd

        let (start, end) = TransactionListGrouping.monthInterval(
            containing: monthAnchor.wrappedValue)
        let predicate: Predicate<LedgerTransaction>? = searching
            ? nil
            : #Predicate { $0.date >= start && $0.date < end }
        var descriptor = FetchDescriptor<LedgerTransaction>(
            predicate: predicate,
            sortBy: [SortDescriptor(\LedgerTransaction.date, order: .reverse)]
        )
        descriptor.relationshipKeyPathsForPrefetching =
            [\.account, \.toAccount, \.category, \.business]
        _transactions = Query(descriptor)
    }

    var body: some View {
        let scan = matchedScan
        VStack(spacing: 0) {
            if !searching {
                monthHeader(scan.rows)
            }
            if !chips.isEmpty {
                chipBar
            }
            listView(scan)
        }
        .background(Color(.systemGroupedBackground))
    }

    // MARK: - Data plumbing

    private var transactionsByID: [UUID: LedgerTransaction] {
        Dictionary(transactions.map { ($0.id, $0) }) { first, _ in first }
    }

    /// Matched rows plus whether the full scan had more than the cap.
    /// While searching the query folds once and iteration stops at
    /// `resultCap + 1` matches, so a 30k-row ledger never materializes the
    /// whole scan per keystroke. Evaluated once per body pass — the result
    /// feeds the month totals, the sections and the cap notice.
    private var matchedScan: (rows: [TransactionListRow], capped: Bool) {
        let query = TransactionListSearch.normalizedQuery(searchText)
        var iterator = transactions.lazy
            .map { TransactionListRow(transaction: $0) }
            .filter { row in
                filter.matches(row)
                    && (!searching
                        || TransactionListSearch.matches(
                            row, query: query,
                            searchable: TransactionListSearch.searchableFields(
                                for: row)))
            }
            .makeIterator()
        if !searching {
            var all: [TransactionListRow] = []
            while let row = iterator.next() { all.append(row) }
            return (all, false)
        }
        var collected: [TransactionListRow] = []
        collected.reserveCapacity(TransactionListSearch.resultCap + 1)
        while collected.count <= TransactionListSearch.resultCap,
              let row = iterator.next() {
            collected.append(row)
        }
        let capped = collected.count > TransactionListSearch.resultCap
        return (Array(collected.prefix(TransactionListSearch.resultCap)), capped)
    }

    private func sections(
        of rows: [TransactionListRow]
    ) -> [TransactionListDaySection] {
        TransactionListGrouping.sections(for: rows)
    }

    // MARK: - Month header card

    private func monthHeader(_ rows: [TransactionListRow]) -> some View {
        VStack(spacing: 12) {
            HStack {
                Button { shiftMonth(-1) } label: {
                    Image(systemName: "chevron.left")
                        .font(.headline)
                        .frame(width: 36, height: 28)
                        .contentShape(Rectangle())
                }
                .accessibilityLabel("Tháng trước")
                Spacer()
                Text(AppDateFormat.monthTitle(monthAnchor))
                    .font(.headline)
                Spacer()
                Button { shiftMonth(1) } label: {
                    Image(systemName: "chevron.right")
                        .font(.headline)
                        .frame(width: 36, height: 28)
                        .contentShape(Rectangle())
                }
                .accessibilityLabel("Tháng sau")
            }

            HStack(spacing: 0) {
                totalCell(
                    "Thu",
                    TransactionListGrouping.incomeTotal(of: rows),
                    kind: .income
                )
                totalCell(
                    "Chi",
                    TransactionListGrouping.expenseTotal(of: rows),
                    kind: .expense
                )
                totalCell(
                    "Chênh lệch",
                    TransactionListGrouping.netTotal(of: rows),
                    kind: nil
                )
            }
        }
        .padding(16)
        .background(
            Color(.secondarySystemGroupedBackground),
            in: RoundedRectangle(cornerRadius: 16)
        )
        .padding(.horizontal, 16)
        .padding(.top, 8)
        .padding(.bottom, 8)
    }

    private func totalCell(
        _ title: String,
        _ amount: Int64,
        kind: TransactionKind?
    ) -> some View {
        VStack(spacing: 3) {
            Text(title)
                .font(.caption)
                .foregroundStyle(.secondary)
            AmountText(amount: amount, kind: kind)
                .font(.subheadline.weight(.semibold))
                .lineLimit(1)
                .minimumScaleFactor(0.5)
        }
        .frame(maxWidth: .infinity)
    }

    private func shiftMonth(_ offset: Int) {
        monthAnchor = TransactionListGrouping.shiftingMonth(
            of: monthAnchor, by: offset)
    }

    // MARK: - Active filter chips

    private struct TransactionListChip: Identifiable {
        let id: String
        let title: String
        let remove: () -> Void
    }

    private var chips: [TransactionListChip] {
        var result: [TransactionListChip] = []
        if let kind = filter.kind {
            result.append(TransactionListChip(id: "kind", title: kind.displayName) {
                filter.kind = nil
            })
        }
        if let accountID = filter.accountID {
            let name = accounts.first { $0.id == accountID }?.name ?? "Tài khoản"
            result.append(TransactionListChip(id: "account", title: name) {
                filter.accountID = nil
            })
        }
        if let categoryID = filter.categoryID {
            let name = categories.first { $0.id == categoryID }?.name ?? "Danh mục"
            result.append(TransactionListChip(id: "category", title: name) {
                filter.categoryID = nil
            })
        }
        switch filter.business {
        case .any:
            break
        case .personal:
            result.append(TransactionListChip(id: "business", title: "Cá nhân") {
                filter.business = .any
            })
        case .business(let businessID):
            let name = businesses.first { $0.id == businessID }?.name ?? "Kinh doanh"
            result.append(TransactionListChip(id: "business", title: name) {
                filter.business = .any
            })
        }
        if filter.onlyNeedsReview {
            result.append(TransactionListChip(id: "review", title: "Chờ phân loại") {
                filter.onlyNeedsReview = false
            })
        }
        return result
    }

    private var chipBar: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                ForEach(chips) { chip in
                    Button(action: chip.remove) {
                        HStack(spacing: 4) {
                            Text(chip.title)
                            Image(systemName: "xmark")
                        }
                        .font(.caption.weight(.medium))
                        .padding(.horizontal, 10)
                        .padding(.vertical, 5)
                        .foregroundStyle(Color.accentColor)
                        .background(Color.accentColor.opacity(0.12), in: Capsule())
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("Bỏ lọc \(chip.title)")
                }
                Button { filter.reset() } label: {
                    Text("Xoá bộ lọc")
                        .font(.caption.weight(.medium))
                        .foregroundStyle(.secondary)
                        .padding(.horizontal, 10)
                        .padding(.vertical, 5)
                        .background(Color(.tertiarySystemFill), in: Capsule())
                }
                .buttonStyle(.plain)
            }
            .padding(.horizontal, 16)
            .padding(.bottom, 8)
        }
    }

    // MARK: - Day-grouped list

    private func listView(
        _ scan: (rows: [TransactionListRow], capped: Bool)
    ) -> some View {
        List {
            ForEach(sections(of: scan.rows)) { section in
                Section {
                    ForEach(section.rows) { row in
                        rowButton(row)
                    }
                } header: {
                    HStack {
                        Text(AppDateFormat.dayHeader(section.day, now: .now))
                        Spacer()
                        if section.incomeTotal > 0 {
                            AmountText(
                                amount: section.incomeTotal,
                                kind: .income,
                                compact: true
                            )
                        }
                        if section.expenseTotal > 0 {
                            AmountText(
                                amount: section.expenseTotal,
                                kind: .expense,
                                compact: true
                            )
                        }
                    }
                    .font(.caption)
                    .textCase(nil)
                }
            }
            if scan.capped {
                Section {
                    Text("Chỉ hiển thị \(TransactionListSearch.resultCap) giao dịch đầu tiên — hãy tìm cụ thể hơn.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity)
                        .multilineTextAlignment(.center)
                        .listRowBackground(Color.clear)
                }
            }
        }
        .listStyle(.insetGrouped)
        .scrollDismissesKeyboard(.interactively)
        .overlay { if scan.rows.isEmpty { emptyState } }
    }

    private func rowButton(_ row: TransactionListRow) -> some View {
        TransactionListRowView(row: row)
        .contentShape(Rectangle())
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("txList.row.\(row.title)")
        .onTapGesture {
            guard let transaction = transactionsByID[row.id] else { return }
            onEdit(transaction)
        }
        .swipeActions(edge: .trailing, allowsFullSwipe: false) {
            Button(role: .destructive) {
                if let transaction = transactionsByID[row.id] {
                    onDelete(transaction)
                }
            } label: {
                Label("Xoá", systemImage: "trash")
            }
        }
        .swipeActions(edge: .leading) {
            Button {
                if let transaction = transactionsByID[row.id] {
                    onDuplicate(transaction)
                }
            } label: {
                Label("Nhân bản", systemImage: "plus.square.on.square")
            }
            .tint(.blue)
        }
    }

    @ViewBuilder private var emptyState: some View {
        if searching || filter.isActive {
            EmptyStateView(
                symbol: "magnifyingglass",
                title: "Không tìm thấy giao dịch",
                message: "Không có giao dịch nào khớp. Thử đổi từ khoá hoặc xoá bộ lọc."
            )
        } else {
            EmptyStateView(
                symbol: "arrow.left.arrow.right",
                title: "Chưa có giao dịch",
                message: "Tháng này chưa có giao dịch nào.",
                actionTitle: "Thêm giao dịch",
                action: onAdd
            )
        }
    }
}

#Preview {
    let container = try! AppModelContainer.make(inMemory: true)
    let context = ModelContext(container)
    try! SeedData.seedIfNeeded(context: context)
    let cash = try! context.fetch(FetchDescriptor<Account>()).first!
    let bank = Account(name: "Ngân hàng", kind: .bank,
                       icon: "building.columns.fill", colorHex: "0A84FF")
    context.insert(bank)
    let categories = try! context.fetch(FetchDescriptor<LedgerCategory>())
    let food = categories.first { $0.name == "Ăn uống" }!
    let salary = categories.first { $0.kind == .income }!
    let business = try! context.fetch(FetchDescriptor<Business>()).first!
    let calendar = AppCalendar.vietnam
    let yesterday = calendar.date(byAdding: .day, value: -1, to: .now)!
    let lastWeek = calendar.date(byAdding: .day, value: -6, to: .now)!
    context.insert(LedgerTransaction(
        kind: .expense, amount: 125_000, date: .now,
        note: "Ăn trưa", account: cash, category: food))
    context.insert(LedgerTransaction(
        kind: .income, amount: 5_000_000, date: yesterday,
        note: "Tiền thuê T11", account: cash, category: salary,
        business: business))
    context.insert(LedgerTransaction(
        kind: .transfer, amount: 2_000_000, date: yesterday,
        account: cash, toAccount: bank))
    context.insert(LedgerTransaction(
        kind: .expense, amount: 240_000, date: lastWeek,
        note: "Đổ xăng", account: cash, needsReview: true))
    return TransactionsView()
        .modelContainer(container)
}
