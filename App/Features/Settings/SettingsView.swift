import SwiftUI
import SwiftData

/// Màn hình cài đặt — pushed inside an existing NavigationStack, so it must
/// not create its own stack.
struct SettingsView: View {
    @Query private var categories: [LedgerCategory]
    @Query private var businesses: [Business]

    private var activeCategoryCount: Int {
        categories.filter { !$0.isArchived }.count
    }

    private var activeBusinessCount: Int {
        businesses.filter { !$0.isArchived }.count
    }

    var body: some View {
        List {
            Section("Phân loại") {
                NavigationLink {
                    CategoriesListView()
                } label: {
                    rowLabel("Danh mục", symbol: "tag.fill", count: activeCategoryCount)
                }
                NavigationLink {
                    BusinessesListView()
                } label: {
                    rowLabel("Mảng kinh doanh", symbol: "briefcase.fill", count: activeBusinessCount)
                }
            }

            Section("Dữ liệu") {
                NavigationLink {
                    BackupView()
                } label: {
                    Label("Sao lưu & khôi phục", systemImage: "icloud.fill")
                }
            }

            Section("Giới thiệu") {
                LabeledContent("Ứng dụng", value: SettingsAbout.appName)
                LabeledContent("Phiên bản", value: SettingsAbout.versionText)
            }
        }
        .navigationTitle("Cài đặt")
    }

    private func rowLabel(_ title: String, symbol: String, count: Int) -> some View {
        HStack {
            Label(title, systemImage: symbol)
            Spacer()
            Text("\(count)")
                .font(.callout)
                .monospacedDigit()
                .foregroundStyle(.secondary)
        }
    }
}

#Preview {
    let container = try! AppModelContainer.make(inMemory: true)
    try! SeedData.seedIfNeeded(context: ModelContext(container))
    return NavigationStack {
        SettingsView()
    }
    .modelContainer(container)
}
