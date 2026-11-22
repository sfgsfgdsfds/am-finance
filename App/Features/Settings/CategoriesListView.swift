import SwiftUI
import SwiftData
import FinanceCore

/// Quản lý danh mục chi / thu: thêm, sửa, kéo để sắp xếp (ghi lại sortOrder),
/// lưu trữ / bỏ lưu trữ và xoá. Pushed inside an existing NavigationStack.
struct CategoriesListView: View {
    @Environment(\.modelContext) private var context
    @Query(sort: \LedgerCategory.sortOrder) private var categories: [LedgerCategory]

    @State private var kind: CategoryKind = .expense
    @State private var editing: LedgerCategory?
    @State private var showsAdd = false
    @State private var showsArchived = false
    @State private var deleteConfirm: LedgerCategory?
    @State private var deleteBlocked: LedgerCategory?
    @State private var showsDeleteConfirm = false
    @State private var showsDeleteBlocked = false

    private var active: [LedgerCategory] {
        categories.filter { $0.kind == kind && !$0.isArchived }
    }

    private var archived: [LedgerCategory] {
        categories.filter { $0.kind == kind && $0.isArchived }
    }

    var body: some View {
        List {
            Section {
                Picker("Loại danh mục", selection: $kind) {
                    Text("Chi").tag(CategoryKind.expense)
                    Text("Thu").tag(CategoryKind.income)
                }
                .pickerStyle(.segmented)
                .labelsHidden()
            }

            Section {
                if active.isEmpty {
                    EmptyStateView(
                        symbol: "tag.fill",
                        title: "Chưa có danh mục",
                        message: "Chạm + để tạo danh mục đầu tiên."
                    )
                    .listRowSeparator(.hidden)
                    .listRowBackground(Color.clear)
                } else {
                    ForEach(active) { category in
                        row(category)
                    }
                    .onMove(perform: move)
                }
            }

            if !archived.isEmpty {
                Section("Đã lưu trữ (\(archived.count))", isExpanded: $showsArchived) {
                    ForEach(archived) { category in
                        row(category)
                            .foregroundStyle(.secondary)
                    }
                }
            }
        }
        .navigationTitle("Danh mục")
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button {
                    showsAdd = true
                } label: {
                    Label("Thêm danh mục", systemImage: "plus")
                }
            }
            ToolbarItem(placement: .topBarTrailing) {
                EditButton()
            }
        }
        .sheet(isPresented: $showsAdd) {
            CategoryEditView(defaultKind: kind)
        }
        .sheet(item: $editing) { category in
            CategoryEditView(category: category)
        }
        .alert(
            "Xoá danh mục",
            isPresented: $showsDeleteConfirm,
            presenting: deleteConfirm
        ) { category in
            Button("Xoá", role: .destructive) {
                context.delete(category)
                save()
            }
            Button("Huỷ", role: .cancel) {}
        } message: { category in
            Text("\"\(category.name)\" sẽ bị xoá vĩnh viễn.")
        }
        .alert(
            "Không thể xoá",
            isPresented: $showsDeleteBlocked,
            presenting: deleteBlocked
        ) { category in
            Button("Lưu trữ") {
                category.isArchived = true
                save()
            }
            Button("Huỷ", role: .cancel) {}
        } message: { category in
            Text("\"\(category.name)\" đang được dùng bởi \(category.transactions?.count ?? 0) giao dịch. Lưu trữ sẽ ẩn nó khỏi danh sách chọn.")
        }
    }

    @ViewBuilder
    private func row(_ category: LedgerCategory) -> some View {
        Button {
            editing = category
        } label: {
            HStack(spacing: 12) {
                IconBadge(symbol: category.icon, colorHex: category.colorHex, size: 32)
                Text(category.name)
                Spacer()
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .swipeActions(edge: .trailing) {
            Button(role: .destructive) {
                requestDelete(category)
            } label: {
                Label("Xoá", systemImage: "trash")
            }
            Button {
                toggleArchive(category)
            } label: {
                Label(
                    category.isArchived ? "Bỏ lưu trữ" : "Lưu trữ",
                    systemImage: category.isArchived ? "tray.and.arrow.up.fill" : "archivebox.fill"
                )
            }
            .tint(.orange)
        }
    }

    private func move(from source: IndexSet, to destination: Int) {
        SettingsReorder.renumber(
            SettingsReorder.moved(active, from: source, to: destination),
            sortOrder: \.sortOrder
        )
        save()
    }

    private func toggleArchive(_ category: LedgerCategory) {
        if category.isArchived {
            // Unarchived rows re-enter at the end of the visible list.
            category.sortOrder = (active.map(\.sortOrder).max() ?? -1) + 1
        }
        category.isArchived.toggle()
        save()
    }

    private func requestDelete(_ category: LedgerCategory) {
        switch SettingsDeleteRule.decision(transactionCount: category.transactions?.count ?? 0) {
        case .delete:
            deleteConfirm = category
            showsDeleteConfirm = true
        case .archiveOnly:
            deleteBlocked = category
            showsDeleteBlocked = true
        }
    }

    private func save() {
        try? context.save()
    }
}

#Preview("Chi") {
    let container = try! AppModelContainer.make(inMemory: true)
    try! SeedData.seedIfNeeded(context: ModelContext(container))
    return NavigationStack {
        CategoriesListView()
    }
    .modelContainer(container)
}
