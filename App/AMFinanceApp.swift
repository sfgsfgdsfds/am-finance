import SwiftUI
import SwiftData

@main
struct AMFinanceApp: App {
    private let container: ModelContainer?
    /// The one shared coordinator behind `walletSyncAutoRefresh` and the
    /// dashboard banner — nil during UI tests, so no wallet sync ever runs.
    private let syncCoordinator: WalletSyncCoordinator?
    /// Rebuilt when "Xoá dữ liệu" finishes: a fresh view identity drops
    /// every screen's references to deleted SwiftData objects and returns
    /// every navigation stack to its root.
    @State private var dataResetToken = UUID()

    init() {
        do {
            // UI tests pass -uiTestInMemoryStore so they run against a throwaway
            // in-memory store (still seeded) and never touch real data.
            let inMemory = ProcessInfo.processInfo.arguments
                .contains("-uiTestInMemoryStore")
            if inMemory {
                // UI tests start from factory defaults — the Agent access
                // picker's persisted values must not leak between launches.
                UserDefaults.standard.removeObject(
                    forKey: AIAgentView.accessDefaultsKey)
                UserDefaults.standard.removeObject(
                    forKey: AIAgentView.includeNotesDefaultsKey)
            }
            let container = try AppModelContainer.make(inMemory: inMemory)
            try SeedData.seedIfNeeded(context: ModelContext(container))
            self.container = container
            self.syncCoordinator = inMemory ? nil : MainActor.assumeIsolated {
                WalletSyncCoordinator.live(context: container.mainContext)
            }
            // BGTaskScheduler demands registration before the launch
            // sequence finishes — App.init is the earliest hook there is.
            // The scheduler itself is a no-op under -uiTestInMemoryStore.
            MainActor.assumeIsolated {
                BackgroundRefreshScheduler.registerHandler(container: container)
            }
        } catch {
            self.container = nil
            self.syncCoordinator = nil
        }
    }

    var body: some Scene {
        WindowGroup {
            if let container {
                RootTabView(syncCoordinator: syncCoordinator)
                    .modelContainer(container)
                    .appScenePhaseHooks(container: container)
                    .id(dataResetToken)
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
            } else {
                Text("Không thể mở dữ liệu. Vui lòng khởi động lại ứng dụng.")
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .padding()
            }
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
