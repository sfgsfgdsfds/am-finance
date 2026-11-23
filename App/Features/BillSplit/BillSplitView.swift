import SwiftUI
import SwiftData
import FinanceCore

/// The editor-draft values a new bill is seeded with — a plain copy, so
/// cancelling the split sheet leaves the editor's unsaved draft
/// untouched.
struct BillSplitSeed {
    var total: Int64
    var payer: Account?
    var date: Date
    var category: LedgerCategory?
    var note: String
}

/// One friend row on the split sheet: `account` picks an existing
/// personal receivable, nil means a new person named `name`.
struct BillSplitFriend: Identifiable {
    var id = UUID()
    var account: Account?
    var name = ""
}

/// "Chia bill" — posts a shared bill through `BillSplitService`. With no
/// `transaction` the sheet is seeded from the transaction editor's
/// unsaved draft and `splitNewBill` posts the own-share expense plus one
/// advance per friend; with a saved row the sheet locks source
/// total/payer/date/provenance and `splitExistingExpense` shrinks it in
/// place under a `BillSplitOriginal` precondition. Cancel never touches
/// the editor; a successful save dismisses it through `onSaved` without
/// going through the editor's own "Lưu" path.
struct BillSplitView: View {
    /// The saved expense being split — nil for a new bill.
    private let transaction: LedgerTransaction?
    /// The snapshot captured when the sheet opened (existing mode only).
    private let expected: BillSplitOriginal?
    /// The editor holds unsaved edits — disclosed since they are not
    /// part of the split.
    private let editorHasPendingEdits: Bool
    private let onSaved: () -> Void

    @Environment(\.modelContext) private var context
    @Environment(\.dismiss) private var dismiss
    @Query(sort: \Account.sortOrder) private var accounts: [Account]
    @Query(sort: \LedgerCategory.sortOrder) private var categories: [LedgerCategory]

    @State private var total: Int64
    @State private var payer: Account?
    @State private var date: Date
    @State private var category: LedgerCategory?
    @State private var note: String
    @State private var friends: [BillSplitFriend]
    @State private var keypadVisible: Bool
    @State private var saving = false
    @State private var failure: BillSplitError?

    /// New bill seeded from the editor's draft.
    init(seed: BillSplitSeed, onSaved: @escaping () -> Void) {
        transaction = nil
        expected = nil
        editorHasPendingEdits = false
        self.onSaved = onSaved
        _total = State(initialValue: seed.total)
        _payer = State(initialValue: seed.payer.flatMap {
            ReceivableActions.canAdvance(from: $0) ? $0 : nil
        })
        _date = State(initialValue: seed.date)
        _category = State(initialValue: seed.category)
        _note = State(initialValue: seed.note)
        _friends = State(initialValue: [BillSplitFriend()])
        _keypadVisible = State(initialValue: true)
    }

    /// In-place split of a saved expense — `expected` is the snapshot
    /// taken when the sheet opened and is re-checked by the service.
    init(
        transaction: LedgerTransaction,
        expected: BillSplitOriginal,
        editorHasPendingEdits: Bool,
        onSaved: @escaping () -> Void
    ) {
        self.transaction = transaction
        self.expected = expected
        self.editorHasPendingEdits = editorHasPendingEdits
        self.onSaved = onSaved
        _total = State(initialValue: expected.amount)
        _payer = State(initialValue: transaction.account)
        _date = State(initialValue: expected.date)
        _category = State(initialValue: transaction.category)
        _note = State(initialValue: expected.note)
        _friends = State(initialValue: [BillSplitFriend()])
        _keypadVisible = State(initialValue: false)
    }

    private var ledger: LedgerBalanceStore {
        LedgerBalanceStores.shared(for: context.container)
    }

    /// The locked total: the snapshot amount for an existing row, the
    /// editable keypad amount for a new bill.
    private var billTotal: Int64 {
        expected?.amount ?? total
    }

