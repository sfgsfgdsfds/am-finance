import SwiftUI
import SwiftData
import FinanceCore

/// Create/edit sheet for one `RentalUnit` (nil = create). Owns its
/// NavigationStack. Deleting a room removes its leases first — the
/// `.nullify` rule would otherwise leave them behind — and their rent
/// rows stay in the ledger, unlinked.
struct RentalUnitEditView: View {
    private let unit: RentalUnit?

    @Environment(\.dismiss) private var dismiss
    @Environment(\.modelContext) private var context
    @Query(sort: \RentalUnit.sortOrder) private var existing: [RentalUnit]
    @Query(sort: \Business.sortOrder) private var businesses: [Business]

    @State private var draft: RentalUnitDraft
    @State private var keypadVisible = false
    @State private var deleteConfirmationShown = false
    @State private var error: RentalUnitDraftError?
    @FocusState private var nameFocused: Bool

    init(unit: RentalUnit? = nil, business: Business? = nil) {
        self.unit = unit
        _draft = State(initialValue: unit.map(RentalUnitDraft.init)
            ?? RentalUnitDraft(business: business))
    }

    private var isNew: Bool { unit == nil }

    private var activeBusinesses: [Business] {
        businesses.filter { !$0.isArchived }
    }

    var body: some View {
        NavigationStack {
            Form {
                Section("Phòng") {
                    TextField("Tên phòng", text: $draft.name)
                        .focused($nameFocused)
                    Picker("Mảng kinh doanh", selection: $draft.business) {
                        Text("Không có").tag(nil as Business?)
                        ForEach(activeBusinesses, id: \.id) { business in
                            Text(business.name).tag(business as Business?)
                        }
                    }
                }

                Section {
                    Button {
                        withAnimation(.snappy(duration: 0.2)) {
                            keypadVisible.toggle()
                        }
                    } label: {
                        HStack {
                            Text("Giá niêm yết")
                            Spacer()
                            Text(VND.format(draft.listPrice))
                                .monospacedDigit()
                                .foregroundStyle(.secondary)
                        }
                    }
                    .foregroundStyle(.primary)
                    .accessibilityHint(keypadVisible
                        ? "Chạm để ẩn bàn phím" : "Chạm để hiện bàn phím")
                    if keypadVisible {
                        AmountKeypad(amount: $draft.listPrice)
                    }
                } header: {
                    Text("Giá thuê hằng tháng")
                } footer: {
                    Text("Giá tham khảo — mỗi hợp đồng ghi giá thuê riêng.")
                }

                Section("Ghi chú") {
                    TextField("Ghi chú (không bắt buộc)", text: $draft.note, axis: .vertical)
                        .lineLimit(2...4)
                }

                if unit != nil {
                    Section {
                        Toggle("Đã lưu trữ", isOn: $draft.isArchived)
                    } footer: {
                        Text("Phòng lưu trữ xếp gọn cuối danh sách và không tính vào tháng.")
                    }

                    Section {
                        Button(role: .destructive) {
                            deleteConfirmationShown = true
                        } label: {
                            Text("Xoá phòng")
                                .frame(maxWidth: .infinity)
                        }
                    }
                }
            }
            .navigationTitle(isNew ? "Phòng mới" : "Sửa phòng")
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
                "Xoá phòng này?",
                isPresented: $deleteConfirmationShown,
                titleVisibility: .visible
            ) {
                Button("Xoá phòng", role: .destructive, action: deleteUnit)
                Button("Huỷ", role: .cancel) {}
            } message: {
                Text("Các hợp đồng của phòng cũng bị xoá; giao dịch đã ghi vẫn giữ trong sổ.")
            }
        }
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
        if let unit {
            draft.apply(to: unit)
        } else {
            let next = (existing.map(\.sortOrder).max() ?? -1) + 1
            context.insert(draft.makeUnit(sortOrder: next))
        }
        try? context.save()
        dismiss()
    }

    /// Leases are deleted explicitly — `.nullify` keeps their income rows
    /// in the ledger, unlinked from the room.
    private func deleteUnit() {
        guard let unit else { return }
        for lease in unit.leases ?? [] { context.delete(lease) }
        context.delete(unit)
        try? context.save()
        dismiss()
    }
}

#Preview("Tạo mới") {
    let container = try! AppModelContainer.make(inMemory: true)
    try! SeedData.seedIfNeeded(context: ModelContext(container))
    return RentalUnitEditView()
        .modelContainer(container)
}

#Preview("Sửa") {
    let container = try! AppModelContainer.make(inMemory: true)
    let context = ModelContext(container)
    try! SeedData.seedIfNeeded(context: context)
    let unit = RentalUnit(
        name: "Phòng 101", listPrice: 5_000_000,
        note: "Tầng 1, ban công",
        business: try! context.fetch(FetchDescriptor<Business>())
            .first { $0.name == "Căn hộ dịch vụ" })
    context.insert(unit)
    return RentalUnitEditView(unit: unit)
        .modelContainer(container)
}
