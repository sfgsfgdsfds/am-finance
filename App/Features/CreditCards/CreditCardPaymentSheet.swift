import SwiftUI
import SwiftData
import FinanceCore

/// "Trả nợ thẻ" sheet: a `CreditCardPaymentPlan`-pre-filled đồng keypad with
/// quick chips (statement balance, minimum, all debt), a payer picker limited
/// to `CreditCardPayment.eligiblePayers`, and a date. Saving inserts one
/// transfer `LedgerTransaction` — a card payment is never an expense.
struct CreditCardPaymentSheet: View {
    let card: Account
    let plan: CreditCardPaymentPlan

    @Environment(\.modelContext) private var context
    @Environment(\.dismiss) private var dismiss
    @Query(sort: \Account.sortOrder) private var accounts: [Account]

    @State private var amount: Int64
    @State private var payer: Account?
    @State private var date: Date

    init(card: Account, plan: CreditCardPaymentPlan) {
        self.card = card
        self.plan = plan
        _amount = State(initialValue: plan.prefill)
        _date = State(initialValue: .now)
    }

    private var payers: [Account] {
        CreditCardPayment.eligiblePayers(accounts, paying: card)
    }

    private var note: String { "Trả nợ thẻ \(card.name)" }

    private var canSave: Bool { amount > 0 && payer != nil }

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                VStack(spacing: 8) {
                    quickChips
                    AmountKeypad(amount: $amount)
                }
                .padding(.horizontal)
                .padding(.top, 8)
                .padding(.bottom, 12)

                Form {
                    Section {
                        if payers.isEmpty {
                            Text("Chưa có tài khoản để trả — hãy tạo một tài khoản tiền mặt, ngân hàng hoặc ví điện tử trước.")
                                .foregroundStyle(.secondary)
                        } else {
                            payerPicker
                        }
                        DatePicker(
                            "Ngày trả",
                            selection: $date,
                            displayedComponents: .date
                        )
                        .environment(\.calendar, AppCalendar.vietnam)
                        LabeledContent("Ghi chú", value: note)
                    }
                }
            }
            .background(Color(.systemGroupedBackground))
            .navigationTitle("Trả nợ thẻ")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Huỷ") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Lưu") { save() }
                        .disabled(!canSave)
                }
            }
            .onAppear {
                if payer == nil { payer = payers.first }
            }
        }
    }

    // MARK: - Quick chips

    private var quickChips: some View {
        HStack(spacing: 8) {
            chip("Dư nợ sao kê", value: plan.statementBalance)
            chip("Tối thiểu", value: plan.minimumPayment)
            chip("Toàn bộ dư nợ", value: plan.totalDebt)
        }
    }

    @ViewBuilder
    private func chip(_ title: String, value: Int64?) -> some View {
        if let value, value > 0 {
            Button {
                amount = value
            } label: {
                VStack(spacing: 1) {
                    Text(title)
                        .font(.caption2)
                    Text(VND.compact(value))
                        .font(.caption.weight(.semibold))
                        .monospacedDigit()
                }
                .foregroundStyle(amount == value ? .white : .primary)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 6)
                .padding(.horizontal, 4)
                .background(
                    amount == value ? Color.accentColor : Color(.secondarySystemFill),
                    in: RoundedRectangle(cornerRadius: 10)
                )
            }
            .buttonStyle(.plain)
            .accessibilityAddTraits(amount == value ? .isSelected : [])
        }
    }

    // MARK: - Payer

    private var payerPicker: some View {
        Picker(selection: $payer) {
            ForEach(payers, id: \.id) { account in
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
            Text("Trả từ")
        }
        .pickerStyle(.navigationLink)
    }

    // MARK: - Save

    private func save() {
        guard let payer, amount > 0 else { return }
        context.insert(CreditCardPayment.makeTransfer(
            card: card, from: payer, amount: amount, date: date
        ))
        try? context.save()
        dismiss()
    }
}

#Preview {
    let container = try! AppModelContainer.make(inMemory: true)
    let context = ModelContext(container)
    try! SeedData.seedIfNeeded(context: context)
    let bank = Account(
        name: "Techcombank", kind: .bank,
        openingBalance: 25_000_000, colorHex: "0A84FF", sortOrder: 1
    )
    let card = Account(name: "Thẻ Visa", kind: .creditCard, colorHex: "FF9500", sortOrder: 2)
    card.creditLimit = 30_000_000
    card.statementDay = 20
    card.graceDays = 15
    context.insert(bank)
    context.insert(card)
    let plan = CreditCardPaymentPlan(
        statementBalance: 3_250_000,
        statementDue: 2_250_000,
        minimumPayment: 112_500,
        totalDebt: 2_600_000
    )
    return CreditCardPaymentSheet(card: card, plan: plan)
        .modelContainer(container)
}
