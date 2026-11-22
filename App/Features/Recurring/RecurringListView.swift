import SwiftUI
import SwiftData
import FinanceCore

/// Recurring transactions: subscriptions, rent, salaries and autopay
/// rules. The header card shows the expected Thu/Chi of the next
/// `windowDays` days, "Sắp tới" lists every occurrence inside that window
/// in date order, then come the live rules sorted by next occurrence and
/// a collapsed "Tạm dừng & kết thúc" section. Pushed inside an existing
/// NavigationStack — it must not create its own.
struct RecurringListView: View {
    @Environment(\.modelContext) private var context
    @Query(sort: \RecurringRule.startDate) private var rules: [RecurringRule]

    /// Days the header and "Sắp tới" look ahead.
    private static let windowDays = 30

    @State private var isCreating = false
    @State private var editing: RecurringRule?
    @State private var pendingDelete: RecurringRule?
    @State private var showsInactive = false

    init() {}

    private var calendar: Calendar { AppCalendar.vietnam }

    private var inputs: [RecurringUpcoming.Input] {
        rules.map { RecurringUpcoming.Input(rule: $0) }
    }

    private var window: ClosedRange<Date> {
        RecurringUpcoming.window(days: Self.windowDays, now: .now, calendar: calendar)
    }

    private var nextDates: [UUID: Date] {
        RecurringUpcoming.nextOccurrences(of: inputs, asOf: .now, calendar: calendar)
    }

    /// Active rules with occurrences still ahead, soonest first.
    private var liveInputs: [RecurringUpcoming.Input] {
        inputs
            .filter { $0.isActive && nextDates[$0.id] != nil }
            .sorted {
                (nextDates[$0.id] ?? .distantFuture, $0.title, $0.id.uuidString)
                    < (nextDates[$1.id] ?? .distantFuture, $1.title, $1.id.uuidString)
            }
    }

    /// Paused rules plus rules whose schedule ran out — the collapsed section.
    private var inactiveInputs: [RecurringUpcoming.Input] {
        inputs
            .filter { !$0.isActive || nextDates[$0.id] == nil }
            .sorted { ($0.title, $0.id.uuidString) < ($1.title, $1.id.uuidString) }
    }

    private var upcoming: [RecurringUpcoming.Occurrence] {
        RecurringUpcoming.occurrences(
            in: inputs, window: window, now: .now, calendar: calendar
        )
    }

    private var totals: RecurringUpcoming.Totals {
        RecurringUpcoming.totals(
            in: inputs, window: window, now: .now, calendar: calendar
        )
    }

