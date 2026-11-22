import SwiftUI
import SwiftData

/// "Thay đổi lãi suất" — adds one `LoanRateChange`: a new annual rate that
/// applies from a chosen installment to the end of the schedule, the way a
/// promo rate flips to a floating rate. Installment 1 keeps the base rate,
/// so the range is 2...term.
struct LoanRateChangeSheet: View {
    let account: Account

    @Environment(\.modelContext) private var context
    @Environment(\.dismiss) private var dismiss

    @State private var fromInstallment: Int
    @State private var ratePercent = 0.0

    init(account: Account) {
        self.account = account
        _fromInstallment = State(initialValue: min(2, max(2, account.loanTermMonths ?? 2)))
    }

    private var termMonths: Int { account.loanTermMonths ?? 0 }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Stepper(
                        "Từ kỳ: \(fromInstallment)",
                        value: $fromInstallment,
                        in: 2...max(2, termMonths)
                    )
                    TextField("Lãi suất mới (%/năm)", value: $ratePercent, format: .number)
                        .keyboardType(.decimalPad)
                } footer: {
                    if let validationError, shouldShowError {
                        Text(validationError.errorDescription ?? "")
                            .foregroundStyle(AppTheme.expense)
                    } else {
                        Text("Lãi suất mới áp dụng cho các kỳ từ \(fromInstallment) trở đi.")
                    }
                }
            }
            .navigationTitle("Thay đổi lãi suất")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Huỷ") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Lưu") { save() }
                        .disabled(validationError != nil)
                }
            }
        }
    }

    private var validationError: LoanRateChangeError? {
        LoanPlan.validateRateChange(
            fromInstallment: fromInstallment,
            annualRatePercent: ratePercent,
            termMonths: termMonths,
            existingInstallments: Set((account.loanRateChanges ?? []).map(\.fromInstallment))
        )
    }

    /// An untouched rate field shows the hint, not an error.
    private var shouldShowError: Bool {
        validationError != .invalidRate || ratePercent != 0
    }

    private func save() {
        context.insert(LoanRateChange(
            fromInstallment: fromInstallment,
            annualRatePercent: ratePercent,
            account: account
        ))
        try? context.save()
        dismiss()
    }
}

#Preview {
    let container = try! AppModelContainer.make(inMemory: true)
    let context = ModelContext(container)
    try! SeedData.seedIfNeeded(context: context)
    let loan = Account(name: "Vay mua nhà", kind: .loan, openingBalance: -400_000_000)
    loan.loanTermMonths = 60
    context.insert(loan)
    return LoanRateChangeSheet(account: loan)
        .modelContainer(container)
}
