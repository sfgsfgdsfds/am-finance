import SwiftUI
import SwiftData

@main
struct AMFinanceApp: App {
    private let container: ModelContainer?
    /// The one shared coordinator behind `walletSyncAutoRefresh` and the
    /// dashboard banner — nil during UI tests, so no wallet sync ever runs.
    private let syncCoordinator: WalletSyncCoordinator?

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
            } else {
                Text("Không thể mở dữ liệu. Vui lòng khởi động lại ứng dụng.")
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .padding()
            }
        }
    }
}
