import SwiftUI
import SwiftData
import Charts
import FinanceCore

/// Shared chrome for dashboard sections: a rounded card on the grouped
/// background with a bold title row — the same look as the accounts list's
/// net-worth card.
struct DashboardCard<Content: View>: View {
    let title: String?
    let showsChevron: Bool
    let content: Content

    init(_ title: String? = nil, showsChevron: Bool = false,
         @ViewBuilder content: () -> Content) {
        self.title = title
        self.showsChevron = showsChevron
        self.content = content()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            if title != nil || showsChevron {
                HStack {
                    if let title {
                        Text(title)
                            .font(.headline)
                    }
                    Spacer()
                    if showsChevron {
                        Image(systemName: "chevron.right")
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(.tertiary)
                    }
                }
            }
            content
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            Color(.secondarySystemGroupedBackground),
            in: RoundedRectangle(cornerRadius: 16)
        )
    }
}

// MARK: - Net worth

/// Card 1: total net worth plus the assets/liabilities split; tapping pushes
/// the full accounts list.
struct DashboardNetWorthCard: View {
    let netWorth: DashboardSnapshot.NetWorthSummary

    var body: some View {
        NavigationLink {
            AccountsListView()
        } label: {
            DashboardCard("Tài sản ròng", showsChevron: true) {
                VStack(spacing: 10) {
                    AmountText(amount: netWorth.total)
                        .font(.title.bold())
                        .frame(maxWidth: .infinity)
                    HStack(spacing: 0) {
                        column(title: "Tài sản", amount: netWorth.assets)
                        Divider().frame(height: 32)
                        column(title: "Nợ", amount: netWorth.liabilities)
                    }
                }
            }
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier("dashboard.netWorthCard")
    }

    private func column(title: String, amount: Int64) -> some View {
        VStack(spacing: 2) {
            Text(title)
                .font(.caption)
                .foregroundStyle(.secondary)
            AmountText(amount: amount)
                .font(.headline)
        }
        .frame(maxWidth: .infinity)
    }
}

// MARK: - This month

/// Card 2: income, expense, net for the current calendar month, with the
/// percent change against the previous month and a compact
/// personal/business split line.
struct DashboardMonthCard: View {
    let month: DashboardSnapshot.MonthSummary

    var body: some View {
        DashboardCard(month.title) {
            VStack(spacing: 10) {
                totalRow("Thu", amount: month.income, kind: .income,
                         percent: month.incomeChangePercent)
                totalRow("Chi", amount: month.expense, kind: .expense,
                         percent: month.expenseChangePercent)
                Divider()
                HStack {
                    Text("Cân đối")
                        .foregroundStyle(.secondary)
                    Spacer()
                    AmountText(amount: month.net)
                        .font(.headline)
                }
                Text(
                    "Cá nhân: chi \(VND.compact(month.personalExpense)) · " +
                    "Kinh doanh: thu \(VND.compact(month.businessIncome)), " +
                    "chi \(VND.compact(month.businessExpense))"
                )
                .font(.caption)
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("dashboard.monthCard")
    }

    private func totalRow(
        _ title: String, amount: Int64,
        kind: TransactionKind, percent: Double?
    ) -> some View {
        HStack {
            Text(title)
                .foregroundStyle(.secondary)
            Spacer()
            if let percent {
                changeBadge(percent, kind: kind)
            }
            AmountText(amount: amount, kind: kind)
                .font(.subheadline.weight(.medium))
        }
    }

    /// "+25%" / "-8%" pill; hidden entirely when the previous month had no
    /// value to compare to.
    private func changeBadge(_ percent: Double, kind: TransactionKind) -> some View {
        Label(
            DashboardSnapshot.percentText(percent),
            systemImage: percent >= 0 ? "arrow.up.right" : "arrow.down.right"
        )
        .font(.caption2.weight(.semibold))
        .foregroundStyle(AppTheme.color(for: kind))
        .padding(.horizontal, 6)
        .padding(.vertical, 3)
        .background(AppTheme.color(for: kind).opacity(0.12), in: Capsule())
    }
}

// MARK: - Accounts strip

/// Card 3: horizontally scrolling chips of the non-archived accounts;
/// tapping pushes the account detail.
struct DashboardAccountsCard: View {
    let chips: [DashboardSnapshot.AccountChip]
    /// Resolves a chip back to its model so the destination can be built.
    let account: (UUID) -> Account?

    var body: some View {
        DashboardCard("Tài khoản") {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 10) {
                    ForEach(chips) { chip in
                        if let model = account(chip.id) {
                            NavigationLink {
                                AccountDetailView(account: model)
                            } label: {
                                chipView(chip)
                            }
                            .buttonStyle(.plain)
                        } else {
                            chipView(chip)
                        }
                    }
                }
            }
        }
    }

