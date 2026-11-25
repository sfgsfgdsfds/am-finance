import SwiftUI
import SwiftData

@main
struct AMFinanceApp: App {
    private let container: ModelContainer?
    /// The one shared coordinator behind `walletSyncAutoRefresh` and the
    /// dashboard banner — nil during UI tests, so no wallet sync ever runs.
    private let syncCoordinator: WalletSyncCoordinator?
    /// The shared two-way web sync coordinator — created on every launch
    /// (it stays inert until enabled). Under `-uiTestInMemoryStore` its
    /// shadow is in-memory; `-uiTestFakeSyncServer` swaps the API client
    /// for the DEBUG in-app fake.
    private let financeSyncCoordinator: FinanceSyncCoordinator?
    /// The online-only launch pipeline — nil for plain
    /// `-uiTestInMemoryStore` launches (seeded in-memory store, no gate,
    /// no network). Every real launch has one: the app container is an
    /// in-memory store loaded from the server before any tab appears.
    private let onlineStore: OnlineStore?
    /// Rebuilt when "Xoá dữ liệu" finishes: a fresh view identity drops
    /// every screen's references to deleted SwiftData objects and returns
    /// every navigation stack to its root.
    @State private var dataResetToken = UUID()

    init() {
        do {
            // UI tests pass -uiTestInMemoryStore so they run against a throwaway
            // in-memory store (still seeded) and never touch real data.
            let arguments = ProcessInfo.processInfo.arguments
            let uiTest = arguments.contains("-uiTestInMemoryStore")
            let online = OnlineStore.usesOnlinePipeline(arguments: arguments)
            if uiTest {
                // UI tests start from factory defaults — the Agent access
                // picker's persisted values must not leak between launches.
                UserDefaults.standard.removeObject(
                    forKey: AIAgentView.accessDefaultsKey)
                UserDefaults.standard.removeObject(
                    forKey: AIAgentView.includeNotesDefaultsKey)
            }
            // Never persisted locally: the data lives in memory for the
            // session and comes from the server (see `OnlineStore`).
            let container = try AppModelContainer.make(inMemory: true)
            if !online {
                try SeedData.seedIfNeeded(context: ModelContext(container))
            }
            // The online stack can throw (bad base URL) — build it before
            // any stored property is assigned.
            let stack: FinanceSyncStack? = online
                ? try MainActor.assumeIsolated {
                    try FinanceSyncCoordinator.makeStack(
                        container: container, inMemoryShadow: true)
                }
                : nil
            self.container = container
            self.syncCoordinator = uiTest ? nil : MainActor.assumeIsolated {
                WalletSyncCoordinator.live(context: container.mainContext)
            }
            // Plain UI-test launches get no coordinator at all — the
            // same treatment `syncCoordinator` gets — so no shadow store,
            // refresh task, timer or save observer exists while tests
            // run. Only `-uiTestFakeSyncServer` builds one (it points the
            // API at the in-app fake — see FinanceSyncUITestSupport).
            let fakeSyncServer = arguments.contains("-uiTestFakeSyncServer")
            if let stack {
                self.financeSyncCoordinator = MainActor.assumeIsolated {
                    stack.coordinator
                }
                self.onlineStore = MainActor.assumeIsolated {
                    OnlineStore.live(
                        stack: stack, container: container,
                        fakeServer: uiTest)
                }
            } else {
                self.financeSyncCoordinator = uiTest && !fakeSyncServer
                    ? nil
                    : MainActor.assumeIsolated {
                        try? FinanceSyncCoordinator.live(container: container)
                    }
                self.onlineStore = nil
            }
            // BGTaskScheduler demands registration before the launch
            // sequence finishes — App.init is the earliest hook there is.
            // The scheduler itself is a no-op under -uiTestInMemoryStore.
            MainActor.assumeIsolated {
                BackgroundRefreshScheduler.registerHandler(
                    container: container,
                    financeSync: self.financeSyncCoordinator,
                    onlineStore: self.onlineStore)
            }
        } catch {
            self.container = nil
            self.syncCoordinator = nil
            self.financeSyncCoordinator = nil
            self.onlineStore = nil
        }
    }

    var body: some Scene {
        WindowGroup {
            if let container {
                if let onlineStore {
                    OnlineGate(store: onlineStore) {
                        rootContent(container: container)
                    }
                } else {
                    rootContent(container: container)
                }
            } else {
                Text("Không thể mở dữ liệu. Vui lòng khởi động lại ứng dụng.")
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .padding()
            }
        }
    }

    /// The root tabs with every activation hook — under the online
    /// pipeline this only exists once the store is `ready`.
    private func rootContent(container: ModelContainer) -> some View {
        RootTabView(syncCoordinator: syncCoordinator)
            .modelContainer(container)
            .environment(\.financeSync, financeSyncCoordinator)
            .appScenePhaseHooks(container: container)
            .id(dataResetToken)
            // After `.id` so a data-reset rebuild does not tear
            // the modifier's observers down with the content.
            .financeSyncAutoRefresh(financeSyncCoordinator)
            .onReceive(NotificationCenter.default.publisher(
                for: .dataResetCompleted
            )) { _ in
                // The container is already wiped and reseeded by
                // this point; bump the store so no stale aggregate
                // survives while views rebuild.
                LedgerBalanceStores.shared(for: container)
                    .invalidate()
                dataResetToken = UUID()
            }
    }
}

/// Scene-phase hooks owned by the App struct:
/// - `.background`: keep one `vn.amx.finance.refresh` request outstanding,
///   submitted ~15 minutes out (the run itself also re-arms when it
///   finishes).
/// - `.active`: force the ledger fingerprint check — on iOS 17 a write can
///   commit without any save notification reaching the balance store, and
///   returning to the foreground is the last moment a stale aggregate
///   could hide behind the throttle.
/// Read at view level — the App struct's own environment carries no
/// scenePhase.
private struct AppScenePhaseModifier: ViewModifier {
    @Environment(\.scenePhase) private var scenePhase
    let container: ModelContainer

    func body(content: Content) -> some View {
        content.onChange(of: scenePhase) { _, phase in
            switch phase {
            case .active:
                LedgerBalanceStores.shared(for: container)
                    .refreshIfStale(force: true)
            case .background:
                BackgroundRefreshScheduler.scheduleNext()
            default:
                break
            }
        }
    }
}

extension View {
    fileprivate func appScenePhaseHooks(container: ModelContainer) -> some View {
        modifier(AppScenePhaseModifier(container: container))
    }
}
