import SwiftUI
import SwiftData
import FinanceCore

/// One keypad sheet behind each receivable action: đồng entry, a
/// counterparty account picker where the action needs one, date and note.
/// Saving inserts exactly one row through `ReceivableActions`; a write-off
/// asks for confirmation first and is capped at the outstanding amount.
struct ReceivableActionSheet: View {
    let account: Account
    let kind: ReceivableSheetKind

    @Environment(\.modelContext) private var context
    @Environment(\.dismiss) private var dismiss
    @Query(sort: \Account.sortOrder) private var accounts: [Account]
    @Query(sort: \LedgerCategory.sortOrder) private var categories: [LedgerCategory]

    @State private var amount: Int64
    @State private var counterparty: Account?
    @State private var date: Date
    @State private var note: String
    @State private var confirmsWriteOff = false

    init(account: Account, kind: ReceivableSheetKind) {
        self.account = account
        self.kind = kind
        // The repayment sheet starts at "everything the client still owes".
        _amount = State(initialValue: kind == .repayment
            ? ReceivableSnapshot.make(account: account).outstanding
            : 0)
        _date = State(initialValue: .now)
        _note = State(initialValue: kind.defaultNote(clientName: account.name))
    }

    private static func outstanding(of account: Account) -> Int64 {
        ReceivableSnapshot.make(account: account).outstanding
    }

    private var outstanding: Int64 { Self.outstanding(of: account) }

    /// Accounts the counterparty may be: advance payers (cash, bank,
    /// eWallet, credit card) or receivers (cash, bank, eWallet).
    private var counterparties: [Account] {
        switch kind {
        case .advance:
            return ReceivableActions.advancePayers(accounts, for: account)
        case .repayment, .serviceFee:
            return ReceivableActions.receivers(accounts, for: account)
        case .writeOff:
            return []
        }
    }

    private var canSave: Bool {
        guard amount > 0 else { return false }
        switch kind {
        case .writeOff:
            return amount <= outstanding
        case .advance, .repayment, .serviceFee:
            return counterparty != nil
        }
    }

    /// Overpaying a repayment is allowed — the excess becomes prepaid
    /// credit ("khách ứng trước"), so the sheet says so up front.
    private var overpaymentHint: Bool {
        kind == .repayment && amount > outstanding
    }

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                VStack(spacing: 8) {
                    quickChips
                    AmountKeypad(amount: $amount)
                    if overpaymentHint {
                        Text("Khách trả dư \(VND.format(amount - outstanding)), sẽ ghi là tiền khách ứng trước")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .multilineTextAlignment(.center)
                    }
                }
                .padding(.horizontal)
                .padding(.top, 8)
                .padding(.bottom, 12)

