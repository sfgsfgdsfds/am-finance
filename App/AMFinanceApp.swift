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
                    .backgroundRefreshOnScenePhase()
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

/// Keeps one refresh request outstanding: every time the scene goes to
/// the background the next `vn.amx.finance.refresh` is submitted ~15
/// minutes out (the run itself also re-arms when it finishes). Read at
/// view level — the App struct's own environment carries no scenePhase.
private struct BackgroundRefreshPhaseModifier: ViewModifier {
    @Environment(\.scenePhase) private var scenePhase

    func body(content: Content) -> some View {
        content.onChange(of: scenePhase) { _, phase in
            guard phase == .background else { return }
            BackgroundRefreshScheduler.scheduleNext()
        }
    }
}

extension View {
    fileprivate func backgroundRefreshOnScenePhase() -> some View {
        modifier(BackgroundRefreshPhaseModifier())
    }
}
