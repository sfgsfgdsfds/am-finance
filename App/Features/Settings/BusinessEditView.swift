import SwiftUI
import SwiftData

/// Sheet to create or edit a business / income stream (nil = create).
/// Owns its NavigationStack.
struct BusinessEditView: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.modelContext) private var context
    @Query(sort: \Business.sortOrder) private var existing: [Business]

    private let business: Business?
    @State private var draft: BusinessDraft
    @FocusState private var nameFocused: Bool

    init(business: Business? = nil) {
        self.business = business
        _draft = State(initialValue: business.map(BusinessDraft.init) ?? BusinessDraft())
    }

    private var isNew: Bool { business == nil }

    private var hasDuplicate: Bool {
        draft.isValid && draft.duplicateName(among: existing, excludingID: business?.id)
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField("Tên mảng kinh doanh", text: $draft.name)
                        .focused($nameFocused)
                } header: {
                    Text("Tên")
                } footer: {
                    if hasDuplicate {
                        Label(
                            "Đã có mảng kinh doanh cùng tên.",
                            systemImage: "exclamationmark.triangle.fill"
                        )
                        .foregroundStyle(.orange)
                    }
                }

                Section("Ghi chú") {
                    TextField("Ghi chú (không bắt buộc)", text: $draft.note, axis: .vertical)
                        .lineLimit(2...4)
                }

                Section("Biểu tượng") {
                    IconPickerGrid(selection: $draft.icon)
                        .padding(.vertical, 4)
                }

                Section("Màu sắc") {
                    ColorHexPickerGrid(selection: $draft.colorHex)
                        .padding(.vertical, 4)
                }
            }
            .navigationTitle(isNew ? "Mảng kinh doanh mới" : "Sửa mảng kinh doanh")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Huỷ") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button(isNew ? "Thêm" : "Lưu", action: save)
                        .disabled(!draft.isValid)
                }
            }
            .onAppear {
                DispatchQueue.main.async { nameFocused = true }
            }
        }
    }

    private func save() {
        guard draft.isValid else { return }
        if let business {
            draft.apply(to: business)
        } else {
            let next = (existing.map(\.sortOrder).max() ?? -1) + 1
            context.insert(draft.makeBusiness(sortOrder: next))
        }
        try? context.save()
        dismiss()
    }
}

#Preview("Tạo mới") {
    let container = try! AppModelContainer.make(inMemory: true)
    try! SeedData.seedIfNeeded(context: ModelContext(container))
    return BusinessEditView()
        .modelContainer(container)
}

#Preview("Sửa") {
    let container = try! AppModelContainer.make(inMemory: true)
    let context = ModelContext(container)
    try! SeedData.seedIfNeeded(context: context)
    let business = try! context.fetch(FetchDescriptor<Business>()).first!
    return BusinessEditView(business: business)
        .modelContainer(container)
}
