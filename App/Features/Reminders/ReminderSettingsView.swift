import SwiftUI
import SwiftData
import UIKit

/// Màn hình cài đặt nhắc nhở — trạng thái quyền thông báo, các loại lời
/// nhắc, ngày/giờ gửi, xem trước lời nhắc sắp tới và nút gửi thử. Pushed
/// inside an existing NavigationStack — it must not create one.
struct ReminderSettingsView: View {
    @Environment(\.modelContext) private var context

    private let scheduler: ReminderScheduler
    private let settingsStore: ReminderSettingsStore

    @State private var settings: ReminderSettings
    @State private var authorization: ReminderAuthorizationStatus = .notDetermined
    @State private var planned: [ReminderPlannedNotification] = []
    @State private var isSending = false
    @State private var notice: String?

    /// How many rows of the plan the preview lists before collapsing to
    /// "… và n lời nhắc khác".
    private static let previewLimit = 5

    init(
        scheduler: ReminderScheduler = ReminderScheduler(),
        settingsStore: ReminderSettingsStore = ReminderSettingsStore()
    ) {
        self.scheduler = scheduler
        self.settingsStore = settingsStore
        _settings = State(initialValue: settingsStore.load().sanitized())
    }

    var body: some View {
        Form {
            permissionSection
            kindsSection
            timingSection
            bankSyncSection
            previewSection
            testSection
        }
        .navigationTitle("Nhắc nhở")
        .task { await reload() }
        .onChange(of: settings) { _, newValue in
            settingsStore.save(newValue)
            Task {
                // Enabling for the first time asks for permission right away.
                if newValue.isEnabled, authorization == .notDetermined {
                    _ = try? await scheduler.requestAuthorization()
                }
                await reload()
            }
        }
        .onReceive(NotificationCenter.default.publisher(
            for: UIApplication.willEnterForegroundNotification
        )) { _ in
            Task { authorization = await scheduler.authorizationStatus() }
        }
    }

    // MARK: - Permission

    private var permissionSection: some View {
        Section {
            LabeledContent("Quyền thông báo", value: authorizationText)
            switch authorization {
            case .notDetermined:
                Button {
                    Task { await requestPermission() }
                } label: {
                    Label("Cho phép thông báo", systemImage: "bell.badge.fill")
                }
            case .denied:
                Button {
                    openSystemSettings()
                } label: {
                    Label("Mở Cài đặt hệ thống", systemImage: "gear")
                }
            default:
                EmptyView()
            }
        } header: {
            Text("Thông báo")
        } footer: {
            if authorization == .denied {
                Text("Thông báo đang tắt — vào Cài đặt > Thông báo > AM Finance để bật lại.")
            } else {
                Text("Lời nhắc đến qua thông báo của máy, không cần mạng.")
            }
        }
    }

    private var authorizationText: String {
        switch authorization {
        case .notDetermined: return "Chưa yêu cầu"
        case .denied: return "Đã tắt"
        case .authorized: return "Đã cấp"
        case .provisional, .ephemeral: return "Đã cấp (tạm thời)"
        }
    }

    // MARK: - Kinds

    private var kindsSection: some View {
        Section {
            Toggle("Bật nhắc nhở", isOn: $settings.isEnabled)
            Group {
                Toggle("Đến hạn thẻ tín dụng", isOn: $settings.creditCardDue)
                Toggle("Kỳ trả khoản vay", isOn: $settings.loanInstallment)
                Toggle("Giao dịch lặp lại (chỉ nhắc)", isOn: $settings.recurringItems)
                Toggle("Cảnh báo ngân sách", isOn: $settings.budgetWarnings)
                Toggle("Thu tiền phòng", isOn: $settings.rentCollection)
            }
            .disabled(!settings.isEnabled)
        } header: {
            Text("Lời nhắc")
        } footer: {
            Text("Giao dịch lặp lại ở chế độ \"chỉ nhắc\" sẽ báo đúng ngày đến hạn.")
        }
    }

    // MARK: - Timing

    private var timingSection: some View {
        Section {
            ForEach(ReminderSettings.dayChoices, id: \.self) { offset in
                Toggle(dayLabel(offset), isOn: dayBinding(offset))
            }
            Picker("Giờ gửi", selection: $settings.notificationHour) {
                ForEach(0..<24, id: \.self) { hour in
                    Text(String(format: "%02d:00", hour)).tag(hour)
                }
            }
        } header: {
            Text("Lịch nhắc")
        } footer: {
            Text("Áp dụng cho thẻ tín dụng và khoản vay.")
        }
        .disabled(!settings.isEnabled)
    }

    private func dayLabel(_ offset: Int) -> String {
        offset == 0 ? "Đúng ngày đến hạn" : "Trước \(offset) ngày"
    }

