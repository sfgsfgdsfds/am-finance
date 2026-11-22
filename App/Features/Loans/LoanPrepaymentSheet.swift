import SwiftUI
import SwiftData
import FinanceCore

/// "Trả gốc trước hạn" — an extra principal repayment recorded as a single
/// transfer into the loan account. The schedule needs no bookkeeping: the
/// plan re-infers progress from the smaller remaining debt.
struct LoanPrepaymentSheet: View {
    let account: Account

    @Environment(\.modelContext) private var context
    @Environment(\.dismiss) private var dismiss

    @State private var draft = LoanPrepaymentDraft()
    @State private var saveFailed = false

    init(account: Account) {
        self.account = account
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    AmountKeypad(amount: $draft.amount)
                } header: {
                    Text("Số tiền gốc trả trước")
                } footer: {
                    Text(
                        "Dư nợ còn lại \(VND.format(max(0, -LedgerBalanceStores.shared(for: context.container).balance(of: account)))). "
                        + "Lịch trả nợ sẽ tự điều chỉnh theo số tiền đã trả."
                    )
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
            .navigationTitle("Trả gốc trước hạn")
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

    private func save() {
        guard draft.insert(into: context, loan: account) else {
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

#Preview {
    let container = try! AppModelContainer.make(inMemory: true)
    let context = ModelContext(container)
    try! SeedData.seedIfNeeded(context: context)
    let bank = Account(name: "Ngân hàng", kind: .bank, openingBalance: 180_000_000)
    let loan = Account(name: "Vay mua nhà", kind: .loan, openingBalance: -90_000_000)
    context.insert(bank)
    context.insert(loan)
    return LoanPrepaymentSheet(account: loan)
        .modelContainer(container)
}
