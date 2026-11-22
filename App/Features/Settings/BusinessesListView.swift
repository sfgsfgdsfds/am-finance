import SwiftUI
import SwiftData

/// Quản lý mảng kinh doanh (nguồn thu như "Căn hộ dịch vụ", "Làm web"):
/// thêm, sửa, kéo để sắp xếp, lưu trữ / bỏ lưu trữ và xoá. Pushed inside an
/// existing NavigationStack.
struct BusinessesListView: View {
    @Environment(\.modelContext) private var context
    @Query(sort: \Business.sortOrder) private var businesses: [Business]

    @State private var editing: Business?
    @State private var showsAdd = false
    @State private var showsArchived = false
    @State private var deleteConfirm: Business?
    @State private var deleteBlocked: Business?
    @State private var showsDeleteConfirm = false
    @State private var showsDeleteBlocked = false

    private var active: [Business] {
        businesses.filter { !$0.isArchived }
    }

    private var archived: [Business] {
        businesses.filter { $0.isArchived }
    }

    var body: some View {
        List {
            Section {
                if active.isEmpty {
                    EmptyStateView(
                        symbol: "briefcase.fill",
                        title: "Chưa có mảng kinh doanh",
                        message: "Chạm + để tạo mảng đầu tiên — ví dụ \"Căn hộ dịch vụ\"."
                    )
                    .listRowSeparator(.hidden)
                    .listRowBackground(Color.clear)
                } else {
                    ForEach(active) { business in
                        row(business)
                    }
                    .onMove(perform: move)
                }
            }

            if !archived.isEmpty {
                Section("Đã lưu trữ (\(archived.count))", isExpanded: $showsArchived) {
                    ForEach(archived) { business in
                        row(business)
                            .foregroundStyle(.secondary)
                    }
                }
            }
        }
        .navigationTitle("Mảng kinh doanh")
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button {
                    showsAdd = true
                } label: {
                    Label("Thêm mảng kinh doanh", systemImage: "plus")
                }
            }
            ToolbarItem(placement: .topBarTrailing) {
                EditButton()
            }
        }
        .sheet(isPresented: $showsAdd) {
            BusinessEditView()
        }
        .sheet(item: $editing) { business in
            BusinessEditView(business: business)
        }
        .alert(
            "Xoá mảng kinh doanh",
            isPresented: $showsDeleteConfirm,
            presenting: deleteConfirm
        ) { business in
            Button("Xoá", role: .destructive) {
                context.delete(business)
                save()
            }
            Button("Huỷ", role: .cancel) {}
        } message: { business in
            Text("\"\(business.name)\" sẽ bị xoá vĩnh viễn.")
        }
        .alert(
            "Không thể xoá",
            isPresented: $showsDeleteBlocked,
            presenting: deleteBlocked
        ) { business in
            Button("Lưu trữ") {
                business.isArchived = true
                save()
            }
            Button("Huỷ", role: .cancel) {}
        } message: { business in
            Text("\"\(business.name)\" đang được dùng bởi \(business.transactions?.count ?? 0) giao dịch. Lưu trữ sẽ ẩn nó khỏi danh sách chọn.")
        }
    }

    @ViewBuilder
    private func row(_ business: Business) -> some View {
        Button {
            editing = business
        } label: {
            HStack(spacing: 12) {
                IconBadge(symbol: business.icon, colorHex: business.colorHex, size: 32)
                VStack(alignment: .leading, spacing: 2) {
                    Text(business.name)
                    if !business.note.isEmpty {
                        Text(business.note)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                }
                Spacer()
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .swipeActions(edge: .trailing) {
            Button(role: .destructive) {
                requestDelete(business)
            } label: {
                Label("Xoá", systemImage: "trash")
            }
            Button {
                toggleArchive(business)
            } label: {
                Label(
                    business.isArchived ? "Bỏ lưu trữ" : "Lưu trữ",
                    systemImage: business.isArchived ? "tray.and.arrow.up.fill" : "archivebox.fill"
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

    private func toggleArchive(_ business: Business) {
        if business.isArchived {
            business.sortOrder = (active.map(\.sortOrder).max() ?? -1) + 1
        }
        business.isArchived.toggle()
        save()
    }

    private func requestDelete(_ business: Business) {
        switch SettingsDeleteRule.decision(transactionCount: business.transactions?.count ?? 0) {
        case .delete:
            deleteConfirm = business
            showsDeleteConfirm = true
        case .archiveOnly:
            deleteBlocked = business
            showsDeleteBlocked = true
        }
    }

    private func save() {
        try? context.save()
    }
}

#Preview {
    let container = try! AppModelContainer.make(inMemory: true)
    try! SeedData.seedIfNeeded(context: ModelContext(container))
    return NavigationStack {
        BusinessesListView()
    }
    .modelContainer(container)
}
