import SwiftUI
import SwiftData

struct RootTabView: View {
    /// The shared wallet-sync coordinator created in `AMFinanceApp` — nil
    /// under `-uiTestInMemoryStore`, where no sync may run.
    let syncCoordinator: WalletSyncCoordinator?

    @Environment(\.modelContext) private var context
    @Environment(\.scenePhase) private var scenePhase

    @State private var quickAddShown = false
    /// Selected tab — "Tổng quan" (0) by default, which is also where a
    /// rebuilt tree lands after the data reset.
    @State private var selectedTab = 0
    /// Last time the activation housekeeping ran — the once-a-minute cap.
    @State private var lastActivationWork = Date.distantPast
    /// Ledger `changeCount` the reminder queue was last built against —
    /// an activation with no ledger movement and a fresh plan skips the
    /// rebuild entirely.
    @State private var lastReminderChangeCount = -1
    @State private var lastReminderBuild = Date.distantPast

    init(syncCoordinator: WalletSyncCoordinator? = nil) {
        self.syncCoordinator = syncCoordinator
    }

    var body: some View {
        syncedContent
            .appLockProtected()
            .onChange(of: scenePhase, initial: true) { _, phase in
                guard phase == .active else { return }
                runActivationWork()
            }
    }

    /// The tabs with auto-refresh attached when a coordinator exists —
    /// without one (UI tests) the modifier is left off entirely so nothing
    /// wallet-related ever fires.
    @ViewBuilder
    private var syncedContent: some View {
        if let syncCoordinator {
            tabContent.walletSyncAutoRefresh(syncCoordinator)
        } else {
            tabContent
        }
    }

    private var tabContent: some View {
        TabView(selection: $selectedTab) {
            DashboardView(syncCoordinator: syncCoordinator)
                .tabItem {
                    Label("Tổng quan", systemImage: "house.fill")
                }
                .tag(0)
            TransactionsView()
                .tabItem {
                    Label("Giao dịch", systemImage: "arrow.left.arrow.right")
                }
                .tag(1)
            DebtsView()
                .tabItem {
                    Label("Nợ & Thẻ", systemImage: "creditcard.fill")
                }
                .tag(2)
            ReportsView()
                .tabItem {
                    Label("Báo cáo", systemImage: "chart.bar.fill")
                }
                .tag(3)
        }
        .overlay(alignment: .bottom) {
            quickAddButton
        }
        .sheet(isPresented: $quickAddShown) {
            TransactionEditorView()
        }
    }

    /// Once per activation (capped at one run a minute): post the due
    /// recurring transactions, then rebuild the reminder queue — but only
    /// when the ledger moved or the plan went stale; every failure is
    /// swallowed, housekeeping must never crash or block.
    private func runActivationWork() {
        let now = Date.now
        guard now.timeIntervalSince(lastActivationWork) >= 60 else { return }
        lastActivationWork = now
        _ = try? RecurringGenerator.generateDueTransactions(in: context, now: now)
        // UI tests must never touch the real notification center — a
        // reschedule could schedule live requests on the device/simulator.
        guard !AppLockSettingsStore.isUITestLaunch() else { return }
        let ledger = LedgerBalanceStores.shared(for: context.container)
        guard ledger.changeCount != lastReminderChangeCount
            || now.timeIntervalSince(lastReminderBuild) >= 15 * 60
        else { return }
        lastReminderChangeCount = ledger.changeCount
        lastReminderBuild = now
        Task {
            await ReminderScheduler().reschedule(context: context)
        }
    }

    /// Centered "+" floating over the tab bar's middle gap — the fastest way
    /// into a new transaction from anywhere in the app.
    private var quickAddButton: some View {
        Button {
            quickAddShown = true
        } label: {
            Image(systemName: "plus")
                .font(.title2.weight(.bold))
                .foregroundStyle(.white)
                .frame(width: 56, height: 56)
                .background(Color.accentColor, in: Circle())
                .shadow(color: .black.opacity(0.25), radius: 6, y: 3)
        }
        .accessibilityLabel("Thêm giao dịch")
        .accessibilityIdentifier("root.quickAdd")
        .padding(.bottom, 20)
    }
}

#Preview {
    let container = try! AppModelContainer.make(inMemory: true)
    try! SeedData.seedIfNeeded(context: ModelContext(container))
    return RootTabView()
        .modelContainer(container)
}
