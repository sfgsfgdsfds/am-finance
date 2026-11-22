import SwiftUI
import SwiftData
import FinanceCore

/// Sheet to create or edit a category (nil = create). Owns its
/// NavigationStack. The kind ("Chi"/"Thu") is selectable on create only;
/// on edit it stays fixed so existing transactions keep their meaning.
struct CategoryEditView: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.modelContext) private var context
    @Query(sort: \LedgerCategory.sortOrder) private var existing: [LedgerCategory]

    private let category: LedgerCategory?
    @State private var draft: CategoryDraft
    @FocusState private var nameFocused: Bool

    init(category: LedgerCategory? = nil, defaultKind: CategoryKind = .expense) {
        self.category = category
        _draft = State(initialValue: category.map(CategoryDraft.init)
            ?? CategoryDraft(kind: defaultKind))
    }

    private var isNew: Bool { category == nil }

    private var hasDuplicate: Bool {
        draft.isValid && draft.duplicateName(among: existing, excludingID: category?.id)
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField("Tên danh mục", text: $draft.name)
                        .focused($nameFocused)
                } header: {
                    Text("Tên")
                } footer: {
                    if hasDuplicate {
                        Label(
                            "Đã có danh mục cùng tên trong nhóm này.",
                            systemImage: "exclamationmark.triangle.fill"
                        )
                        .foregroundStyle(.orange)
                    }
                }

                Section("Loại") {
                    if isNew {
                        Picker("Loại", selection: $draft.kind) {
                            Text("Chi").tag(CategoryKind.expense)
                            Text("Thu").tag(CategoryKind.income)
                        }
                        .pickerStyle(.segmented)
                        .labelsHidden()
                    } else {
                        Text(draft.kind == .expense ? "Chi" : "Thu")
                            .foregroundStyle(.secondary)
                    }
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
            .navigationTitle(isNew ? "Danh mục mới" : "Sửa danh mục")
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
        if let category {
            draft.apply(to: category)
        } else {
            let next = (existing.filter { $0.kind == draft.kind }
                .map(\.sortOrder).max() ?? -1) + 1
            context.insert(draft.makeCategory(sortOrder: next))
        }
        try? context.save()
        dismiss()
    }
}

#Preview("Tạo mới") {
    let container = try! AppModelContainer.make(inMemory: true)
    try! SeedData.seedIfNeeded(context: ModelContext(container))
    return CategoryEditView(defaultKind: .expense)
        .modelContainer(container)
}

#Preview("Sửa") {
    let container = try! AppModelContainer.make(inMemory: true)
    let context = ModelContext(container)
    try! SeedData.seedIfNeeded(context: context)
    let category = try! context.fetch(FetchDescriptor<LedgerCategory>()).first!
    return CategoryEditView(category: category)
        .modelContainer(container)
}