    private var plan: BillSplit.Plan? {
        try? BillSplit.plan(
            total: billTotal, participants: friends.count + 1)
    }

    private var participants: [BillSplitParticipant] {
        friends.map { friend in
            if let account = friend.account { return .existing(account) }
            return .newPerson(friend.name)
        }
    }

    private var personalReceivables: [Account] {
        accounts.filter {
            $0.kind == .receivable && $0.business == nil && !$0.isArchived
        }
    }

    private var payableAccounts: [Account] {
        accounts.filter { ReceivableActions.canAdvance(from: $0) }
    }

    private var expenseCategories: [LedgerCategory] {
        categories.filter { $0.kind == .expense && !$0.isArchived }
    }

    /// The first problem blocking "Lưu chia bill", surfaced as the
    /// participants section's footer — mirrors the service's own
    /// validations so a disabled save always explains itself.
    private var validationHint: String? {
        if transaction == nil {
            if billTotal <= 0 {
                return "Nhập tổng hoá đơn trước."
            }
            if payer == nil || !ReceivableActions.canAdvance(from: payer!) {
                return "Chọn tài khoản trả — tiền mặt, ngân hàng, ví điện tử hoặc thẻ tín dụng."
            }
        }
        if friends.isEmpty {
            return "Thêm ít nhất một người để chia."
        }
        let trimmedNames = friends.map {
            $0.name.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        if friends.indices.contains(where: {
            friends[$0].account == nil && trimmedNames[$0].isEmpty
        }) {
            return "Điền tên hoặc chọn phải thu cho mỗi người."
        }
        let pickedIDs = friends.compactMap { $0.account?.id }
        if Set(pickedIDs).count != pickedIDs.count {
            return BillSplitError.duplicateParticipant.errorDescription
        }
        var foldedNew = Set<String>()
        for (index, friend) in friends.enumerated()
        where friend.account == nil {
            let key = SettingsNameNormalizer.fold(trimmedNames[index])
            if !foldedNew.insert(key).inserted {
                return BillSplitError.duplicateParticipant.errorDescription
            }
            if personalReceivables.contains(where: {
                SettingsNameNormalizer.fold($0.name) == key
            }) {
                return BillSplitError.participantNameMatchesExisting
                    .errorDescription
            }
        }
        if plan == nil {
            return "Số tiền quá nhỏ để chia đều cho \(friends.count + 1) người."
        }
        return nil
    }

    private var canSave: Bool {
        validationHint == nil && !saving
    }

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                if transaction == nil { newBillHeader }
                form
            }
            .background(Color(.systemGroupedBackground))
            .navigationTitle("Chia bill")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Huỷ") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Lưu chia bill") { save() }
                        .disabled(!canSave)
                }
            }
            .alert("Không thể lưu chia bill", isPresented: failurePresented) {
                Button("Đóng", role: .cancel) {}
            } message: {
                Text(failure?.errorDescription ?? "")
            }
        }
    }

    // MARK: - New-bill header: total + keypad

    private var newBillHeader: some View {
        VStack(spacing: 8) {
            Button {
                withAnimation(.snappy(duration: 0.2)) { keypadVisible.toggle() }
            } label: {
                Text(VND.format(total))
                    .font(.largeTitle.bold())
                    .monospacedDigit()
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Tổng hoá đơn")
            .accessibilityHint(keypadVisible ? "Chạm để ẩn bàn phím" : "Chạm để hiện bàn phím")

            if keypadVisible {
                AmountKeypad(amount: $total)
            }
        }
        .padding(.horizontal)
        .padding(.top, 4)
        .padding(.bottom, 8)
    }

    // MARK: - Form

    private var form: some View {
        Form {
            if let transaction {
                sourceSection(transaction)
                // An uncategorized source (typically a synced row) can be
                // classified inside the split — or left as-is, in which
                // case the review flag stays on.
                if transaction.category == nil {
                    Section {
                        categoryPicker
                    } footer: {
                        Text("Không chọn thì giao dịch vẫn nằm trong \"Chờ phân loại\".")
                    }
                }
            } else {
                newBillSections
            }
            participantsSection
            previewSection
        }
        .scrollDismissesKeyboard(.interactively)
    }

    /// Locked source values for an in-place split — the disclosure that
    /// a saved row is being shrunk, not re-entered.
    private func sourceSection(
        _ transaction: LedgerTransaction
    ) -> some View {
        Section {
            LabeledContent("Tổng hoá đơn") {
                Text(VND.format(billTotal)).monospacedDigit()
            }
            LabeledContent("Trả từ") {
                Text(transaction.account?.name ?? "—")
            }
            LabeledContent("Ngày") {
                Text("\(AppDateFormat.shortDate(expected?.date ?? transaction.date)) \(AppDateFormat.time(expected?.date ?? transaction.date))")
            }
            if let note = expected?.note, !note.isEmpty {
                LabeledContent("Ghi chú") {
                    Text(note).lineLimit(1)
                }
            }
            if let category = transaction.category {
                LabeledContent("Danh mục") {
                    Text(category.name).lineLimit(1)
                }
            }
        } header: {
            Text("Giao dịch đang được chia")
        } footer: {
            Text(existingDisclosure)
        }
    }

    private var existingDisclosure: String {
        var text = "Phần của bạn giữ nguyên ngày, tài khoản và nguồn gốc; phần các bạn thành khoản phải thu."
        if editorHasPendingEdits {
            text += " Các thay đổi chưa lưu trong form sửa sẽ không được áp dụng."
        }
        return text
    }

    private var newBillSections: some View {
        Group {
            Section {
                payerPicker
                DatePicker(
                    "Thời gian",
                    selection: $date,
                    displayedComponents: [.date, .hourAndMinute]
                )
                TextField("Ghi chú", text: $note)
            }
            Section("Danh mục") {
                categoryPicker
            }
        }
    }

    private var payerPicker: some View {
        Picker(selection: $payer) {
            ForEach(payableAccounts, id: \.id) { account in
                Label {
                    HStack {
                        Text(account.name)
                        Spacer(minLength: 8)
                        AmountText(
                            amount: ledger.balance(of: account),
                            compact: true)
                            .font(.subheadline)
                    }
                } icon: {
                    IconBadge(
                        symbol: account.icon,
                        colorHex: account.colorHex, size: 28)
                }
                .tag(account as Account?)
            }
        } label: {
            Text("Trả từ")
        }
        .pickerStyle(.navigationLink)
    }

    private var categoryPicker: some View {
        Picker(selection: $category) {
            Text("Không có").tag(nil as LedgerCategory?)
            ForEach(expenseCategories, id: \.id) { category in
                Label {
                    Text(category.name)
                } icon: {
                    IconBadge(
                        symbol: category.icon,
                        colorHex: category.colorHex, size: 28)
                }
                .tag(category as LedgerCategory?)
            }
        } label: {
            Text("Danh mục")
        }
        .pickerStyle(.navigationLink)
    }

    // MARK: - Participants

    private var participantsSection: some View {
        Section {
            HStack {
                Label("Tôi", systemImage: "person.fill")
                Spacer()
                Text(plan.map { VND.format($0.ownShare) } ?? "—")
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
            }
            ForEach($friends) { $friend in
                friendRow($friend)
            }
            .onDelete { friends.remove(atOffsets: $0) }
            Button {
                friends.append(BillSplitFriend())
            } label: {
                Label("Thêm người", systemImage: "plus.circle.fill")
            }
            .accessibilityIdentifier("billSplit.addFriend")
        } header: {
            Text("Chia đều cho \(friends.count + 1) người")
        } footer: {
            if let validationHint {
                Text(validationHint)
            }
        }
    }

    private func friendRow(_ friend: Binding<BillSplitFriend>) -> some View {
        let index = friends.firstIndex { $0.id == friend.wrappedValue.id } ?? 0
        return VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 8) {
                Picker(selection: friend.account) {
                    Text("Người mới").tag(nil as Account?)
                    ForEach(personalReceivables, id: \.id) { account in
                        Text(account.name).tag(account as Account?)
                    }
                } label: {
                    Text("Người \(index + 1)")
                }
                .pickerStyle(.menu)
                .labelsHidden()
                .accessibilityLabel("Người \(index + 1)")
                Spacer(minLength: 4)
                if let share = plan?.share(at: index + 1) {
                    Text(VND.format(share))
                        .font(.subheadline)
                        .monospacedDigit()
                        .foregroundStyle(.secondary)
                }
                Button {
                    friends.removeAll { $0.id == friend.wrappedValue.id }
                } label: {
                    Image(systemName: "minus.circle.fill")
                }
                .buttonStyle(.plain)
                .foregroundStyle(.secondary)
                .accessibilityLabel("Bỏ người \(index + 1)")
            }
            if friend.wrappedValue.account == nil {
                TextField("Tên người chia", text: friend.name)
                    .accessibilityIdentifier("billSplit.friendName.\(index)")
            }
        }
        .padding(.vertical, 2)
    }

    // MARK: - Preview

    private var previewSection: some View {
        Section("Xem trước") {
            LabeledContent("Tổng hoá đơn") {
                Text(VND.format(billTotal)).monospacedDigit()
            }
            if let plan {
                LabeledContent("Phần của tôi") {
                    Text(VND.format(plan.ownShare))
                        .monospacedDigit()
                        .foregroundStyle(AppTheme.expense)
                }
                LabeledContent("Tổng phải thu") {
                    Text(VND.format(plan.total - plan.ownShare))
                        .monospacedDigit()
                }
                if plan.remainder > 0 {
                    Text("Lẻ \(VND.format(plan.remainder)) — chia một đồng một người từ Tôi trở đi.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
        }
    }

    // MARK: - Save

    private var failurePresented: Binding<Bool> {
        Binding(
            get: { failure != nil },
            set: { if !$0 { failure = nil } }
        )
    }

    /// One commit through `BillSplitService`; the sheet stays open on
    /// failure with the message shown, and a second tap while a save is
    /// in flight is ignored.
    private func save() {
        guard canSave else { return }
        saving = true
        let service = BillSplitService()
        do {
            if let transaction, let expected {
                _ = try service.splitExistingExpense(
                    transaction, expected: expected, category: category,
                    participants: participants, in: context)
            } else {
                guard let payer else { throw BillSplitError.invalidPayer }
                _ = try service.splitNewBill(
                    total: billTotal, payer: payer, date: date,
                    category: category, note: note,
                    participants: participants, in: context)
            }
            onSaved()
        } catch let error as BillSplitError {
            failure = error
            saving = false
        } catch {
            failure = .saveFailed(error)
            saving = false
        }
    }
}

#Preview("Chia bill mới") {
    let container = try! AppModelContainer.make(inMemory: true)
    let context = ModelContext(container)
    try! SeedData.seedIfNeeded(context: context)
    let cash = try! context.fetch(FetchDescriptor<Account>()).first!
    return BillSplitView(
        seed: BillSplitSeed(
            total: 1_200_000, payer: cash, date: .now,
            category: nil, note: "Ăn trưa nhóm"),
        onSaved: {})
        .modelContainer(container)
}

#Preview("Chia giao dịch đã lưu") {
    let container = try! AppModelContainer.make(inMemory: true)
    let context = ModelContext(container)
    try! SeedData.seedIfNeeded(context: context)
    let cash = try! context.fetch(FetchDescriptor<Account>()).first!
    let transaction = LedgerTransaction(
        kind: .expense, amount: 1_200_000,
        note: "GRAB FOOD", account: cash, needsReview: true)
    context.insert(transaction)
    return BillSplitView(
        transaction: transaction,
        expected: BillSplitOriginal(of: transaction),
        editorHasPendingEdits: false,
        onSaved: {})
        .modelContainer(container)
}