                Form {
                    Section {
                        if let label = kind.counterpartyLabel {
                            if counterparties.isEmpty {
                                Text(emptyCounterpartyHint)
                                    .foregroundStyle(.secondary)
                            } else {
                                counterpartyPicker(label: label)
                            }
                        }
                        DatePicker(
                            "Ngày",
                            selection: $date,
                            displayedComponents: .date
                        )
                        .environment(\.calendar, AppCalendar.vietnam)
                        TextField("Ghi chú", text: $note)
                    }
                }
            }
            .background(Color(.systemGroupedBackground))
            .navigationTitle(kind.title)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Huỷ") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Lưu") { confirm() }
                        .disabled(!canSave)
                }
            }
            .onAppear {
                if counterparty == nil { counterparty = counterparties.first }
            }
            .alert(
                "Xoá nợ",
                isPresented: $confirmsWriteOff
            ) {
                Button("Xoá nợ", role: .destructive) { save() }
                Button("Huỷ", role: .cancel) {}
            } message: {
                Text("Xoá \(VND.format(amount)) khỏi khoản phải thu của \"\(account.name)\"? Số tiền này trở thành chi phí của bạn.")
            }
        }
    }

    // MARK: - Quick chips

    @ViewBuilder
    private var quickChips: some View {
        if outstanding > 0 && (kind == .repayment || kind == .writeOff) {
            HStack(spacing: 8) {
                Button {
                    amount = outstanding
                } label: {
                    VStack(spacing: 1) {
                        Text("Toàn bộ")
                            .font(.caption2)
                        Text(VND.compact(outstanding))
                            .font(.caption.weight(.semibold))
                            .monospacedDigit()
                    }
                    .foregroundStyle(amount == outstanding ? .white : .primary)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 6)
                    .padding(.horizontal, 4)
                    .background(
                        amount == outstanding ? Color.accentColor : Color(.secondarySystemFill),
                        in: RoundedRectangle(cornerRadius: 10)
                    )
                }
                .buttonStyle(.plain)
                .accessibilityAddTraits(amount == outstanding ? .isSelected : [])
            }
        }
    }

    // MARK: - Counterparty

    private var emptyCounterpartyHint: String {
        switch kind {
        case .advance:
            return "Chưa có tài khoản để trả — hãy tạo tiền mặt, ngân hàng, ví điện tử hoặc thẻ tín dụng trước."
        case .repayment, .serviceFee:
            return "Chưa có tài khoản để nhận — hãy tạo tiền mặt, ngân hàng hoặc ví điện tử trước."
        case .writeOff:
            return ""
        }
    }

    private func counterpartyPicker(label: String) -> some View {
        Picker(selection: $counterparty) {
            ForEach(counterparties, id: \.id) { option in
                Label {
                    HStack {
                        Text(option.name)
                        Spacer(minLength: 8)
                        AmountText(amount: option.balance, compact: true)
                            .font(.subheadline)
                    }
                } icon: {
                    IconBadge(symbol: option.icon, colorHex: option.colorHex, size: 28)
                }
                .tag(option as Account?)
            }
        } label: {
            Text(label)
        }
        .pickerStyle(.navigationLink)
    }

    // MARK: - Save

    /// Write-off goes through a confirmation alert; the rest insert directly.
    private func confirm() {
        guard canSave else { return }
        if kind == .writeOff {
            confirmsWriteOff = true
        } else {
            save()
        }
    }

    private func save() {
        let trimmedNote = note.trimmingCharacters(in: .whitespacesAndNewlines)
        let transaction: LedgerTransaction?
        switch kind {
        case .advance:
            transaction = counterparty.map {
                ReceivableActions.advance(
                    receivable: account, from: $0,
                    amount: amount, date: date, note: trimmedNote)
            }
        case .repayment:
            transaction = counterparty.map {
                ReceivableActions.repayment(
                    receivable: account, to: $0,
                    amount: amount, date: date, note: trimmedNote)
            }
        case .serviceFee:
            transaction = counterparty.map {
                ReceivableActions.serviceFee(
                    receivable: account, to: $0,
                    amount: amount, date: date, note: trimmedNote,
                    category: ReceivableActions.category(
                        named: ReceivableActions.serviceFeeCategoryName,
                        kind: .income, in: categories))
            }
        case .writeOff:
            transaction = ReceivableActions.writeOff(
                receivable: account,
                amount: amount, date: date, note: trimmedNote,
                category: ReceivableActions.category(
                    named: ReceivableActions.writeOffCategoryName,
                    kind: .expense, in: categories))
        }
        if let transaction {
            context.insert(transaction)
            try? context.save()
        }
        dismiss()
    }
}

#Preview("Ứng tiền") {
    let container = try! AppModelContainer.make(inMemory: true)
    let context = ModelContext(container)
    try! SeedData.seedIfNeeded(context: context)
    let client = Account(name: "Khách A", kind: .receivable, colorHex: "0A84FF")
    let card = Account(name: "Thẻ Visa", kind: .creditCard, colorHex: "FF9500")
    context.insert(client)
    context.insert(card)
    return ReceivableActionSheet(account: client, kind: .advance)
        .modelContainer(container)
}

#Preview("Xoá nợ") {
    let container = try! AppModelContainer.make(inMemory: true)
    let context = ModelContext(container)
    try! SeedData.seedIfNeeded(context: context)
    let cash = try! context.fetch(FetchDescriptor<Account>()).first!
    let client = Account(name: "Khách A", kind: .receivable, colorHex: "0A84FF")
    context.insert(client)
    context.insert(LedgerTransaction(
        kind: .transfer, amount: 2_000_000, account: cash, toAccount: client))
    return ReceivableActionSheet(account: client, kind: .writeOff)
        .modelContainer(container)
}