    private func chipView(_ chip: DashboardSnapshot.AccountChip) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            IconBadge(symbol: chip.icon, colorHex: chip.colorHex, size: 32)
            Text(chip.name)
                .font(.caption)
                .foregroundStyle(.primary)
                .lineLimit(1)
            AmountText(amount: chip.balance, compact: true)
                .font(.subheadline.weight(.medium))
        }
        .frame(width: 110, alignment: .leading)
        .padding(10)
        .background(
            Color(.tertiarySystemGroupedBackground),
            in: RoundedRectangle(cornerRadius: 12)
        )
    }
}

// MARK: - Six-month chart

/// One plotted bar — a month's income or expense in đồng (as Double so the
/// value is `Plottable` on iOS 17).
private struct DashboardChartDatum: Identifiable {
    let monthStart: Date
    let kind: String
    let amount: Double

    var id: String { "\(monthStart.timeIntervalSince1970)-\(kind)" }
}

/// Card 4: income vs expense per month for the last six months, as grouped
/// bars in the Thu/Chi semantic colors.
struct DashboardChartCard: View {
    let months: [DashboardSnapshot.MonthPoint]

    private var data: [DashboardChartDatum] {
        months.flatMap { point in
            [
                DashboardChartDatum(
                    monthStart: point.monthStart, kind: "Thu",
                    amount: Double(point.income)
                ),
                DashboardChartDatum(
                    monthStart: point.monthStart, kind: "Chi",
                    amount: Double(point.expense)
                ),
            ]
        }
    }

    var body: some View {
        DashboardCard("6 tháng gần đây") {
            VStack(alignment: .leading, spacing: 8) {
                legend
                Chart(data) { entry in
                    BarMark(
                        x: .value("Tháng", entry.monthStart, unit: .month),
                        y: .value("Số tiền", entry.amount)
                    )
                    .foregroundStyle(by: .value("Loại", entry.kind))
                    .position(by: .value("Loại", entry.kind))
                }
                .chartLegend(.hidden)
                .chartForegroundStyleScale(
                    domain: ["Thu", "Chi"],
                    range: [AppTheme.income, AppTheme.expense]
                )
                .chartXAxis {
                    AxisMarks(values: months.map(\.monthStart)) { value in
                        AxisValueLabel {
                            if let date = value.as(Date.self) {
                                Text(
                                    "T\(AppCalendar.vietnam.component(.month, from: date))"
                                )
                                .font(.caption2)
                            }
                        }
                    }
                }
                .chartYAxis {
                    AxisMarks(position: .leading) { value in
                        AxisGridLine()
                        AxisValueLabel {
                            if let amount = value.as(Double.self) {
                                Text(VND.compact(Int64(amount)))
                                    .font(.caption2)
                            }
                        }
                    }
                }
                .frame(height: 180)
                .accessibilityLabel("Biểu đồ thu chi 6 tháng gần đây")
            }
        }
    }

    private var legend: some View {
        HStack(spacing: 16) {
            legendItem("Thu", color: AppTheme.income)
            legendItem("Chi", color: AppTheme.expense)
        }
        .font(.caption)
        .foregroundStyle(.secondary)
    }

    private func legendItem(_ title: String, color: Color) -> some View {
        HStack(spacing: 4) {
            Circle()
                .fill(color)
                .frame(width: 8, height: 8)
            Text(title)
        }
    }
}

// MARK: - Top expense categories

/// Card 5: the month's five biggest expense categories with proportional
/// bars; everything else is folded into the trailing "Khác" row.
struct DashboardTopCategoriesCard: View {
    let rows: [DashboardSnapshot.CategoryRow]

    var body: some View {
        DashboardCard("Chi tiêu theo danh mục") {
            VStack(spacing: 12) {
                ForEach(rows) { row in
                    HStack(spacing: 10) {
                        IconBadge(symbol: row.icon, colorHex: row.colorHex, size: 30)
                        VStack(alignment: .leading, spacing: 4) {
                            Text(row.name)
                                .font(.subheadline)
                                .lineLimit(1)
                            bar(share: row.share, colorHex: row.colorHex)
                        }
                        Spacer()
                        VStack(alignment: .trailing, spacing: 2) {
                            AmountText(amount: row.total, kind: .expense)
                                .font(.subheadline.weight(.medium))
                            Text(DashboardSnapshot.shareText(row.share))
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                        }
                    }
                }
            }
        }
    }

    private func bar(share: Double, colorHex: String) -> some View {
        GeometryReader { geometry in
            ZStack(alignment: .leading) {
                Capsule()
                    .fill(Color(.tertiarySystemFill))
                Capsule()
                    .fill(Color(hex: colorHex))
                    .frame(width: max(4, geometry.size.width * min(1, share)))
            }
        }
        .frame(height: 6)
        .accessibilityHidden(true)
    }
}

// MARK: - Business profit & loss

/// Card 6: revenue, cost and profit per business for the month — only
/// businesses with activity (the card is hidden when the list is empty).
struct DashboardBusinessCard: View {
    let results: [DashboardSnapshot.BusinessResult]

