import SwiftUI
import SwiftData
import FinanceCore

/// One bank loan: remaining debt and repaid-principal progress, the next
/// installment, the full repayment schedule and the rate-change list.
/// Pushed inside an existing `NavigationStack`; sheets own their own stacks.
struct LoanDetailView: View {
    let account: Account

    @Environment(\.modelContext) private var context
    @State private var basis: LoanInterestBasis
    @State private var showsPayment = false
    @State private var showsPrepayment = false
    @State private var showsRateChange = false
    @State private var showsAccountEdit = false

    private let basisStore = LoanInterestBasisStore()

    init(account: Account) {
        self.account = account
        _basis = State(initialValue: LoanInterestBasisStore().basis(for: account.id))
    }

    var body: some View {
        content
            .navigationTitle(account.name)
            .toolbar {
                ToolbarItem(placement: .primaryAction) {
                    Button("Sửa") { showsAccountEdit = true }
                }
            }
            .sheet(isPresented: $showsAccountEdit) {
                AccountEditView(account: account)
            }
            .sheet(isPresented: $showsPayment) {
                LoanPaymentSheet(account: account, plan: plan)
            }
            .sheet(isPresented: $showsPrepayment) {
                LoanPrepaymentSheet(account: account)
            }
            .sheet(isPresented: $showsRateChange) {
                LoanRateChangeSheet(account: account)
            }
            .onChange(of: basis) { _, newBasis in
                basisStore.set(newBasis, for: account.id)
            }
    }

    /// Recomputed on every body evaluation — cheap for term-sized schedules
    /// and always in sync with the latest ledger balance and rate changes.
    private var plan: LoanPlan? {
        LoanPlan(account: account, basis: basis, calendar: AppCalendar.vietnam)
    }

    @ViewBuilder
    private var content: some View {
        if account.kind != .loan {
            EmptyStateView(
                symbol: "doc.text.fill",
                title: "Không phải khoản vay",
                message: "Màn hình này chỉ dành cho tài khoản khoản vay."
            )
        } else if let plan {
            loanList(plan: plan)
        } else {
            EmptyStateView(
                symbol: "doc.text.fill",
                title: "Chưa đủ thông tin khoản vay",
                message: "Nhập số tiền gốc, lãi suất, kỳ hạn, ngày giải ngân và ngày trả hằng tháng để xem lịch trả nợ.",
                actionTitle: "Bổ sung thông tin",
                action: { showsAccountEdit = true }
            )
        }
    }

    // MARK: - Sections

    private func loanList(plan: LoanPlan) -> some View {
        List {
            Section {
                headerCard(plan: plan)
                    .frame(maxWidth: .infinity)
                    .listRowSeparator(.hidden)
                    .listRowBackground(Color.clear)
                LabeledContent("Gốc vay", value: VND.format(plan.principal))
                LabeledContent("Lãi suất hiện tại", value: rateText(plan.currentAnnualRate))
                LabeledContent("Phương thức", value: plan.schedule.terms.method.displayName)
                if let payoff = plan.payoffDate {
                    LabeledContent("Ngày đáo hạn", value: LoanDateFormat.full(payoff))
                }
            }

            if let next = plan.nextInstallment {
                nextSection(plan: plan, next: next)
            }

            if plan.isFullyRepaid {
                Section {
                    Label("Đã trả hết khoản vay", systemImage: "checkmark.seal.fill")
                        .foregroundStyle(AppTheme.income)
                }
            } else {
                Section {
                    Button { showsPayment = true } label: {
                        Label("Ghi nhận trả nợ", systemImage: "checkmark.circle")
                    }
                    Button { showsPrepayment = true } label: {
                        Label("Trả gốc trước hạn", systemImage: "arrow.down.to.line")
                    }
                }
            }

            rateSection(plan: plan)
            scheduleSection(plan: plan)
        }
        .listStyle(.insetGrouped)
    }

