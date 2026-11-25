import SwiftUI
import SwiftData

/// Defers a navigation destination until it is actually pushed: building the
/// link only stores the closure, so a screen listing many destinations whose
/// inits are heavyweight (the notification center, UserDefaults stores) does
/// not pay for them on every body evaluation — iOS 26 evaluates
/// `NavigationLink` destinations eagerly, which made this screen churn.
private struct LazyDestination<Content: View>: View {
    let build: () -> Content

    init(@ViewBuilder _ build: @escaping () -> Content) {
        self.build = build
    }

    var body: some View { build() }
}

/// Màn hình cài đặt — pushed inside an existing NavigationStack, so it must
/// not create its own stack.
struct SettingsView: View {
    @Query private var categories: [LedgerCategory]
    @Query private var businesses: [Business]
    /// Imported rows still waiting for a category — the inbox row's badge.
    @Query private var pendingReview: [LedgerTransaction]

    init() {
        _pendingReview = Query(
            filter: #Predicate { $0.needsReview == true },
            sort: \.date,
            order: .reverse
        )
    }

    private var activeCategoryCount: Int {
        categories.filter { !$0.isArchived }.count
    }

    private var activeBusinessCount: Int {
        businesses.filter { !$0.isArchived }.count
    }

    var body: some View {
        List {
            Section("Ngân hàng") {
                NavigationLink {
                    LazyDestination { WalletLinkSettingsView() }
                } label: {
                    Label("Kết nối wallet.amx.vn", systemImage: "link")
                }
                NavigationLink {
                    LazyDestination { WalletSyncAccountsView() }
                } label: {
                    Label(
                        "Tài khoản liên kết & đồng bộ",
                        systemImage: "arrow.triangle.2.circlepath")
                }
                NavigationLink {
                    LazyDestination { WalletSyncInboxView() }
                } label: {
                    rowLabel(
                        "Giao dịch chờ phân loại",
                        symbol: "tray.full.fill",
                        count: pendingReview.isEmpty ? nil : pendingReview.count)
                }
                NavigationLink {
                    LazyDestination { WalletSyncRulesView() }
                } label: {
                    Label("Quy tắc tự phân loại", systemImage: "checklist")
                }
            }

            Section("Trợ lý AI") {
                NavigationLink {
                    LazyDestination { AISettingsView() }
                } label: {
                    Label("Nhà cung cấp AI", systemImage: "cpu.fill")
                }
                NavigationLink {
                    LazyDestination { AIAgentView() }
                } label: {
                    HStack {
                        Label("Agent", systemImage: "sparkles")
                        Spacer()
                        AgentActivityDot()
                    }
                }
            }

            Section("Kế hoạch") {
                NavigationLink {
                    LazyDestination { BudgetsView() }
                } label: {
                    Label("Ngân sách", systemImage: "chart.pie.fill")
                }
                NavigationLink {
                    LazyDestination { RecurringListView() }
                } label: {
                    Label("Giao dịch định kỳ", systemImage: "repeat")
                }
                NavigationLink {
                    LazyDestination { ReminderSettingsView() }
                } label: {
                    Label("Nhắc nhở", systemImage: "bell.fill")
                }
            }

            Section("Phân loại") {
                NavigationLink {
                    LazyDestination { CategoriesListView() }
                } label: {
                    rowLabel("Danh mục", symbol: "tag.fill", count: activeCategoryCount)
                }
                NavigationLink {
                    LazyDestination { BusinessesListView() }
                } label: {
                    rowLabel("Mảng kinh doanh", symbol: "briefcase.fill", count: activeBusinessCount)
                }
                NavigationLink {
                    LazyDestination { BusinessHubView() }
                } label: {
                    Label("Lãi lỗ theo mảng", systemImage: "chart.bar.fill")
                }
                NavigationLink {
                    LazyDestination { ReceivablesView() }
                } label: {
                    Label("Khoản ứng hộ khách", systemImage: "person.badge.clock.fill")
                }
                NavigationLink {
                    LazyDestination { RentalsView() }
                } label: {
                    Label("Phòng cho thuê", systemImage: "bed.double.fill")
                }
            }

            Section("Bảo mật") {
                NavigationLink {
                    LazyDestination { AppLockSettingsView() }
                } label: {
                    Label("Khoá ứng dụng", systemImage: "lock.fill")
                }
            }

            Section("Dữ liệu") {
                NavigationLink {
                    LazyDestination { FinanceSyncSettingsView() }
                } label: {
                    Label(
                        "Đồng bộ với web",
                        systemImage: "icloud.and.arrow.up.and.arrow.down"
                    )
                }
                .accessibilityIdentifier("financeSync.settingsRow")
                NavigationLink {
                    LazyDestination { BackupView() }
                } label: {
                    Label("Sao lưu & khôi phục", systemImage: "icloud.fill")
                }
                NavigationLink {
                    LazyDestination { CSVImportView() }
                } label: {
                    Label("Nhập sao kê CSV", systemImage: "doc.badge.arrow.down")
                }
                NavigationLink {
                    LazyDestination { DataResetView() }
                } label: {
                    Label("Xoá dữ liệu", systemImage: "trash.fill")
                        .foregroundStyle(.red)
                }
            }

            Section("Giới thiệu") {
                LabeledContent("Ứng dụng", value: SettingsAbout.appName)
                LabeledContent("Phiên bản", value: SettingsAbout.versionText)
            }
        }
        .navigationTitle("Cài đặt")
    }

    private func rowLabel(_ title: String, symbol: String, count: Int?) -> some View {
        HStack {
            Label(title, systemImage: symbol)
            Spacer()
            if let count {
                Text("\(count)")
                    .font(.callout)
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
            }
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
