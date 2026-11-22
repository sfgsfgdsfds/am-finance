import SwiftUI
import SwiftData
import FinanceCore

/// Create/edit form for one account, presented as a sheet with its own
/// NavigationStack. `account == nil` creates a new account — the kind picker
/// is only shown in that mode.
struct AccountEditView: View {
    private let account: Account?

    @Environment(\.modelContext) private var context
    @Environment(\.dismiss) private var dismiss
    @Query(sort: \Account.sortOrder) private var existingAccounts: [Account]

    @State private var draft: AccountDraft
    @State private var error: AccountDraftError?

    init(account: Account? = nil) {
        self.account = account
        _draft = State(initialValue: account.map { AccountDraft(account: $0) } ?? AccountDraft())
    }

    var body: some View {
        NavigationStack {
            Form {
                infoSection
                balanceSection
                if draft.kind == .creditCard { creditCardSection }
                if draft.kind == .loan { loanSection }
                appearanceSection
                noteSection
            }
            .navigationTitle(account == nil ? "Tài khoản mới" : "Sửa tài khoản")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Huỷ") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Lưu") { save() }
                }
            }
            .alert(
                "Không thể lưu",
                isPresented: errorAlertPresented,
                presenting: error
            ) { _ in
                Button("OK", role: .cancel) {}
            } message: { draftError in
                Text(draftError.errorDescription ?? "")
            }
        }
    }

    private var errorAlertPresented: Binding<Bool> {
        Binding(
            get: { error != nil },
            set: { if !$0 { error = nil } }
        )
    }

    // MARK: - Sections

    private var infoSection: some View {
        Section("Thông tin") {
            TextField("Tên tài khoản", text: $draft.name)
            if account == nil {
                Picker("Loại tài khoản", selection: $draft.kind) {
                    ForEach(AccountKind.allCases, id: \.self) { kind in
                        Text(kind.displayName).tag(kind)
                    }
                }
            } else {
                LabeledContent("Loại tài khoản", value: draft.kind.displayName)
            }
        }
        .onChange(of: draft.kind) { oldKind, newKind in
            // Keep a default icon in sync with the kind; never clobber a
            // symbol the user picked themselves.
            if draft.icon.isEmpty || draft.icon == oldKind.defaultSymbol {
                draft.icon = newKind.defaultSymbol
            }
        }
    }

    private var balanceSection: some View {
        Section {
            AmountKeypad(amount: $draft.openingBalance)
        } header: {
            Text(draft.kind.isLiability ? "Dư nợ hiện tại" : "Số dư ban đầu")
        } footer: {
            if draft.kind.isLiability {
                Text("Nhập số tiền bạn đang nợ trên \(draft.kind == .creditCard ? "thẻ" : "khoản vay") này.")
            }
        }
    }

    private var creditCardSection: some View {
        Section("Thẻ tín dụng") {
            TextField("Hạn mức", value: $draft.creditLimit, format: .number)
                .keyboardType(.numberPad)
            Stepper("Ngày chốt sao kê: \(draft.statementDay)", value: $draft.statementDay, in: 1...31)
            Stepper("Số ngày ân hạn: \(draft.graceDays)", value: $draft.graceDays, in: 0...90)
            LabeledContent("Sao kê tiếp theo", value: nextStatementText)
            LabeledContent("Hạn thanh toán", value: nextDueText)
        }
    }

    private var loanSection: some View {
        Section("Khoản vay") {
            TextField("Số tiền vay gốc", value: $draft.loanPrincipal, format: .number)
                .keyboardType(.numberPad)
            TextField("Lãi suất (%/năm)", value: $draft.loanAnnualRatePercent, format: .number)
                .keyboardType(.decimalPad)
            TextField("Kỳ hạn (tháng)", value: $draft.loanTermMonths, format: .number)
                .keyboardType(.numberPad)
            DatePicker(
                "Ngày giải ngân",
                selection: $draft.loanStartDate,
                displayedComponents: .date
            )
            .environment(\.calendar, AppCalendar.vietnam)
            Stepper("Ngày trả hằng tháng: \(draft.loanPaymentDay)", value: $draft.loanPaymentDay, in: 1...31)
            Picker("Phương thức", selection: $draft.loanMethod) {
                ForEach(LoanMethod.allCases, id: \.self) { method in
                    Text(method.displayName).tag(method)
                }
            }
        }
    }

    private var appearanceSection: some View {
        Group {
            Section("Biểu tượng") {
                IconPickerGrid(selection: $draft.icon)
            }
            Section("Màu sắc") {
                ColorHexPickerGrid(selection: $draft.colorHex)
            }
        }
    }

    private var noteSection: some View {
        Section("Ghi chú") {
            TextField("Ghi chú", text: $draft.note, axis: .vertical)
                .lineLimit(3...)
        }
    }

    // MARK: - Credit-card date previews

    private var nextStatementText: String {
        let config = draft.creditCardCycleConfig
        return AccountDateFormat.full(
            config.nextClosingDate(onOrAfter: .now, calendar: AppCalendar.vietnam)
        )
    }

    private var nextDueText: String {
        let config = draft.creditCardCycleConfig
        return AccountDateFormat.full(
            config.nextDueDate(onOrAfter: .now, calendar: AppCalendar.vietnam)
        )
    }

    // MARK: - Save

    private func save() {
        if let validationError = draft.validate() {
            error = validationError
            return
        }
        if let account {
            draft.apply(to: account)
        } else {
            let newAccount = Account(name: draft.name, kind: draft.kind)
            draft.apply(to: newAccount)
            newAccount.sortOrder = (existingAccounts.last?.sortOrder ?? -1) + 1
            context.insert(newAccount)
        }
        dismiss()
    }
}

#Preview("Tạo mới") {
    let container = try! AppModelContainer.make(inMemory: true)
    try! SeedData.seedIfNeeded(context: ModelContext(container))
    return AccountEditView()
        .modelContainer(container)
}

#Preview("Sửa thẻ tín dụng") {
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
    return AccountEditView(account: card)
        .modelContainer(container)
}
