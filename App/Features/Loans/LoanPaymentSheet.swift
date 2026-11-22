import SwiftUI
import SwiftData
import FinanceCore

/// "Ghi nhận trả nợ" — records one scheduled installment as two ledger rows:
/// a transfer into the loan for the principal and an expense for the
/// interest. Both amounts are prefilled from the plan and editable. Owns its
/// NavigationStack and dismisses on save or cancel.
struct LoanPaymentSheet: View {
    let account: Account

    @Environment(\.modelContext) private var context
    @Environment(\.dismiss) private var dismiss
    @Query(sort: \LedgerCategory.sortOrder) private var categories: [LedgerCategory]

    @State private var draft: LoanPaymentDraft
    @State private var part = LoanPaymentDraft.Part.principal
    @State private var saveFailed = false

    init(account: Account, plan: LoanPlan?) {
        self.account = account
        _draft = State(initialValue: LoanPaymentDraft(plan: plan))
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Picker("Phần tiền", selection: $part) {
                        ForEach(LoanPaymentDraft.Part.allCases, id: \.self) { choice in
                            Text(choice.displayName).tag(choice)
                        }
                    }
                    .pickerStyle(.segmented)
                    AmountKeypad(amount: amountBinding)
                    LabeledContent("Gốc", value: VND.format(draft.principal))
                    LabeledContent("Lãi", value: VND.format(draft.interest))
                    LabeledContent("Tổng trả", value: VND.format(draft.total))
                } header: {
                    Text("Kỳ \(draft.installmentIndex) · \(account.name)")
                }

                Section {
                    LoanPayingAccountPicker(selection: $draft.payingAccount)
                    DatePicker(
                        "Ngày trả",
                        selection: $draft.date,
                        displayedComponents: .date
                    )
                    .environment(\.calendar, AppCalendar.vietnam)
                }
            }
            .navigationTitle("Ghi nhận trả nợ")
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
                Text("Chưa chọn tài khoản trả hoặc số tiền không hợp lệ.")
            }
        }
    }

    /// The keypad edits whichever part the segmented control selects.
    private var amountBinding: Binding<Int64> {
        Binding(
            get: { part == .principal ? draft.principal : draft.interest },
            set: {
                if part == .principal { draft.principal = $0 }
                else { draft.interest = $0 }
            }
        )
    }

    /// The seeded "Lãi vay & phí" category, looked up by name — nil when the
    /// user deleted it.
    private var interestCategory: LedgerCategory? {
        categories.first { $0.name == LoanPaymentDraft.interestCategoryName }
    }

    private func save() {
        guard draft.insert(into: context, loan: account, interestCategory: interestCategory) else {
            saveFailed = true
            return
        }
        do {
            try context.save()
            dismiss()
        } catch {
            saveFailed = true
        }
    }
}

/// Picker of the asset accounts a loan payment can leave from — non-archived
/// and not a liability — each shown with its compact balance. Shared by the
/// payment and prepayment sheets.
struct LoanPayingAccountPicker: View {
    @Query(sort: \Account.sortOrder) private var accounts: [Account]
    @Binding var selection: Account?

    var body: some View {
        Picker(selection: $selection) {
            ForEach(candidates, id: \.id) { candidate in
                Label {
                    HStack {
                        Text(candidate.name)
                        Spacer(minLength: 8)
                        AmountText(amount: candidate.balance, compact: true)
                            .font(.subheadline)
                    }
                } icon: {
                    IconBadge(symbol: candidate.icon, colorHex: candidate.colorHex, size: 28)
                }
                .tag(candidate as Account?)
            }
        } label: {
            Text("Trả từ tài khoản")
        }
        .pickerStyle(.navigationLink)
        .onAppear(perform: selectDefault)
        .onChange(of: accounts.count) { _, _ in selectDefault() }
    }

    /// Non-archived asset accounts — cash, bank and e-wallet, never the
    /// loan itself or a credit card.
    private var candidates: [Account] {
        accounts.filter { !$0.isArchived && !$0.kind.isLiability }
    }

    /// Preselect the first candidate when nothing is chosen, and repair the
    /// selection if the account disappeared.
    private func selectDefault() {
        if let current = selection,
           candidates.contains(where: { $0.id == current.id }) {
            return
        }
        selection = candidates.first
    }
}

#Preview {
    let container = try! AppModelContainer.make(inMemory: true)
    let context = ModelContext(container)
    try! SeedData.seedIfNeeded(context: context)
    let bank = Account(name: "Ngân hàng", kind: .bank, openingBalance: 180_000_000)
    let loan = Account(
        name: "Vay mua nhà", kind: .loan,
        openingBalance: -90_000_000, colorHex: "BF5AF2"
    )
    loan.loanPrincipal = 120_000_000
    loan.loanAnnualRatePercent = 12
    loan.loanTermMonths = 12
    loan.loanStartDate = AppCalendar.vietnam.date(byAdding: .month, value: -4, to: .now) ?? .now
    loan.loanPaymentDay = 15
    loan.loanMethodRaw = LoanMethod.equalPrincipal.rawValue
    context.insert(bank)
    context.insert(loan)
    let plan = LoanPlan(account: loan, basis: .monthly, calendar: AppCalendar.vietnam)
    return LoanPaymentSheet(account: loan, plan: plan)
        .modelContainer(container)
}
