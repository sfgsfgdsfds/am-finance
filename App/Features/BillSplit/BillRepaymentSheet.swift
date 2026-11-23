import SwiftUI
import SwiftData
import FinanceCore

/// "Ghi nhận hoàn tiền" — reclassifies an already-recorded personal
/// income (typically a synced bank row) as a receivable repayment
/// **in place** through `BillSplitService.assignRepayment`. The row
/// keeps its id and external provenance and becomes a
/// `receivable -> original receiver` transfer; no secondary income or
/// transfer is ever created. Only active personal receivables whose
/// remaining outstanding can absorb the full amount are offered — the
/// flow never creates prepaid credit. A successful save dismisses the
/// sheet and the editor through `onSaved`; cancelling changes nothing.
struct BillRepaymentSheet: View {
    private let transaction: LedgerTransaction
    /// Snapshot taken when the sheet opened — re-checked by the service.
    private let expected: BillSplitOriginal
    /// The editor holds unsaved edits — disclosed since they are not
    /// part of the conversion.
    private let editorHasPendingEdits: Bool
    private let onSaved: () -> Void

    @Environment(\.modelContext) private var context
    @Environment(\.dismiss) private var dismiss
    @Query(sort: \Account.sortOrder) private var accounts: [Account]

    @State private var selected: Account?
    @State private var saving = false
    @State private var failure: BillSplitError?

    init(
        transaction: LedgerTransaction,
        expected: BillSplitOriginal,
        editorHasPendingEdits: Bool = false,
        onSaved: @escaping () -> Void
    ) {
        self.transaction = transaction
        self.expected = expected
        self.editorHasPendingEdits = editorHasPendingEdits
        self.onSaved = onSaved
    }

    private var ledger: LedgerBalanceStore {
        LedgerBalanceStores.shared(for: context.container)
    }

    /// Active personal receivables that can absorb the whole amount —
    /// read through the shared ledger store, never relationship walks.
    private var eligibleReceivables: [Account] {
        accounts.filter {
            $0.kind == .receivable && $0.business == nil
                && !$0.isArchived && $0.id != transaction.account?.id
                && ledger.receivableSnapshot(of: $0).outstanding
                    >= expected.amount
        }
    }

    private var canSave: Bool { selected != nil && !saving }

    var body: some View {
        NavigationStack {
            form
                .background(Color(.systemGroupedBackground))
                .navigationTitle("Ghi nhận hoàn tiền")
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) {
                        Button("Huỷ") { dismiss() }
                    }
                    ToolbarItem(placement: .confirmationAction) {
                        Button("Xác nhận hoàn tiền") { save() }
                            .disabled(!canSave)
                    }
                }
                .alert(
                    "Không thể ghi nhận",
                    isPresented: failurePresented
                ) {
                    Button("Đóng", role: .cancel) {}
                } message: {
                    Text(failure?.errorDescription ?? "")
                }
        }
    }

    private var form: some View {
        Form {
            Section {
                LabeledContent("Số tiền") {
                    Text(VND.format(expected.amount)).monospacedDigit()
                }
                LabeledContent("Nhận vào") {
                    Text(transaction.account?.name ?? "—")
                }
                LabeledContent("Ngày") {
                    Text("\(AppDateFormat.shortDate(expected.date)) \(AppDateFormat.time(expected.date))")
                }
                if !expected.note.isEmpty {
                    LabeledContent("Ghi chú") {
                        Text(expected.note).lineLimit(1)
                    }
                }
            } header: {
                Text("Khoản thu đang được ghi nhận")
            } footer: {
                Text(disclosure)
            }

            Section {
                if eligibleReceivables.isEmpty {
                    Text("Không có khoản phải thu cá nhân nào đủ dư để ghi nhận \(VND.format(expected.amount)).")
                        .foregroundStyle(.secondary)
                } else {
                    ForEach(eligibleReceivables, id: \.id) { receivable in
                        receivableRow(receivable)
                    }
                }
            } header: {
                Text("Ghi vào phải thu của")
            }
        }
    }

    private var disclosure: String {
        var text = "Giao dịch này sẽ đổi thành khoản chuyển từ phải thu về tài khoản nhận — không tạo giao dịch mới."
        if editorHasPendingEdits {
            text += " Các thay đổi chưa lưu trong form sửa sẽ không được áp dụng."
        }
        return text
    }

    private func receivableRow(_ receivable: Account) -> some View {
        let isSelected = selected?.id == receivable.id
        return HStack {
            IconBadge(
                symbol: receivable.icon,
                colorHex: receivable.colorHex, size: 28)
            VStack(alignment: .leading, spacing: 2) {
                Text(receivable.name)
                Text("Đang nợ \(VND.format(ledger.receivableSnapshot(of: receivable).outstanding))")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            if isSelected {
                Image(systemName: "checkmark.circle.fill")
                    .foregroundStyle(Color.accentColor)
            }
        }
        .contentShape(Rectangle())
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("billRepay.receivable.\(receivable.name)")
        .onTapGesture { selected = receivable }
    }

    private var failurePresented: Binding<Bool> {
        Binding(
            get: { failure != nil },
            set: { if !$0 { failure = nil } }
        )
    }

    /// One conversion through `BillSplitService`; the sheet stays open
    /// on failure with the message shown, and a second tap while a save
    /// is in flight is ignored.
    private func save() {
        guard canSave, let receivable = selected else { return }
        saving = true
        do {
            _ = try BillSplitService().assignRepayment(
                transaction, expected: expected,
                to: receivable, in: context)
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

#Preview {
    let container = try! AppModelContainer.make(inMemory: true)
    let context = ModelContext(container)
    try! SeedData.seedIfNeeded(context: context)
    let cash = try! context.fetch(FetchDescriptor<Account>()).first!
    let client = Account(name: "An", kind: .receivable)
    context.insert(client)
    context.insert(ReceivableActions.advance(
        receivable: client, from: cash,
        amount: 900_000, date: .now, note: "Ăn trưa nhóm"))
    let income = LedgerTransaction(
        kind: .income, amount: 300_000,
        note: "MB BANK CHUYEN TIEN", account: cash)
    context.insert(income)
    try! context.save()
    return BillRepaymentSheet(
        transaction: income,
        expected: BillSplitOriginal(of: income),
        onSaved: {})
        .modelContainer(container)
}
