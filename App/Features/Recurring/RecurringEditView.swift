import SwiftUI
import SwiftData
import FinanceCore

/// Create/edit sheet for one `RecurringRule` (`rule == nil` = create).
/// Owns its NavigationStack. The header mirrors `TransactionEditorView`'s
/// kind/amount/keypad block; the form adds the title, accounts, category,
/// business, the schedule (frequency, interval, start, end condition), a
/// live preview of the next dates, the auto-create toggle and a note. In
/// edit mode "Tạo giao dịch ngay" posts one transaction immediately
/// without advancing `lastGeneratedDate`.
struct RecurringEditView: View {
    private let rule: RecurringRule?

    @Environment(\.modelContext) private var context
    @Environment(\.dismiss) private var dismiss

    @Query(sort: \Account.sortOrder) private var accounts: [Account]
    @Query(sort: \LedgerCategory.sortOrder) private var categories: [LedgerCategory]
    @Query(sort: \Business.sortOrder) private var businesses: [Business]

    @State private var draft: RecurringDraft
    @State private var keypadVisible: Bool
    @State private var saveFailed = false
    @State private var createdNow = false

    init(rule: RecurringRule? = nil) {
        self.rule = rule
        _draft = State(initialValue: rule.map(RecurringDraft.init) ?? RecurringDraft())
        _keypadVisible = State(initialValue: rule == nil)
    }

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                header
                form
            }
            .background(Color(.systemGroupedBackground))
            .navigationTitle(rule == nil ? "Quy tắc lặp lại mới" : "Sửa quy tắc lặp lại")
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
            .alert("Không thể lưu", isPresented: $saveFailed) {
                Button("Đóng", role: .cancel) {}
            } message: {
                Text("Quy tắc chưa đầy đủ hoặc dữ liệu không hợp lệ.")
            }
            .alert("Đã tạo giao dịch", isPresented: $createdNow) {
                Button("Đóng", role: .cancel) {}
            } message: {
                Text("Một giao dịch đã được thêm cho hôm nay.")
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
            Section("Tên") {
                TextField("Ví dụ: Tiền thuê phòng", text: $draft.title)
            }

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
                Section {
                    businessPicker
                }
            }

            scheduleSection

            if !previewDates.isEmpty {
                Section("3 ngày tới") {
                    ForEach(previewDates, id: \.self) { date in
                        Text(AppDateFormat.dayHeader(date, now: .now))
                    }
                }
            }

            Section {
                Toggle("Tự tạo giao dịch khi đến hạn", isOn: $draft.autoCreate)
                TextField("Ghi chú", text: $draft.note)
            }

            if rule != nil {
                Section {
                    Button {
                        createNow()
                    } label: {
                        Text("Tạo giao dịch ngay")
                            .frame(maxWidth: .infinity)
                    }
                }
            }
        }
        .scrollDismissesKeyboard(.interactively)
    }

    private var scheduleSection: some View {
        Section {
            Picker("Tần suất", selection: $draft.frequency) {
                ForEach(RecurrenceFrequency.allCases, id: \.self) { frequency in
                    Text(frequency.displayName).tag(frequency)
                }
            }
            Stepper("Mỗi \(draft.interval) \(intervalUnitName)", value: $draft.interval, in: 1...99)
            DatePicker(
                "Ngày bắt đầu",
                selection: $draft.startDate,
                displayedComponents: .date
            )
            .environment(\.calendar, AppCalendar.vietnam)
            Picker("Kết thúc", selection: $draft.endMode) {
                ForEach(RecurringEndMode.allCases, id: \.self) { mode in
                    Text(mode.displayName).tag(mode)
                }
            }
            if draft.endMode == .date {
                DatePicker(
                    "Ngày kết thúc",
                    selection: $draft.endDate,
                    in: AppCalendar.vietnam.startOfDay(for: draft.startDate)...,
                    displayedComponents: .date
                )
                .environment(\.calendar, AppCalendar.vietnam)
            }
            if draft.endMode == .count {
                Stepper("Số lần: \(draft.endCount)", value: $draft.endCount, in: 1...999)
            }
        } header: {
            Text("Lặp lại")
        } footer: {
            if let summary = draft.schedule(calendar: AppCalendar.vietnam)?
                .summary(calendar: AppCalendar.vietnam) {
                Text(summary)
            }
        }
    }

    private var intervalUnitName: String {
        switch draft.frequency {
        case .daily: return "ngày"
        case .weekly: return "tuần"
        case .monthly: return "tháng"
        case .yearly: return "năm"
        }
    }

    private var previewDates: [Date] {
        draft.previewDates(count: 3, calendar: AppCalendar.vietnam)
    }

    // MARK: - Pickers

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
                        AmountText(
                            amount: LedgerBalanceStores.shared(
                                for: context.container
                            ).balance(of: account),
                            compact: true)
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

    /// Create mode only: preselect the first non-archived account.
    private func resolveDefaultAccount() {
        guard rule == nil, draft.account == nil else { return }
        draft.account = visibleAccounts.first
    }

    // MARK: - Actions

    private func save() {
        do {
            if let rule {
                try draft.apply(to: rule)
            } else {
                try draft.insert(into: context)
            }
            try context.save()
            dismiss()
        } catch {
            saveFailed = true
        }
    }

    /// "Tạo giao dịch ngay" — posts one transaction dated now, using the
    /// same field mapping as `RecurringGenerator`, and deliberately
    /// leaves `lastGeneratedDate` alone so the generator neither skips
    /// nor repeats an occurrence.
    private func createNow() {
        guard let rule else { return }
        context.insert(Self.makeTransaction(from: rule, at: .now))
        try? context.save()
        createdNow = true
    }

    /// One LedgerTransaction from a rule's current fields — the same
    /// mapping `RecurringGenerator` applies, dated `date` instead of an
    /// occurrence's day.
    static func makeTransaction(from rule: RecurringRule, at date: Date) -> LedgerTransaction {
        LedgerTransaction(
            kind: rule.kind,
            amount: rule.amount,
            date: date,
            note: rule.note.isEmpty ? rule.title : rule.note,
            account: rule.account,
            toAccount: rule.toAccount,
            category: rule.category,
            business: rule.business
        )
    }
}

#Preview("Quy tắc mới") {
    let container = try! AppModelContainer.make(inMemory: true)
    try! SeedData.seedIfNeeded(context: ModelContext(container))
    return RecurringEditView()
        .modelContainer(container)
}

#Preview("Sửa quy tắc") {
    let container = try! AppModelContainer.make(inMemory: true)
    let context = ModelContext(container)
    try! SeedData.seedIfNeeded(context: context)
    let cash = try! context.fetch(FetchDescriptor<Account>()).first!
    let category = try! context.fetch(FetchDescriptor<LedgerCategory>())
        .first { $0.kind == .expense }!
    let rule = RecurringRule(
        title: "ChatGPT Plus", kind: .expense, amount: 500_000,
        note: "Gói tháng", account: cash, category: category,
        frequency: .monthly, startDate: .now
    )
    context.insert(rule)
    return RecurringEditView(rule: rule)
        .modelContainer(container)
}