    private func headerCard(plan: LoanPlan) -> some View {
        VStack(spacing: 10) {
            IconBadge(symbol: account.icon, colorHex: account.colorHex, size: 56)
            VStack(spacing: 2) {
                AmountText(amount: -plan.remainingDebt)
                    .font(.title.bold())
                Text("Dư nợ còn lại")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            ProgressView(value: plan.progressFraction)
                .tint(Color.accentColor)
            HStack {
                Text("Gốc đã trả \(VND.compact(plan.principalRepaid))")
                Spacer()
                Text("\(Int((plan.progressFraction * 100).rounded()))%")
            }
            .font(.caption)
            .foregroundStyle(.secondary)
        }
        .accessibilityElement(children: .combine)
    }

    private func nextSection(plan: LoanPlan, next: LoanInstallment) -> some View {
        Section("Kỳ trả tiếp theo") {
            LabeledContent("Kỳ", value: "\(next.index)/\(plan.schedule.installments.count)")
            LabeledContent("Đến hạn", value: LoanDateFormat.full(next.dueDate))
            LabeledContent("Gốc", value: VND.format(next.principal))
            LabeledContent("Lãi", value: VND.format(next.interest))
            LabeledContent("Tổng", value: VND.format(next.total))
            dueHint(plan: plan)
        }
    }

    @ViewBuilder
    private func dueHint(plan: LoanPlan) -> some View {
        let days = plan.daysUntilNextDue(now: .now, calendar: AppCalendar.vietnam)
        if let days, days < 0 {
            Label("Quá hạn \(-days) ngày", systemImage: "exclamationmark.triangle.fill")
                .foregroundStyle(AppTheme.expense)
        } else if days == 0 {
            Label("Đến hạn hôm nay", systemImage: "exclamationmark.circle.fill")
                .foregroundStyle(.orange)
        } else if let days {
            Text("Còn \(days) ngày nữa đến hạn")
                .foregroundStyle(.secondary)
        }
    }

    private func rateSection(plan: LoanPlan) -> some View {
        Section {
            LabeledContent("Lãi suất ban đầu", value: rateText(account.loanAnnualRatePercent ?? 0))
            Picker("Cách tính lãi", selection: $basis) {
                ForEach(LoanInterestBasis.allCases, id: \.self) { choice in
                    Text(choice.displayName).tag(choice)
                }
            }
            ForEach(sortedRateChanges, id: \.id) { change in
                LabeledContent(
                    "Từ kỳ \(change.fromInstallment)",
                    value: rateText(change.annualRatePercent)
                )
            }
            .onDelete(perform: deleteRateChanges)
            if (account.loanTermMonths ?? 0) >= 2 {
                Button { showsRateChange = true } label: {
                    Label("Thêm thay đổi lãi suất", systemImage: "plus")
                }
            }
        } header: {
            Text("Lãi suất")
        }
    }

    private func scheduleSection(plan: LoanPlan) -> some View {
        Section {
            ForEach(plan.schedule.installments, id: \.index) { installment in
                installmentRow(installment, plan: plan)
            }
        } header: {
            Text("Lịch trả nợ")
        } footer: {
            Text(
                "Tổng lãi \(VND.format(plan.schedule.totalInterest)) · "
                + "Tổng trả \(VND.format(plan.schedule.totalPaid))"
            )
        }
    }

    private func installmentRow(_ installment: LoanInstallment, plan: LoanPlan) -> some View {
        let paid = installment.index <= plan.paidInstallmentCount
        let isNext = plan.nextInstallment?.index == installment.index
        return HStack(spacing: 12) {
            Image(systemName: paid ? "checkmark.circle.fill" : "circle")
                .foregroundStyle(paid ? AppTheme.income : Color.secondary.opacity(0.5))
                .frame(width: 22)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text("Kỳ \(installment.index)")
                        .font(.subheadline.weight(isNext ? .semibold : .regular))
                    if isNext {
                        Text("Tiếp theo")
                            .font(.caption2.weight(.medium))
                            .padding(.horizontal, 6)
                            .padding(.vertical, 2)
                            .background(Color.accentColor.opacity(0.15), in: Capsule())
                            .foregroundStyle(Color.accentColor)
                    }
                }
                Text(LoanDateFormat.full(installment.dueDate))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Text(
                    "Gốc \(VND.compact(installment.principal)) · "
                    + "Lãi \(VND.compact(installment.interest))"
                )
                .font(.caption)
                .foregroundStyle(.secondary)
            }
            Spacer()
            VStack(alignment: .trailing, spacing: 2) {
                Text(VND.format(installment.total))
                    .monospacedDigit()
                    .font(.subheadline.weight(isNext ? .semibold : .regular))
                Text("Còn \(VND.compact(installment.remainingBalance))")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.vertical, 2)
        .foregroundStyle(paid ? .secondary : .primary)
        .opacity(paid ? 0.6 : 1)
        .listRowBackground(isNext ? Color.accentColor.opacity(0.08) : nil)
        .accessibilityElement(children: .combine)
    }

    // MARK: - Rate changes

    private var sortedRateChanges: [LoanRateChange] {
        (account.loanRateChanges ?? []).sorted { $0.fromInstallment < $1.fromInstallment }
    }

    private func deleteRateChanges(at offsets: IndexSet) {
        for index in offsets {
            context.delete(sortedRateChanges[index])
        }
        try? context.save()
    }

    private func rateText(_ percent: Double) -> String {
        "\(percent.formatted(.number.precision(.fractionLength(0...2))))%/năm"
    }
}

#Preview("Khoản vay đang trả") {
    let container = try! AppModelContainer.make(inMemory: true)
    let context = ModelContext(container)
    try! SeedData.seedIfNeeded(context: context)
    let bank = Account(name: "Ngân hàng", kind: .bank, openingBalance: 180_000_000)
    let loan = Account(
        name: "Vay mua nhà", kind: .loan,
        openingBalance: -402_000_000, colorHex: "BF5AF2"
    )
    loan.loanPrincipal = 500_000_000
    loan.loanAnnualRatePercent = 8.4
    loan.loanTermMonths = 60
    loan.loanStartDate = AppCalendar.vietnam.date(byAdding: .month, value: -10, to: .now) ?? .now
    loan.loanPaymentDay = 15
    loan.loanMethodRaw = LoanMethod.annuity.rawValue
    context.insert(bank)
    context.insert(loan)
    context.insert(LoanRateChange(fromInstallment: 13, annualRatePercent: 11.5, account: loan))
    return NavigationStack {
        LoanDetailView(account: loan)
    }
    .modelContainer(container)
}

#Preview("Thiếu thông tin") {
    let container = try! AppModelContainer.make(inMemory: true)
    let context = ModelContext(container)
    try! SeedData.seedIfNeeded(context: context)
    let loan = Account(name: "Vay tiêu dùng", kind: .loan, openingBalance: -50_000_000)
    context.insert(loan)
    return NavigationStack {
        LoanDetailView(account: loan)
    }
    .modelContainer(container)
}
