import SwiftUI
import SwiftData

/// Màn hình "Khoá ứng dụng" — Face ID (kèm mã khoá thiết bị dự phòng) cho
/// toàn bộ ứng dụng. Pushed inside an existing NavigationStack, so it must
/// not create its own stack.
struct AppLockSettingsView: View {
    private let controller: AppLockController

    @State private var isEnabling = false
    @State private var showUnavailableAlert = false

    @MainActor
    init(controller: AppLockController = .shared) {
        self.controller = controller
    }

    var body: some View {
        List {
            Section {
                Toggle("Khoá bằng Face ID", isOn: enabledBinding)
                    .disabled(isEnabling)
                    .accessibilityIdentifier("appLock.enabledToggle")
            } footer: {
                Text("Yêu cầu Face ID hoặc mã khoá thiết bị để mở AM Finance.")
            }

            if controller.settings.isEnabled {
                Section {
                    Picker("Khoá lại sau", selection: delayBinding) {
                        ForEach(AppLockDelay.allCases, id: \.self) { delay in
                            Text(delay.title).tag(delay)
                        }
                    }
                } header: {
                    Text("Tự động khoá")
                } footer: {
                    Text("Thời gian ứng dụng ở chế độ nền trước khi yêu cầu mở khoá lại.")
                }

                Section {
                    Toggle("Ẩn nội dung khi đa nhiệm", isOn: hideBinding)
                } footer: {
                    Text("Che nội dung ứng dụng trong màn hình chuyển đổi giữa các app.")
                }
            }
        }
        .navigationTitle("Khoá ứng dụng")
        .alert("Không thể bật khoá", isPresented: $showUnavailableAlert) {
            Button("Đã hiểu", role: .cancel) {}
        } message: {
            Text("Thiết bị chưa thiết lập Face ID hoặc mã khoá. Hãy mở Cài đặt của hệ thống để thiết lập, sau đó thử lại.")
        }
    }

    // MARK: - Bindings

    /// Enabling runs the authenticate-then-persist flow; the toggle only
    /// stays on when the controller reports `.enabled`.
    private var enabledBinding: Binding<Bool> {
        Binding(
            get: { controller.settings.isEnabled },
            set: { newValue in
                guard !isEnabling else { return }
                isEnabling = true
                Task {
                    let outcome = await controller.setEnabled(newValue)
                    isEnabling = false
                    if outcome == .unavailable {
                        showUnavailableAlert = true
                    }
                }
            }
        )
    }

    private var delayBinding: Binding<AppLockDelay> {
        Binding(
            get: { controller.settings.delay },
            set: { controller.setDelay($0) }
        )
    }

    private var hideBinding: Binding<Bool> {
        Binding(
            get: { controller.settings.hideInAppSwitcher },
            set: { controller.setHideInAppSwitcher($0) }
        )
    }
}

#if DEBUG
#Preview {
    let container = try! AppModelContainer.make(inMemory: true)
    try! SeedData.seedIfNeeded(context: ModelContext(container))
    let controller = AppLockController(
        store: AppLockSettingsStore(
            defaults: UserDefaults(suiteName: "AppLockSettingsView.preview")!),
        authenticator: AppLockPreviewAuthenticator())
    return NavigationStack {
        AppLockSettingsView(controller: controller)
    }
    .modelContainer(container)
}
#endif
