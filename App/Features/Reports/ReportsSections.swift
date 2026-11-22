import SwiftUI
import Charts
import FinanceCore

/// Compact đồng labels ("1,2 tr", "500 k") on chart value axes.
struct ReportsAxisAmountFormat: FormatStyle {
    func format(_ value: Double) -> String {
        VND.compact(Int64(value.rounded()))
    }
}

/// "Thu / Chi / Chênh lệch" for the period with the change versus the
/// equal-length previous period underneath each figure. The percent is
/// hidden when the previous value is 0.
struct ReportsSummarySection: View {
    let comparison: ReportComparison

    var body: some View {
        Section {
            HStack(alignment: .top, spacing: 8) {
                cell("Thu", amount: comparison.current.income,
                     change: comparison.income, kind: .income)
                cell("Chi", amount: comparison.current.expense,
                     change: comparison.expense, kind: .expense)
                cell("Chênh lệch", amount: comparison.current.net,
                     change: comparison.net, kind: nil)
            }
            .padding(.vertical, 4)
        } header: {
            Text("Tổng quan")
        }
    }

    private func cell(
        _ title: String, amount: Int64,
        change: ReportChange, kind: TransactionKind?
    ) -> some View {
        VStack(spacing: 4) {
            Text(title)
                .font(.caption)
                .foregroundStyle(.secondary)
            AmountText(amount: amount, kind: kind, compact: true)
                .font(.subheadline.weight(.semibold))
                .lineLimit(1)
                .minimumScaleFactor(0.4)
            changeLabel(change)
        }
        .frame(maxWidth: .infinity)
    }

    @ViewBuilder private func changeLabel(_ change: ReportChange) -> some View {
        if let percent = change.percent {
            HStack(spacing: 2) {
                Image(systemName: percent > 0
                      ? "arrow.up" : percent < 0 ? "arrow.down" : "minus")
                Text(abs(percent).formatted(.percent.precision(.fractionLength(0...1))))
            }
            .font(.caption2)
            .foregroundStyle(.secondary)
        } else {
            Text("—")
                .font(.caption2)
                .foregroundStyle(.tertiary)
        }
    }
}

/// Icon, name and count on the left; signed amount and share percent on the
/// right — one row under a category donut.
struct ReportsCategoryRowView: View {
    let slice: ReportsCategorySlice
    let kind: TransactionKind

