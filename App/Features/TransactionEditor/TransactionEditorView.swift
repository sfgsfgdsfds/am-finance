import SwiftUI
import SwiftData
import FinanceCore

/// Add/edit screen for one `LedgerTransaction` — the fastest path in the
/// app: open, type the amount on the keypad, tap a category, save. Presented
/// as a sheet; owns its NavigationStack and dismisses itself on save, delete
/// or cancel. `transaction == nil` means create mode.
struct TransactionEditorView: View {
    private let transaction: LedgerTransaction?
    private let defaultKind: TransactionKind
    private let defaultAccount: Account?

    @Environment(\.modelContext) private var modelContext
    @Environment(\.dismiss) private var dismiss
    @AppStorage("lastUsedTransactionAccountID") private var lastUsedAccountID = ""

    @Query(sort: \Account.sortOrder) private var accounts: [Account]
    @Query(sort: \LedgerCategory.sortOrder) private var categories: [LedgerCategory]
    @Query(sort: \Business.sortOrder) private var businesses: [Business]

    @State private var draft: TransactionDraft
    @State private var keypadVisible: Bool
    @State private var deleteConfirmationShown = false
    @State private var saveFailed = false

    init(
        transaction: LedgerTransaction? = nil,
        defaultKind: TransactionKind = .expense,
        defaultAccount: Account? = nil
    ) {
        self.transaction = transaction
        self.defaultKind = defaultKind
        self.defaultAccount = defaultAccount
        if let transaction {
            _draft = State(initialValue: TransactionDraft(transaction: transaction))
            _keypadVisible = State(initialValue: false)
        } else {
            _draft = State(initialValue: TransactionDraft(
                kind: defaultKind,
                account: defaultAccount?.isArchived == false ? defaultAccount : nil
            ))
            _keypadVisible = State(initialValue: true)
        }
    }

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                header
                form
            }
            .background(Color(.systemGroupedBackground))
            .navigationTitle(transaction == nil ? "Giao dịch mới" : "Sửa giao dịch")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Huỷ") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Lưu") { save() }
                        .disabled(!draft.isValid)
                }
            }
            .confirmationDialog(
                "Xoá giao dịch này?",
                isPresented: $deleteConfirmationShown,
                titleVisibility: .visible
            ) {
                Button("Xoá giao dịch", role: .destructive, action: deleteTransaction)
                Button("Huỷ", role: .cancel) {}
            } message: {
                Text("Thao tác này không thể hoàn tác.")
            }
            .alert("Không thể lưu", isPresented: $saveFailed) {
                Button("Đóng", role: .cancel) {}
            } message: {
                Text("Giao dịch chưa đầy đủ hoặc dữ liệu không hợp lệ.")
            }
            .onAppear(perform: resolveDefaultAccount)
            .onChange(of: draft.account?.id) { _, _ in
                if draft.toAccount?.id == draft.account?.id {
                    draft.toAccount = nil
                }
            }
        }
    }

    // MARK: - Header: kind, amount, keypad

    private var header: some View {
        VStack(spacing: 8) {
            Picker("Loại giao dịch", selection: kindBinding) {
                ForEach(TransactionKind.allCases, id: \.self) { kind in
                    Text(kind.displayName).tag(kind)
                }
            }
            .pickerStyle(.segmented)

            Button {
                withAnimation(.snappy(duration: 0.2)) { keypadVisible.toggle() }
            } label: {
                AmountText(amount: draft.amount, kind: draft.kind)
                    .font(.largeTitle.bold())
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Số tiền")
            .accessibilityHint(keypadVisible ? "Chạm để ẩn bàn phím" : "Chạm để hiện bàn phím")

            if keypadVisible {
                AmountKeypad(amount: $draft.amount)
            }
        }
        .padding(.horizontal)
        .padding(.top, 4)
        .padding(.bottom, 8)
    }

    private var kindBinding: Binding<TransactionKind> {
        Binding(get: { draft.kind }, set: { draft.setKind($0) })
    }

    // MARK: - Form

    private var form: some View {
        Form {
            Section {
                accountPicker(
                    selection: $draft.account,
                    title: "Tài khoản",
                    excluding: nil
                )
                if draft.kind == .transfer {
                    accountPicker(
                        selection: $draft.toAccount,
                        title: "Đến tài khoản",
                        excluding: draft.account?.id
                    )
                }
            }

            if draft.kind != .transfer {
                Section("Danh mục") {
                    categoryGrid
                }
            }

            Section {
                if draft.kind != .transfer {
                    businessPicker
                }
                dateChips
                DatePicker(
                    "Thời gian",
                    selection: $draft.date,
                    displayedComponents: [.date, .hourAndMinute]
                )
                TextField("Ghi chú", text: $draft.note)
            }

            if transaction != nil {
                Section {
                    Button(role: .destructive) {
                        deleteConfirmationShown = true
                    } label: {
                        Text("Xoá giao dịch")
                            .frame(maxWidth: .infinity)
                    }
                }
            }
        }
        .scrollDismissesKeyboard(.interactively)
    }

    private func accountPicker(
        selection: Binding<Account?>,
        title: String,
        excluding excludedID: UUID?
    ) -> some View {
        Picker(selection: selection) {
            ForEach(visibleAccounts.filter { $0.id != excludedID }, id: \.id) { account in
                Label {
                    HStack {
                        Text(account.name)
                        Spacer(minLength: 8)
                        AmountText(amount: account.balance, compact: true)
                            .font(.subheadline)
                    }
                } icon: {
                    IconBadge(symbol: account.icon, colorHex: account.colorHex, size: 28)
                }
                .tag(account as Account?)
            }
        } label: {
            Text(title)
        }
        .pickerStyle(.navigationLink)
    }

    private var categoryGrid: some View {
        LazyVGrid(
            columns: [GridItem(.adaptive(minimum: 72), spacing: 4)],
            spacing: 4
        ) {
            ForEach(visibleCategories, id: \.id) { category in
                categoryCell(category)
            }
        }
        .padding(.vertical, 4)
        .listRowInsets(EdgeInsets(top: 8, leading: 12, bottom: 8, trailing: 12))
    }

    private func categoryCell(_ category: LedgerCategory) -> some View {
        let selected = draft.category?.id == category.id
        return Button {
            draft.category = category
        } label: {
            VStack(spacing: 4) {
                IconBadge(symbol: category.icon, colorHex: category.colorHex, size: 40)
                Text(category.name)
                    .font(.caption)
                    .lineLimit(1)
                    .foregroundStyle(.primary)
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 8)
            .padding(.horizontal, 2)
            .background(
                selected ? Color.accentColor.opacity(0.15) : .clear,
                in: RoundedRectangle(cornerRadius: 10)
            )
            .overlay {
                if selected {
                    RoundedRectangle(cornerRadius: 10)
                        .strokeBorder(Color.accentColor, lineWidth: 1.5)
                }
            }
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier("txEditor.category.\(category.name)")
        .accessibilityAddTraits(selected ? .isSelected : [])
    }

    private var businessPicker: some View {
        Picker(selection: $draft.business) {
            Text("Cá nhân").tag(Business?.none)
            ForEach(visibleBusinesses, id: \.id) { business in
                Label {
                    Text(business.name)
                } icon: {
                    IconBadge(symbol: business.icon, colorHex: business.colorHex, size: 28)
                }
                .tag(business as Business?)
            }
        } label: {
            Text("Kinh doanh")
        }
        .pickerStyle(.navigationLink)
    }

    private var dateChips: some View {
        HStack(spacing: 8) {
            dateChip("Hôm nay", isSelected: AppCalendar.vietnam.isDateInToday(draft.date)) {
                draft.date = .now
            }
            dateChip("Hôm qua", isSelected: isYesterday(draft.date)) {
                draft.date = AppCalendar.vietnam.date(byAdding: .day, value: -1, to: .now) ?? .now
            }
            Spacer()
        }
    }

    private func dateChip(
        _ title: String,
        isSelected: Bool,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            Text(title)
                .font(.subheadline)
                .padding(.horizontal, 12)
                .padding(.vertical, 6)
                .background(
                    isSelected ? Color.accentColor : Color(.secondarySystemFill),
                    in: Capsule()
                )
                .foregroundStyle(isSelected ? .white : .primary)
        }
        .buttonStyle(.plain)
    }

    // MARK: - Data

    private var visibleAccounts: [Account] {
        accounts.filter { !$0.isArchived }
    }

    private var visibleBusinesses: [Business] {
        businesses.filter { !$0.isArchived }
    }

    private var visibleCategories: [LedgerCategory] {
        guard let wanted = TransactionDraft.categoryKind(for: draft.kind) else {
            return []
        }
        return categories.filter { !$0.isArchived && $0.kind == wanted }
    }

    private func isYesterday(_ date: Date) -> Bool {
        let yesterday = AppCalendar.vietnam.date(byAdding: .day, value: -1, to: .now) ?? .now
        return AppCalendar.vietnam.isDate(date, inSameDayAs: yesterday)
    }

    /// Create mode only: preselect the requested account, else the last used
    /// one, else the first visible account.
    private func resolveDefaultAccount() {
        guard transaction == nil, draft.account == nil else { return }
        draft.account = defaultAccount.flatMap { $0.isArchived ? nil : $0 }
            ?? visibleAccounts.first { $0.id.uuidString == lastUsedAccountID }
            ?? visibleAccounts.first
    }

    private func save() {
        do {
            if let transaction {
                try draft.apply(to: transaction)
            } else {
                try draft.insert(into: modelContext)
            }
            if let account = draft.account {
                lastUsedAccountID = account.id.uuidString
            }
            try modelContext.save()
            dismiss()
        } catch {
            saveFailed = true
        }
    }

    private func deleteTransaction() {
        guard let transaction else { return }
        LedgerTransactionDeletion.delete(transaction, in: modelContext)
        try? modelContext.save()
        dismiss()
    }
}

#Preview("Giao dịch mới") {
    let container = try! AppModelContainer.make(inMemory: true)
    try! SeedData.seedIfNeeded(context: ModelContext(container))
    return TransactionEditorView()
        .modelContainer(container)
}

#Preview("Sửa giao dịch") {
    let container = try! AppModelContainer.make(inMemory: true)
    let context = ModelContext(container)
    try! SeedData.seedIfNeeded(context: context)
    let account = try! context.fetch(FetchDescriptor<Account>()).first!
    let category = try! context.fetch(FetchDescriptor<LedgerCategory>()).first!
    let transaction = LedgerTransaction(
        kind: .expense,
        amount: 125_000,
        note: "Ăn trưa",
        account: account,
        category: category
    )
    context.insert(transaction)
    return TransactionEditorView(transaction: transaction)
        .modelContainer(container)
}
