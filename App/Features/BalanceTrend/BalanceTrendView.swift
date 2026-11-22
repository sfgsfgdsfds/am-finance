import SwiftUI
import SwiftData
import Charts
import FinanceCore

/// Compact đồng labels ("1,2 tr", "500 k") on the chart's value axis.
struct BalanceTrendAxisAmountFormat: FormatStyle {
    func format(_ value: Double) -> String {
        VND.compact(Int64(value.rounded()))
    }
}

/// Date labels for the chart and annotations, rendered in the app calendar.
enum BalanceTrendDateLabel {
    /// Axis label matching the span: "22/11" inside a quarter, "11/2026"
    /// when the range reaches across months and years.
    static func axis(_ date: Date, range: BalanceTrendRange) -> String {
        switch range {
        case .days30, .days90:
            return AppDateFormat.shortDate(date)
        case .year, .all:
            return format("MM/yyyy", date)
        }
    }

    /// "dd/MM/yyyy" for the drag-to-inspect bubble and extreme dates.
    static func full(_ date: Date) -> String {
        format("dd/MM/yyyy", date)
    }

    private static func format(_ format: String, _ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.calendar = AppCalendar.vietnam
        formatter.timeZone = AppCalendar.vietnam.timeZone
        formatter.locale = AppCalendar.vietnam.locale
        formatter.dateFormat = format
        return formatter.string(from: date)
    }
}

/// Balance history of one account: a line/area chart of the daily closing
/// balance (or, on liabilities, the debt drawn as a positive "Dư nợ"), a
/// range picker, a summary card for the range, and a toolbar action opening
/// `BalanceTrendAnchorSheet` to set the real balance. Pushed inside an
/// existing `NavigationStack` — it does not create one.
struct BalanceTrendView: View {
    let account: Account

    @State private var range: BalanceTrendRange = .days30
    @State private var isAnchoring = false
    @State private var inspectedDate: Date?

    init(account: Account) {
        self.account = account
    }

    private var isLiability: Bool { account.kind.isLiability }
    private var chartColor: Color { Color(hex: account.colorHex) }

    private var series: BalanceTrendSeries? {
        try? BalanceTrendSeries.build(
            entries: account.balanceTrendEntries,
            openingBalance: account.openingBalance,
            range: range,
            now: .now,
            isLiability: isLiability,
            calendar: AppCalendar.vietnam
        )
    }