    var body: some View {
        HStack(spacing: 12) {
            IconBadge(symbol: slice.icon, colorHex: slice.colorHex, size: 36)
            VStack(alignment: .leading, spacing: 2) {
                Text(slice.name)
                    .lineLimit(1)
                Text("\(slice.count) giao dịch")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer(minLength: 8)
            VStack(alignment: .trailing, spacing: 2) {
                AmountText(amount: slice.total, kind: kind)
                    .font(.subheadline.weight(.semibold))
                    .lineLimit(1)
                    .minimumScaleFactor(0.6)
                Text(slice.share.formatted(.percent.precision(.fractionLength(0...1))))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.vertical, 2)
    }
}

/// "Lãi lỗ kinh doanh" — a bar chart of profit per business plus rows with
/// revenue, cost, profit and margin. Rendered only for scope "Tất cả".
struct ReportsBusinessSection: View {
    let results: [ReportsBusinessSlice]

    var body: some View {
        Section {
            Chart {
                ForEach(results) { item in
                    BarMark(
                        x: .value("Lãi", Double(item.profit)),
                        y: .value("Kinh doanh", item.name)
                    )
                    .foregroundStyle(item.profit >= 0 ? AppTheme.income : AppTheme.expense)
                    .cornerRadius(4)
                }
            }
            .chartLegend(.hidden)
            .chartXAxis {
                AxisMarks { _ in
                    AxisGridLine()
                    AxisValueLabel(format: ReportsAxisAmountFormat())
                }
            }
            .frame(height: max(110, CGFloat(results.count) * 44))
            .listRowInsets(EdgeInsets(top: 8, leading: 0, bottom: 4, trailing: 0))

            ForEach(results) { item in
                HStack(spacing: 12) {
                    IconBadge(symbol: item.icon, colorHex: item.colorHex, size: 36)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(item.name)
                            .lineLimit(1)
                        Text("Thu \(VND.compact(item.revenue)) · Chi \(VND.compact(item.cost))")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                            .minimumScaleFactor(0.7)
                    }
                    Spacer(minLength: 8)
                    VStack(alignment: .trailing, spacing: 2) {
                        AmountText(amount: item.profit)
                            .font(.subheadline.weight(.semibold))
                            .lineLimit(1)
                            .minimumScaleFactor(0.6)
                        Text("Biên lãi \(item.margin.formatted(.percent.precision(.fractionLength(0...1))))")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
                .padding(.vertical, 2)
            }
        } header: {
            Text("Lãi lỗ kinh doanh")
        }
    }
}

/// "Xu hướng 12 tháng" — income and expense as side-by-side bars per month
/// with the net drawn as a line on top.
struct ReportsTrendSection: View {
    let points: [ReportMonthPoint]

    var body: some View {
        Section {
            VStack(alignment: .leading, spacing: 8) {
                Chart {
                    ForEach(points, id: \.monthStart) { point in
                        BarMark(
                            x: .value("Tháng", point.monthStart, unit: .month),
                            y: .value("Thu", Double(point.income))
                        )
                        .position(by: .value("Loại", "Thu"))
                        .foregroundStyle(AppTheme.income)
                        .cornerRadius(2)
                        BarMark(
                            x: .value("Tháng", point.monthStart, unit: .month),
                            y: .value("Chi", Double(point.expense))
                        )
                        .position(by: .value("Loại", "Chi"))
                        .foregroundStyle(AppTheme.expense)
                        .cornerRadius(2)
                    }
                    ForEach(points, id: \.monthStart) { point in
                        LineMark(
                            x: .value("Tháng", point.monthStart, unit: .month),
                            y: .value("Chênh lệch", Double(point.net))
                        )
                        .foregroundStyle(Color.accentColor)
                        .lineStyle(StrokeStyle(lineWidth: 2))
                        .symbol(.circle)
                        .symbolSize(24)
                    }
                }
                .chartLegend(.hidden)
                .chartXAxis {
                    AxisMarks { _ in
                        AxisValueLabel(format: .dateTime.month())
                    }
                }
                .chartYAxis {
                    AxisMarks { _ in
                        AxisGridLine()
                        AxisValueLabel(format: ReportsAxisAmountFormat())
                    }
                }
                .frame(height: 180)

                HStack(spacing: 16) {
                    legendChip("Thu", color: AppTheme.income)
                    legendChip("Chi", color: AppTheme.expense)
                    legendChip("Chênh lệch", color: .accentColor, line: true)
                }
            }
            .padding(.vertical, 4)
        } header: {
            Text("Xu hướng 12 tháng")
        }
    }

    private func legendChip(
        _ title: String, color: Color, line: Bool = false
    ) -> some View {
        HStack(spacing: 4) {
            if line {
                Capsule()
                    .fill(color)
                    .frame(width: 14, height: 2)
            } else {
                RoundedRectangle(cornerRadius: 2)
                    .fill(color)
                    .frame(width: 10, height: 10)
            }
            Text(title)
                .font(.caption2)
                .foregroundStyle(.secondary)
        }
        .accessibilityHidden(true)
    }
}

/// "Chi theo ngày" — the daily expense bars of the displayed month. Shown
/// only for month periods.
struct ReportsDailySection: View {
    let days: [ReportDayPoint]

    var body: some View {
        Section {
            Chart {
                ForEach(days, id: \.date) { day in
                    BarMark(
                        x: .value("Ngày", day.date, unit: .day),
                        y: .value("Chi", Double(day.expense))
                    )
                    .foregroundStyle(AppTheme.expense)
                    .cornerRadius(2)
                }
            }
            .chartLegend(.hidden)
            .chartXAxis {
                AxisMarks(values: .stride(by: .day, count: 5)) { _ in
                    AxisValueLabel(format: .dateTime.day())
                }
            }
            .chartYAxis {
                AxisMarks { _ in
                    AxisGridLine()
                    AxisValueLabel(format: ReportsAxisAmountFormat())
                }
            }
            .frame(height: 140)
            .listRowInsets(EdgeInsets(top: 8, leading: 0, bottom: 4, trailing: 0))
        } header: {
            Text("Chi theo ngày")
        }
    }
}
