import SwiftUI
import SwiftData

@main
struct AMFinanceApp: App {
    private let container: ModelContainer?

    init() {
        do {
            // UI tests pass -uiTestInMemoryStore so they run against a throwaway
            // in-memory store (still seeded) and never touch real data.
            let inMemory = ProcessInfo.processInfo.arguments
                .contains("-uiTestInMemoryStore")
            let container = try AppModelContainer.make(inMemory: inMemory)
            try SeedData.seedIfNeeded(context: ModelContext(container))
            self.container = container
        } catch {
            self.container = nil
        }
    }

    var body: some Scene {
        WindowGroup {
            if let container {
                RootTabView()
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