    var body: some View {
        Group {
            if rules.isEmpty {
                EmptyStateView(
                    symbol: "repeat",
                    title: "Chưa có quy tắc lặp lại",
                    message: "Tạo quy tắc cho giao dịch định kỳ — tiền thuê, lương, gói đăng ký — để tự động ghi hoặc nhắc bạn.",
                    actionTitle: "Thêm quy tắc",
                    action: { isCreating = true }
                )
            } else {
                list
            }
        }
        .navigationTitle("Giao dịch lặp lại")
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button {
                    isCreating = true
                } label: {
                    Image(systemName: "plus")
                }
                .accessibilityLabel("Thêm quy tắc lặp lại")
            }
        }
        .sheet(isPresented: $isCreating) {
            RecurringEditView()
        }
        .sheet(item: $editing) { rule in
            RecurringEditView(rule: rule)
        }
        .confirmationDialog(
            "Xoá quy tắc lặp lại?",
            isPresented: deleteDialogPresented,
            titleVisibility: .visible
        ) {
            Button("Xoá quy tắc", role: .destructive) {
                if let pendingDelete { delete(pendingDelete) }
            }
            Button("Huỷ", role: .cancel) {}
        } message: {
            Text("Các giao dịch đã tạo từ quy tắc này vẫn được giữ lại.")
        }
    }

    private var deleteDialogPresented: Binding<Bool> {
        Binding(
            get: { pendingDelete != nil },
            set: { if !$0 { pendingDelete = nil } }
        )
    }

    // MARK: - List

    private var list: some View {
        List {
            Section {
                headerCard
                    .listRowInsets(EdgeInsets(top: 8, leading: 4, bottom: 8, trailing: 4))
                    .listRowBackground(Color.clear)
            }

            if !upcoming.isEmpty {
                Section("Sắp tới") {
                    ForEach(upcoming) { occurrence in
                        upcomingRow(occurrence)
                    }
                }
            }

            if !liveInputs.isEmpty {
                Section("Đang hoạt động") {
                    ForEach(liveInputs, id: \.id) { input in
                        if let rule = rules.first(where: { $0.id == input.id }) {
                            ruleRow(rule)
                        }
                    }
                }
            }

            if !inactiveInputs.isEmpty {
                Section {
                    DisclosureGroup(isExpanded: $showsInactive) {
                        ForEach(inactiveInputs, id: \.id) { input in
                            if let rule = rules.first(where: { $0.id == input.id }) {
                                ruleRow(rule)
                                    .foregroundStyle(.secondary)
                            }
                        }
                    } label: {
                        HStack {
                            Text("Tạm dừng & kết thúc")
                            Spacer()
                            Text("\(inactiveInputs.count)")
                                .foregroundStyle(.secondary)
                                .monospacedDigit()
                        }
                    }
                }
            }
        }
        .listStyle(.insetGrouped)
        // Keeps the last row clear of RootTabView's floating "+".
        .contentMargins(.bottom, 40, for: .scrollContent)
    }

    // MARK: - Header card

    private var headerCard: some View {
        VStack(spacing: 10) {
            Text("Dự kiến \(Self.windowDays) ngày tới")
                .font(.subheadline)
                .foregroundStyle(.secondary)
            AmountText(amount: totals.net)
                .font(.title.bold())
            HStack(spacing: 0) {
                headerColumn("Thu", amount: totals.income, kind: .income)
                Divider().frame(height: 32)
                headerColumn("Chi", amount: totals.expense, kind: .expense)
            }
        }
        .padding(.vertical, 16)
        .padding(.horizontal, 12)
        .frame(maxWidth: .infinity)
        .background(
            Color(.secondarySystemGroupedBackground),
            in: RoundedRectangle(cornerRadius: 16)
        )
        .accessibilityElement(children: .combine)
    }

    private func headerColumn(
        _ title: String, amount: Int64, kind: TransactionKind
    ) -> some View {
        VStack(spacing: 2) {
            Text(title)
                .font(.caption)
                .foregroundStyle(.secondary)
            AmountText(amount: amount, kind: kind)
                .font(.headline)
        }
        .frame(maxWidth: .infinity)
    }

    // MARK: - Upcoming rows

    private func upcomingRow(_ occurrence: RecurringUpcoming.Occurrence) -> some View {
        Button {
            if let rule = rules.first(where: { $0.id == occurrence.ruleID }) {
                editing = rule
            }
        } label: {
            HStack(spacing: 12) {
                IconBadge(
                    symbol: badgeSymbol(kind: occurrence.kind, icon: occurrence.icon),
                    colorHex: badgeColorHex(kind: occurrence.kind, colorHex: occurrence.colorHex),
                    size: 32
                )
                VStack(alignment: .leading, spacing: 2) {
                    Text(occurrence.title)
                        .font(.subheadline.weight(.medium))
                        .lineLimit(1)
                    Text("\(AppDateFormat.shortDate(occurrence.date)) · \(occurrence.statusText)")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                AmountText(amount: occurrence.amount, kind: occurrence.kind)
                    .font(.subheadline.weight(.medium))
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    // MARK: - Rule rows

    private func ruleRow(_ rule: RecurringRule) -> some View {
        Button {
            editing = rule
        } label: {
            HStack(spacing: 12) {
                IconBadge(
                    symbol: badgeSymbol(kind: rule.kind, icon: rule.category?.icon ?? ""),
                    colorHex: badgeColorHex(kind: rule.kind, colorHex: rule.category?.colorHex ?? ""),
                    size: 36
                )
                VStack(alignment: .leading, spacing: 3) {
                    HStack(spacing: 6) {
                        Text(rule.title)
                            .font(.subheadline.weight(.medium))
                            .lineLimit(1)
                        modeTag(rule)
                    }
                    Text(subtitle(for: rule))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                Spacer()
                AmountText(amount: rule.amount, kind: rule.kind)
                    .font(.subheadline.weight(.medium))
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .swipeActions(edge: .trailing, allowsFullSwipe: false) {
            Button(role: .destructive) {
                pendingDelete = rule
            } label: {
                Label("Xoá", systemImage: "trash")
            }
            Button {
                togglePause(rule)
            } label: {
                Label(
                    rule.isActive ? "Tạm dừng" : "Tiếp tục",
                    systemImage: rule.isActive ? "pause.fill" : "play.fill"
                )
            }
            .tint(.orange)
        }
    }

    /// "Tự tạo" / "Chỉ nhắc" — whether the rule posts transactions itself
    /// or only reminds.
    private func modeTag(_ rule: RecurringRule) -> some View {
        Text(rule.autoCreate ? "Tự tạo" : "Chỉ nhắc")
            .font(.caption2.weight(.medium))
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .foregroundStyle(rule.autoCreate ? Color.accentColor : .secondary)
            .background(
                rule.autoCreate
                    ? Color.accentColor.opacity(0.12)
                    : Color(.tertiarySystemFill),
                in: Capsule()
            )
    }

    /// "Hằng tháng, ngày 5 · 05/12 (Còn 13 ngày)" for live rules;
    /// "Tạm dừng · …" or "Đã kết thúc · …" for the collapsed section.
    private func subtitle(for rule: RecurringRule) -> String {
        let summary = rule.recurrenceRule(calendar: calendar)?
            .summary(calendar: calendar) ?? rule.frequency.displayName
        guard rule.isActive else { return "Tạm dừng · \(summary)" }
        guard let next = nextDates[rule.id] else { return "Đã kết thúc · \(summary)" }
        let days = calendar.dateComponents(
            [.day],
            from: calendar.startOfDay(for: .now),
            to: calendar.startOfDay(for: next)
        ).day ?? 0
        let countdown = CreditCardOverview.countdownText(days: days)
        return "\(summary) · \(AppDateFormat.shortDate(next)) (\(countdown))"
    }

    /// Category icon when there is one; otherwise a per-kind default so a
    /// transfer or uncategorised rule still has a meaningful badge.
    private func badgeSymbol(kind: TransactionKind, icon: String) -> String {
        guard icon.isEmpty else { return icon }
        switch kind {
        case .transfer: return "arrow.left.arrow.right"
        case .income: return "arrow.down.left"
        case .expense: return "arrow.up.right"
        }
    }

    private func badgeColorHex(kind: TransactionKind, colorHex: String) -> String {
        guard colorHex.isEmpty else { return colorHex }
        switch kind {
        case .transfer: return "64748B"   // AppTheme.transfer
        case .income: return "34C759"     // AppTheme.income
        case .expense: return "FF3B30"    // AppTheme.expense
        }
    }

    private func togglePause(_ rule: RecurringRule) {
        rule.isActive.toggle()
        try? context.save()
    }

    private func delete(_ rule: RecurringRule) {
        context.delete(rule)
        try? context.save()
        pendingDelete = nil
    }
}

#Preview("Quy tắc lặp lại") {
    let container = try! AppModelContainer.make(inMemory: true)
    let context = ModelContext(container)
    try! SeedData.seedIfNeeded(context: context)
    let cash = try! context.fetch(FetchDescriptor<Account>()).first!
    let bank = Account(
        name: "Ngân hàng", kind: .bank,
        openingBalance: 25_000_000, colorHex: "0A84FF", sortOrder: 1
    )
    context.insert(bank)
    let categories = try! context.fetch(FetchDescriptor<LedgerCategory>())
    let business = try! context.fetch(FetchDescriptor<Business>()).first!
    let calendar = AppCalendar.vietnam
    let tools = categories.first { $0.name == "Công cụ & phần mềm" }
    let rent = categories.first { $0.name == "Tiền thuê phòng" }
    context.insert(RecurringRule(
        title: "ChatGPT Plus", kind: .expense, amount: 500_000,
        account: cash, category: tools,
        frequency: .monthly,
        startDate: calendar.date(byAdding: .day, value: -20, to: .now)!
    ))
    context.insert(RecurringRule(
        title: "Tiền thuê phòng", kind: .income, amount: 4_500_000,
        account: cash, category: rent, business: business,
        frequency: .monthly,
        startDate: calendar.date(byAdding: .day, value: 5, to: .now)!
    ))
    context.insert(RecurringRule(
        title: "Trả nợ thẻ", kind: .transfer, amount: 2_000_000,
        account: bank, toAccount: cash,
        frequency: .monthly,
        startDate: calendar.date(byAdding: .day, value: 10, to: .now)!,
        autoCreate: false
    ))
    context.insert(RecurringRule(
        title: "Gói VPN hết hạn", kind: .expense, amount: 200_000,
        account: cash, category: tools,
        frequency: .monthly,
        startDate: calendar.date(byAdding: .year, value: -1, to: .now)!,
        endDate: calendar.date(byAdding: .day, value: -10, to: .now)!
    ))
    context.insert(RecurringRule(
        title: "Báo tuần (tạm dừng)", kind: .expense, amount: 50_000,
        account: cash, category: categories.first,
        frequency: .weekly,
        startDate: calendar.date(byAdding: .day, value: -3, to: .now)!,
        isActive: false
    ))
    return NavigationStack {
        RecurringListView()
    }
    .modelContainer(container)
}

#Preview("Trống") {
    let container = try! AppModelContainer.make(inMemory: true)
    try! SeedData.seedIfNeeded(context: ModelContext(container))
    return NavigationStack {
        RecurringListView()
    }
    .modelContainer(container)
}