    var body: some View {
        DashboardCard("Kinh doanh") {
            VStack(spacing: 12) {
                ForEach(results) { result in
                    HStack(spacing: 10) {
                        IconBadge(
                            symbol: result.icon, colorHex: result.colorHex, size: 30
                        )
                        VStack(alignment: .leading, spacing: 2) {
                            Text(result.name)
                                .font(.subheadline)
                                .lineLimit(1)
                            Text(
                                "Thu \(VND.compact(result.revenue)) · " +
                                "Chi \(VND.compact(result.cost))"
                            )
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        }
                        Spacer()
                        VStack(alignment: .trailing, spacing: 2) {
                            Text(result.profit >= 0 ? "Lãi" : "Lỗ")
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                            AmountText(amount: result.profit)
                                .font(.subheadline.weight(.semibold))
                        }
                    }
                }
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("dashboard.businessCard")
    }
}

// MARK: - Pending review banner

/// Card 7: plain banner shown while transactions are waiting to be
/// classified (imports, quick notes). No navigation.
struct DashboardPendingReviewBanner: View {
    let count: Int

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: "tray.full.fill")
                .foregroundStyle(.orange)
            Text("Có \(count) giao dịch chờ phân loại")
                .font(.subheadline.weight(.medium))
            Spacer()
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            Color.orange.opacity(0.15),
            in: RoundedRectangle(cornerRadius: 16)
        )
    }
}

// MARK: - Recent transactions

/// Card 8: the eight latest rows — same layout as a history row; tapping
/// presents the transaction editor for that row.
struct DashboardRecentCard: View {
    let items: [DashboardSnapshot.RecentItem]
    let onSelect: (DashboardSnapshot.RecentItem) -> Void

    var body: some View {
        DashboardCard("Giao dịch gần đây") {
            VStack(spacing: 0) {
                ForEach(items) { item in
                    Button {
                        onSelect(item)
                    } label: {
                        row(item)
                    }
                    .buttonStyle(.plain)
                    if item.id != items.last?.id {
                        Divider()
                            .padding(.leading, 42)
                    }
                }
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("dashboard.recentCard")
    }

    private func row(_ item: DashboardSnapshot.RecentItem) -> some View {
        HStack(spacing: 10) {
            IconBadge(symbol: item.icon, colorHex: item.colorHex, size: 32)
            VStack(alignment: .leading, spacing: 2) {
                Text(item.title)
                    .font(.subheadline)
                    .foregroundStyle(.primary)
                    .lineLimit(1)
                Text(item.subtitle)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            Spacer()
            AmountText(amount: item.amount, kind: item.kind)
                .font(.subheadline.weight(.medium))
        }
        .padding(.vertical, 7)
        .contentShape(Rectangle())
    }
}

// MARK: - Upcoming debt payments

/// Card: debt payments due within the next days — card statements and loan
/// installments sorted by due date. Hidden by the caller when the list is
/// empty; tapping a row pushes the matching detail view.
struct DashboardUpcomingCard: View {
    let items: [DebtsUpcomingItem]
    /// Resolves an item's account id back to its model for the row's icon
    /// and name and for the navigation destination.
    let account: (UUID) -> Account?

    var body: some View {
        DashboardCard("Sắp đến hạn") {
            VStack(spacing: 0) {
                ForEach(items) { item in
                    if let model = account(item.accountID) {
                        NavigationLink {
                            destination(item, account: model)
                        } label: {
                            DebtsUpcomingRow(item: item, account: model)
                        }
                        .buttonStyle(.plain)
                        if item.id != items.last?.id {
                            Divider()
                                .padding(.leading, 48)
                        }
                    }
                }
            }
        }
    }

    @ViewBuilder
    private func destination(_ item: DebtsUpcomingItem, account: Account) -> some View {
        switch item.kind {
        case .creditCard: CreditCardDetailView(account: account)
        case .loan: LoanDetailView(account: account)
        }
    }
}

// MARK: - Welcome (fresh install)

/// Shown instead of the data cards when there is no transaction at all:
/// explains the first two steps with a button each.
struct DashboardWelcomeCard: View {
    let onAddTransaction: () -> Void

    var body: some View {
        DashboardCard {
            VStack(spacing: 12) {
                Image(systemName: "chart.pie.fill")
                    .font(.system(size: 40))
                    .foregroundStyle(Color.accentColor)
                Text("Chào mừng đến AM Finance")
                    .font(.headline)
                Text(
                    "Thêm một tài khoản rồi ghi giao dịch đầu tiên " +
                    "để bắt đầu theo dõi tiền của bạn."
                )
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                HStack(spacing: 12) {
                    NavigationLink {
                        AccountsListView()
                    } label: {
                        Text("Thêm tài khoản")
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.bordered)
                    Button(action: onAddTransaction) {
                        Text("Thêm giao dịch đầu tiên")
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.borderedProminent)
                }
                .font(.subheadline.weight(.medium))
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 8)
        }
    }
}