    var body: some View {
        List {
            Section {
                header
                    .frame(maxWidth: .infinity)
                    .listRowBackground(Color.clear)
            }

            Section {
                Picker("Khoảng thời gian", selection: $range) {
                    ForEach(BalanceTrendRange.allCases) { option in
                        Text(option.displayName).tag(option)
                    }
                }
                .pickerStyle(.segmented)
                .listRowInsets(EdgeInsets(top: 6, leading: 0, bottom: 6, trailing: 0))
            }

            Section {
                if let series {
                    chart(series)
                        .frame(height: 220)
                        .listRowInsets(EdgeInsets(top: 8, leading: 0, bottom: 4, trailing: 0))
                } else {
                    Text("Không thể tính được lịch sử số dư.")
                        .foregroundStyle(.secondary)
                }
            } header: {
                Text(isLiability ? "Dư nợ theo thời gian" : "Số dư theo thời gian")
            }

            if let series {
                summarySection(series)
            }
        }
        .listStyle(.insetGrouped)
        .navigationTitle(isLiability ? "Dư nợ" : "Số dư")
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button("Đặt số dư thực tế") { isAnchoring = true }
            }
        }
        .sheet(isPresented: $isAnchoring) {
            BalanceTrendAnchorSheet(account: account)
        }
    }

    // MARK: - Header

    private var header: some View {
        VStack(spacing: 8) {
            IconBadge(symbol: account.icon, colorHex: account.colorHex, size: 56)
            Text(account.name)
                .font(.subheadline)
                .foregroundStyle(.secondary)
            AmountText(amount: BalanceTrendSeries.displayed(account.balance, isLiability: isLiability))
                .font(.title.bold())
            Text(isLiability ? "Dư nợ hiện tại" : "Số dư hiện tại")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    // MARK: - Chart

    /// Daily point nearest to the finger — the drag-to-inspect target.
    private var inspectedPoint: BalanceHistoryPoint? {
        guard let inspectedDate, let points = series?.dailyPoints, !points.isEmpty else {
            return nil
        }
        return points.min {
            abs($0.date.timeIntervalSince(inspectedDate)) < abs($1.date.timeIntervalSince(inspectedDate))
        }
    }

    private func chart(_ series: BalanceTrendSeries) -> some View {
        Chart {
            ForEach(series.chartPoints, id: \.date) { point in
                LineMark(
                    x: .value("Ngày", point.date, unit: .day),
                    y: .value("Số dư", Double(point.balance))
                )
                .foregroundStyle(chartColor)
                .interpolationMethod(.catmullRom)
                AreaMark(
                    x: .value("Ngày", point.date, unit: .day),
                    y: .value("Số dư", Double(point.balance))
                )
                .foregroundStyle(
                    .linearGradient(
                        colors: [chartColor.opacity(0.25), chartColor.opacity(0.02)],
                        startPoint: .top,
                        endPoint: .bottom
                    )
                )
                .interpolationMethod(.catmullRom)
            }
            if let inspected = inspectedPoint {
                RuleMark(x: .value("Ngày", inspected.date))
                    .foregroundStyle(.secondary)
                    .lineStyle(StrokeStyle(lineWidth: 1, dash: [4]))
                    .annotation(
                        position: .top,
                        spacing: 4,
                        overflowResolution: .init(x: .fit(to: .chart), y: .disabled)
                    ) {
                        inspectionBubble(inspected)
                    }
                PointMark(
                    x: .value("Ngày", inspected.date),
                    y: .value("Số dư", Double(inspected.balance))
                )
                .foregroundStyle(chartColor)
            }
        }
        .chartLegend(.hidden)
        .chartXAxis {
            AxisMarks(values: .automatic(desiredCount: 4)) { value in
                AxisGridLine()
                AxisValueLabel {
                    if let date = value.as(Date.self) {
                        Text(BalanceTrendDateLabel.axis(date, range: range))
                    }
                }
            }
        }
        .chartYAxis {
            AxisMarks { _ in
                AxisGridLine()
                AxisValueLabel(format: BalanceTrendAxisAmountFormat())
            }
        }
        .chartOverlay { proxy in
            GeometryReader { geometry in
                Rectangle()
                    .fill(.clear)
                    .contentShape(Rectangle())
                    .gesture(
                        DragGesture(minimumDistance: 0)
                            .onChanged { value in
                                let plotOrigin = geometry[proxy.plotAreaFrame].origin
                                if let date = proxy.value(
                                    atX: value.location.x - plotOrigin.x,
                                    as: Date.self
                                ) {
                                    inspectedDate = date
                                }
                            }
                            .onEnded { _ in inspectedDate = nil }
                    )
            }
        }
        .accessibilityLabel(
            isLiability ? "Biểu đồ dư nợ theo thời gian" : "Biểu đồ số dư theo thời gian"
        )
    }

    private func inspectionBubble(_ point: BalanceHistoryPoint) -> some View {
        VStack(spacing: 1) {
            Text(BalanceTrendDateLabel.full(point.date))
                .font(.caption2)
                .foregroundStyle(.secondary)
            Text(VND.format(point.balance))
                .font(.caption.weight(.semibold))
                .monospacedDigit()
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 8))
    }

    // MARK: - Summary

    private func summarySection(_ series: BalanceTrendSeries) -> some View {
        Section {
            LabeledContent(
                isLiability ? "Dư nợ đầu kỳ" : "Số dư đầu kỳ",
                value: VND.format(series.opening)
            )
            LabeledContent(
                isLiability ? "Dư nợ cuối kỳ" : "Số dư cuối kỳ",
                value: VND.format(series.closing)
            )
            LabeledContent {
                AmountText(amount: series.totalIn, kind: .income)
            } label: {
                Text("Tổng vào")
            }
            LabeledContent {
                AmountText(amount: series.totalOut, kind: .expense)
            } label: {
                Text("Tổng ra")
            }
            LabeledContent {
                AmountText(amount: series.netChange)
            } label: {
                Text("Thay đổi ròng")
            }
            LabeledContent {
                extremeValue(series.highest)
            } label: {
                Text(isLiability ? "Dư nợ cao nhất" : "Số dư cao nhất")
            }
            LabeledContent {
                extremeValue(series.lowest)
            } label: {
                Text(isLiability ? "Dư nợ thấp nhất" : "Số dư thấp nhất")
            }
        } header: {
            Text("Tóm tắt")
        }
    }

    /// "1.250.000 ₫" over "22/11/2026" — an extreme and the day it happened.
    private func extremeValue(_ point: BalanceHistoryPoint) -> some View {
        VStack(alignment: .trailing, spacing: 1) {
            Text(VND.format(point.balance))
                .monospacedDigit()
            Text(BalanceTrendDateLabel.full(point.date))
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }
}

#Preview("Tài khoản ngân hàng") {
    let container = try! AppModelContainer.make(inMemory: true)
    let context = ModelContext(container)
    let calendar = AppCalendar.vietnam
    let now = Date.now
    let account = Account(
        name: "Ngân hàng", kind: .bank,
        openingBalance: 8_000_000, colorHex: "0A84FF"
    )
    context.insert(account)
    for (daysAgo, kind, amount, note) in [
        (45, TransactionKind.income, 15_000_000, "Lương"),
        (32, TransactionKind.expense, 4_500_000, "Tiền nhà"),
        (20, TransactionKind.expense, 1_200_000, "Hoá đơn"),
        (9, TransactionKind.income, 15_000_000, "Lương"),
        (3, TransactionKind.expense, 2_300_000, "Mua sắm"),
    ] as [(Int, TransactionKind, Int64, String)] {
        let date = calendar.date(byAdding: .day, value: -daysAgo, to: now) ?? now
        context.insert(LedgerTransaction(kind: kind, amount: amount, date: date, note: note, account: account))
    }
    return NavigationStack {
        BalanceTrendView(account: account)
    }
    .modelContainer(container)
}

#Preview("Thẻ tín dụng") {
    let container = try! AppModelContainer.make(inMemory: true)
    let context = ModelContext(container)
    let calendar = AppCalendar.vietnam
    let now = Date.now
    let card = Account(
        name: "Thẻ Visa", kind: .creditCard,
        openingBalance: -2_000_000, colorHex: "FF9500"
    )
    context.insert(card)
    let bank = Account(name: "Ngân hàng", kind: .bank, colorHex: "0A84FF")
    context.insert(bank)
    for (daysAgo, amount) in [(25, Int64(3_100_000)), (12, Int64(850_000))] {
        let date = calendar.date(byAdding: .day, value: -daysAgo, to: now) ?? now
        context.insert(LedgerTransaction(kind: .expense, amount: amount, date: date, note: "Chi thẻ", account: card))
    }
    context.insert(LedgerTransaction(
        kind: .transfer, amount: 1_500_000,
        date: calendar.date(byAdding: .day, value: -6, to: now) ?? now,
        note: "Trả thẻ", account: bank, toAccount: card
    ))
    return NavigationStack {
        BalanceTrendView(account: card)
    }
    .modelContainer(container)
}
