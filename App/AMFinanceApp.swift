import SwiftUI
import SwiftData

@main
struct AMFinanceApp: App {
    private let container: ModelContainer?

    init() {
        do {
            let container = try AppModelContainer.make()
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