    private func dayBinding(_ offset: Int) -> Binding<Bool> {
        Binding(
            get: { settings.daysBeforeDue.contains(offset) },
            set: { on in
                var days = Set(settings.daysBeforeDue)
                if on { days.insert(offset) } else { days.remove(offset) }
                settings.daysBeforeDue = days.sorted(by: >)
            }
        )
    }

    // MARK: - Bank sync

    /// Notifications for bank transactions the background refresh syncs
    /// in — independent of the reminder master switch.
    private var bankSyncSection: some View {
        Section {
            Toggle("Thông báo giao dịch ngân hàng mới",
                   isOn: $settings.bankTransactions)
        } header: {
            Text("Đồng bộ ngân hàng")
        } footer: {
            Text("iOS tự quyết định thời điểm làm mới trong nền nên thông báo có thể đến trễ. Cần bật \"Làm mới ứng dụng trong nền\" cho AM Finance trong Cài đặt hệ thống.")
        }
    }

    // MARK: - Preview

    private var previewSection: some View {
        Section {
            if planned.isEmpty {
                Text("Chưa có lời nhắc nào được hẹn.")
                    .foregroundStyle(.secondary)
            } else {
                ForEach(planned.prefix(Self.previewLimit)) { item in
                    VStack(alignment: .leading, spacing: 2) {
                        Text(item.title)
                            .font(.subheadline.weight(.medium))
                        Text(item.body)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        Text(fireText(item.fireDate))
                            .font(.caption2)
                            .foregroundStyle(.tertiary)
                    }
                }
                if planned.count > Self.previewLimit {
                    Text("… và \(planned.count - Self.previewLimit) lời nhắc khác")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
        } header: {
            Text("Sắp nhắc")
        } footer: {
            Text("Tối đa \(ReminderPlanner.maximumPlanned) thông báo được hẹn trước.")
        }
    }

    /// "22/11 lúc 09:00" — when the notification fires.
    private func fireText(_ date: Date) -> String {
        "\(AppDateFormat.shortDate(date, calendar: scheduler.calendar)) " +
        "lúc \(AppDateFormat.time(date, calendar: scheduler.calendar))"
    }

    // MARK: - Test

    private var testSection: some View {
        Section {
            Button {
                Task { await sendTest() }
            } label: {
                Label("Gửi thử thông báo", systemImage: "paperplane.fill")
            }
            .disabled(isSending || !authorization.canDeliver)
            if let notice {
                Text(notice)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        } footer: {
            Text("Thông báo thử đến sau 5 giây — thu nhỏ ứng dụng để thấy nó.")
        }
    }

    // MARK: - Actions

    private func reload() async {
        authorization = await scheduler.authorizationStatus()
        planned = await scheduler.reschedule(context: context)
    }

    private func requestPermission() async {
        _ = try? await scheduler.requestAuthorization()
        await reload()
    }

    private func sendTest() async {
        isSending = true
        defer { isSending = false }
        do {
            try await scheduler.sendTestNotification()
            notice = "Đã hẹn — thông báo thử sẽ đến sau 5 giây."
        } catch {
            notice = "Không gửi được thông báo thử."
        }
    }

    private func openSystemSettings() {
        guard let url = URL(string: UIApplication.openSettingsURLString)
        else { return }
        UIApplication.shared.open(url)
    }
}

#Preview {
    let container = try! AppModelContainer.make(inMemory: true)
    let context = ModelContext(container)
    try! SeedData.seedIfNeeded(context: context)
    let calendar = AppCalendar.vietnam

    // A card with a real statement due so the preview has a debt reminder.
    let card = Account(
        name: "Thẻ VPBank", kind: .creditCard, colorHex: "FF9500", sortOrder: 1)
    card.creditLimit = 30_000_000
    card.statementDay = 20
    card.graceDays = 15
    context.insert(card)
    let closed = card.creditCardCycleConfig!
        .lastClosedCycle(asOf: .now, calendar: calendar)
    context.insert(LedgerTransaction(
        kind: .expense, amount: 3_200_000,
        date: calendar.date(byAdding: .day, value: -5, to: closed.end)!,
        account: card))

    // A remind-only recurring rule coming due.
    let cash = try! context.fetch(FetchDescriptor<Account>()).first!
    context.insert(RecurringRule(
        title: "Trả tiền thuê", kind: .expense, amount: 7_000_000,
        account: cash,
        frequency: .monthly,
        startDate: calendar.date(byAdding: .day, value: 2, to: .now)!,
        autoCreate: false))

    // A budget already at warning.
    let food = try! context.fetch(FetchDescriptor<LedgerCategory>())
        .first { $0.name == "Ăn uống" }!
    context.insert(Budget(monthlyLimit: 1_000_000, category: food))
    context.insert(LedgerTransaction(
        kind: .expense, amount: 900_000, date: .now,
        account: cash, category: food))

    return NavigationStack {
        ReminderSettingsView()
    }
    .modelContainer(container)
}
