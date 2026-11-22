import SwiftUI
import SwiftData
import FinanceCore

/// Create/edit sheet for one `RentalLease` (nil = a new tenancy on
/// `unit`). Owns its NavigationStack. Rent and deposit amounts open an
/// `AmountKeypad` in place; the deposit is kept as information only —
/// it never posts to the ledger.
struct RentalLeaseEditView: View {
    private let lease: RentalLease?
    private let unit: RentalUnit

    @Environment(\.dismiss) private var dismiss
    @Environment(\.modelContext) private var context

    /// Which amount row the keypad edits; nil hides it.
    private enum AmountPart: String {
        case rent, deposit
    }

    @State private var draft: RentalLeaseDraft
    @State private var editingAmount: AmountPart?
    @State private var deleteConfirmationShown = false
    @State private var error: RentalLeaseDraftError?
    @FocusState private var nameFocused: Bool

    init(unit: RentalUnit, lease: RentalLease? = nil) {
        self.unit = unit
        self.lease = lease
        _draft = State(initialValue: lease.map(RentalLeaseDraft.init) ?? {
            var draft = RentalLeaseDraft()
            draft.monthlyRent = unit.listPrice
            draft.deposit = unit.listPrice
            return draft
        }())
    }

    private var isNew: Bool { lease == nil }
    private var calendar: Calendar { AppCalendar.vietnam }

    var body: some View {
        NavigationStack {
            Form {
                Section("Người thuê") {
                    TextField("Tên người thuê", text: $draft.tenantName)
                        .focused($nameFocused)
                    TextField("Điện thoại", text: $draft.tenantPhone)
                        .keyboardType(.phonePad)
                }

                Section {
                    amountRow("Tiền thuê hằng tháng", part: .rent, amount: draft.monthlyRent)
                    if editingAmount == .rent {
                        AmountKeypad(amount: $draft.monthlyRent)
                    }
                    amountRow("Tiền cọc", part: .deposit, amount: draft.deposit)
                    if editingAmount == .deposit {
                        AmountKeypad(amount: $draft.deposit)
                    }
                    Stepper(
                        "Ngày trả hằng tháng: \(draft.paymentDay)",
                        value: $draft.paymentDay, in: 1...31
                    )
                } header: {
                    Text("Tiền & kỳ trả")
                } footer: {
                    Text("Tiền cọc chỉ để ghi nhớ — không ghi vào sổ.")
                }

                Section("Thời hạn") {
                    DatePicker(
                        "Ngày bắt đầu",
                        selection: $draft.startDate,
                        displayedComponents: .date
                    )
                    .environment(\.calendar, calendar)
                    Toggle("Có ngày kết thúc", isOn: $draft.hasEndDate)
                    if draft.hasEndDate {
                        DatePicker(
                            "Ngày kết thúc",
                            selection: $draft.endDate,
                            in: calendar.startOfDay(for: draft.startDate)...,
                            displayedComponents: .date
                        )
                        .environment(\.calendar, calendar)
                    }
                }

                Section("Ghi chú") {
                    TextField("Ghi chú (không bắt buộc)", text: $draft.note, axis: .vertical)
                        .lineLimit(2...4)
                }

                if !isNew {
                    Section {
                        Button(role: .destructive) {
                            deleteConfirmationShown = true
                        } label: {
                            Text("Xoá hợp đồng")
                                .frame(maxWidth: .infinity)
                        }
                    }
                }
            }
            .navigationTitle(isNew ? "Hợp đồng mới" : "Sửa hợp đồng")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Huỷ") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button(isNew ? "Thêm" : "Lưu", action: save)
                        .disabled(draft.trimmedName.isEmpty)
                }
            }
            .onAppear {
                if isNew {
                    DispatchQueue.main.async { nameFocused = true }
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
            .confirmationDialog(
                "Xoá hợp đồng này?",
                isPresented: $deleteConfirmationShown,
                titleVisibility: .visible
            ) {
                Button("Xoá hợp đồng", role: .destructive, action: deleteLease)
                Button("Huỷ", role: .cancel) {}
            } message: {
                Text("Giao dịch đã ghi vẫn giữ trong sổ nhưng không còn gắn hợp đồng.")
            }
        }
    }

    /// One tap-to-edit amount line ("Tiền thuê hằng tháng" / "Tiền cọc")
    /// whose keypad opens underneath.
    private func amountRow(
        _ title: String, part: AmountPart, amount: Int64
    ) -> some View {
        Button {
            withAnimation(.snappy(duration: 0.2)) {
                editingAmount = editingAmount == part ? nil : part
            }
        } label: {
            HStack {
                Text(title)
                Spacer()
                Text(VND.format(amount))
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
            }
        }
        .foregroundStyle(.primary)
        .accessibilityHint("Chạm để \(editingAmount == part ? "ẩn" : "hiện") bàn phím")
    }

    private var errorAlertPresented: Binding<Bool> {
        Binding(
            get: { error != nil },
            set: { if !$0 { error = nil } }
        )
    }

    private func save() {
        if let validationError = draft.validate() {
            error = validationError
            return
        }
        if let lease {
            draft.apply(to: lease)
        } else {
            context.insert(draft.makeLease(unit: unit))
        }
        try? context.save()
        dismiss()
    }

    /// `.nullify` leaves the lease's income rows in the ledger, unlinked.
    private func deleteLease() {
        guard let lease else { return }
        context.delete(lease)
        try? context.save()
        dismiss()
    }
}

#Preview("Hợp đồng mới") {
    let container = try! AppModelContainer.make(inMemory: true)
    let context = ModelContext(container)
    try! SeedData.seedIfNeeded(context: context)
    let unit = RentalUnit(name: "Phòng 102", listPrice: 4_500_000)
    context.insert(unit)
    return RentalLeaseEditView(unit: unit)
        .modelContainer(container)
}

#Preview("Sửa") {
    let container = try! AppModelContainer.make(inMemory: true)
    let context = ModelContext(container)
    try! SeedData.seedIfNeeded(context: context)
    let unit = RentalUnit(name: "Phòng 101", listPrice: 5_000_000)
    context.insert(unit)
    let lease = RentalLease(
        tenantName: "Nguyễn Văn A", tenantPhone: "090 123 4567",
        startDate: AppCalendar.vietnam.date(byAdding: .month, value: -5, to: .now)!,
        monthlyRent: 5_000_000, deposit: 5_000_000, paymentDay: 5,
        unit: unit)
    context.insert(lease)
    return RentalLeaseEditView(unit: unit, lease: lease)
        .modelContainer(container)
}
