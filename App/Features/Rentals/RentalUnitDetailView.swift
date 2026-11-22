import SwiftUI
import SwiftData
import FinanceCore

/// One rental room: its facts, the current lease card (tenant, tappable
/// phone, rent, deposit, due day and period), a twelve-month payment-status
/// grid, the collected payment history, and the actions — collect rent,
/// new lease (only when no lease is active), edit lease and "Kết thúc hợp
/// đồng" after a confirmation. Pushed inside an existing NavigationStack —
/// it does not own one.
struct RentalUnitDetailView: View {
    let unit: RentalUnit

    @Environment(\.modelContext) private var context
    @State private var showsUnitEdit = false
    @State private var showsNewLease = false
    @State private var editingLease: RentalLease?
    @State private var collecting: RentalCollectContext?
    @State private var confirmsEndLease = false

    init(unit: RentalUnit) {
        self.unit = unit
    }

    private var calendar: Calendar { AppCalendar.vietnam }

    private var leases: [RentalLease] {
        unit.leases ?? []
    }

    /// The live tenancy — `isActive` alone decides (an upcoming lease counts
    /// too); at most one is expected, the newest wins if data says more.
    private var activeLease: RentalLease? {
        leases.filter(\.isActive).sorted { $0.startDate > $1.startDate }.first
    }

    private var endedLeases: [RentalLease] {
        leases.filter { !$0.isActive }.sorted { $0.startDate > $1.startDate }
    }

    /// The month the collect action opens on — the active lease's oldest
    /// unpaid month, else its current one.
    private var defaultMonth: Date {
        guard let activeLease else { return RentalSnapshot.monthStart(of: .now, calendar: calendar) }
        return RentalSnapshot.defaultCollectMonth(
            of: RentalLeaseSpan(activeLease),
            payments: RentalSnapshot.payments(of: activeLease),
            now: .now, calendar: calendar
        )
    }

    /// The last twelve months ending with the current one — the status
    /// grid's range.
    private var grid: [RentalUnitMonth] {
        RentalSnapshot.recentMonths(count: 12, endingAt: .now, calendar: calendar)
            .map { RentalSnapshot.make(unit: unit, month: $0, calendar: calendar) }
    }

    private var gridMonths: [Date] {
        RentalSnapshot.recentMonths(count: 12, endingAt: .now, calendar: calendar)
    }

    /// Rent rows collected across every lease of this room, newest first —
    /// extras (nil `rentalPeriod`) ride along via the same relationship.
    private var payments: [LedgerTransaction] {
        var seen = Set<UUID>()
        return leases.flatMap { $0.payments ?? [] }
            .filter { seen.insert($0.id).inserted }
            .sorted { $0.date > $1.date }
    }

    var body: some View {
        List {
            roomSection
            leaseSection
            gridSection
            actionsSection
            historySection
        }
        .listStyle(.insetGrouped)
        .navigationTitle(unit.name)
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button("Sửa") { showsUnitEdit = true }
            }
        }
        .sheet(isPresented: $showsUnitEdit) {
            RentalUnitEditView(unit: unit)
        }
        .sheet(isPresented: $showsNewLease) {
            RentalLeaseEditView(unit: unit)
        }
        .sheet(item: $editingLease) { lease in
            RentalLeaseEditView(unit: unit, lease: lease)
        }
        .sheet(item: $collecting) { target in
            RentalCollectSheet(lease: target.lease, month: target.month)
        }
        .confirmationDialog(
            "Kết thúc hợp đồng?",
            isPresented: $confirmsEndLease,
            titleVisibility: .visible
        ) {
            Button("Kết thúc hợp đồng", role: .destructive) {
                if let activeLease {
                    RentalActions.end(lease: activeLease, at: .now)
                    try? context.save()
                }
            }
            Button("Huỷ", role: .cancel) {}
        } message: {
            Text("Tháng này vẫn tính tiền thuê; các tháng sau phòng chuyển thành trống.")
        }
    }

    // MARK: - Room

    private var roomSection: some View {
        Section("Phòng") {
            LabeledContent("Giá niêm yết", value: VND.format(unit.listPrice))
            if let business = unit.business {
                LabeledContent("Mảng kinh doanh", value: business.name)
            }
            if !unit.note.isEmpty {
                LabeledContent("Ghi chú", value: unit.note)
            }
        }
    }

    // MARK: - Current lease

    @ViewBuilder
    private var leaseSection: some View {
        if let lease = activeLease {
            Section("Hợp đồng hiện tại") {
                LabeledContent("Người thuê", value: lease.tenantName)
                if !lease.tenantPhone.isEmpty {
                    if let url = RentalFormat.phoneURL(lease.tenantPhone) {
                        Link(destination: url) {
                            LabeledContent("Điện thoại") {
                                Text(lease.tenantPhone)
                                    .foregroundStyle(Color.accentColor)
                            }
                        }
                    } else {
                        LabeledContent("Điện thoại", value: lease.tenantPhone)
                    }
                }
                LabeledContent("Tiền thuê") {
                    AmountText(amount: lease.monthlyRent)
                }
                LabeledContent("Tiền cọc", value: VND.format(lease.deposit))
                LabeledContent("Ngày trả hằng tháng", value: "Ngày \(lease.paymentDay)")
                LabeledContent(
                    "Bắt đầu",
                    value: RentalFormat.fullDate(lease.startDate, calendar: calendar)
                )
                LabeledContent(
                    "Kết thúc",
                    value: lease.endDate.map {
                        RentalFormat.fullDate($0, calendar: calendar)
                    } ?? "Chưa xác định"
                )
                if !lease.note.isEmpty {
                    LabeledContent("Ghi chú", value: lease.note)
                }
            }
        }

        if !endedLeases.isEmpty {
            Section("Hợp đồng cũ") {
                ForEach(endedLeases, id: \.id) { lease in
                    Button {
                        editingLease = lease
                    } label: {
                        HStack {
                            Text(lease.tenantName)
                                .foregroundStyle(.primary)
                                .lineLimit(1)
                            Spacer()
                            Text(leasePeriod(lease))
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                        }
                    }
                }
            }
        }
    }

    /// "09/26 – 11/26" for an ended lease row.
    private func leasePeriod(_ lease: RentalLease) -> String {
        let formatter = { (date: Date) in
            let m = calendar.component(.month, from: date)
            let y = calendar.component(.year, from: date) % 100
            return String(format: "%02d/%02d", m, y)
        }
        let start = formatter(lease.startDate)
        guard let end = lease.endDate else { return "từ \(start)" }
        return "\(start) – \(formatter(end))"
    }

    // MARK: - Twelve-month grid

    private var gridSection: some View {
        Section("12 tháng gần nhất") {
            LazyVGrid(
                columns: [GridItem(.adaptive(minimum: 64), spacing: 8)],
                spacing: 8
            ) {
                ForEach(gridMonths.indices, id: \.self) { index in
                    gridCell(monthStart: gridMonths[index], info: grid[index])
                }
            }
            .padding(.vertical, 4)
        }
    }

    private func gridCell(monthStart: Date, info: RentalUnitMonth) -> some View {
        let overdue = info.overdueDays(now: .now, calendar: calendar)
        let color = gridColor(info.status, overdue: overdue)
        let month = calendar.component(.month, from: monthStart)
        let year = calendar.component(.year, from: monthStart) % 100
        return VStack(spacing: 2) {
            Text("T\(month)/\(String(format: "%02d", year))")
                .font(.caption2.weight(.medium))
            Text(gridLabel(info.status, overdue: overdue))
                .font(.caption2)
                .lineLimit(1)
                .minimumScaleFactor(0.6)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 8)
        .background(color.opacity(0.15), in: RoundedRectangle(cornerRadius: 10))
        .foregroundStyle(color)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(AppDateFormat.monthTitle(monthStart)): \(gridLabel(info.status, overdue: overdue))")
    }

    /// Short cell label — the status tag's wording, compacted.
    private func gridLabel(_ status: RentalMonthStatus, overdue: Int) -> String {
        if overdue > 0 { return "Quá \(overdue)n" }
        switch status {
        case .vacant: return "Trống"
        case .unpaid: return "Chưa thu"
        case .partial: return "Một phần"
        case .paid: return "Đã thu"
        }
    }

    private func gridColor(_ status: RentalMonthStatus, overdue: Int) -> Color {
        if overdue > 0 { return AppTheme.expense }
        switch status {
        case .vacant: return .secondary
        case .unpaid: return .secondary
        case .partial: return Color(.systemOrange)
        case .paid: return AppTheme.income
        }
    }

    // MARK: - Actions

    @ViewBuilder
    private var actionsSection: some View {
        Section("Thao tác") {
            if let lease = activeLease {
                Button {
                    collecting = RentalCollectContext(lease: lease, month: defaultMonth)
                } label: {
                    Label {
                        Text("Thu tiền \(RentalActions.monthTitle(of: defaultMonth, calendar: calendar))")
                    } icon: {
                        Image(systemName: "banknote.fill")
                    }
                }
                Button {
                    editingLease = lease
                } label: {
                    Label("Sửa hợp đồng", systemImage: "pencil")
                }
                Button(role: .destructive) {
                    confirmsEndLease = true
                } label: {
                    Label("Kết thúc hợp đồng", systemImage: "xmark.circle")
                }
            } else {
                Button {
                    showsNewLease = true
                } label: {
                    Label("Hợp đồng mới", systemImage: "person.badge.plus")
                }
            }
        }
    }

    // MARK: - Payment history

    private var historySection: some View {
        Section("Lịch sử thu tiền") {
            if payments.isEmpty {
                Text("Chưa có khoản thu nào.")
                    .foregroundStyle(.secondary)
            } else {
                ForEach(payments, id: \.id) { transaction in
                    paymentRow(transaction)
                }
            }
        }
    }

    private func paymentRow(_ transaction: LedgerTransaction) -> some View {
        HStack(spacing: 12) {
            IconBadge(
                symbol: transaction.category?.icon ?? "banknote.fill",
                colorHex: transaction.category?.colorHex ?? "34C759",
                size: 32
            )
            VStack(alignment: .leading, spacing: 2) {
                Text(transaction.note.isEmpty ? "Thu tiền phòng" : transaction.note)
                    .lineLimit(1)
                Text("\(AppDateFormat.shortDate(transaction.date)) · \(AppDateFormat.time(transaction.date))" + (transaction.account.map { " · \($0.name)" } ?? ""))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            Spacer(minLength: 8)
            AmountText(amount: transaction.amount, kind: .income)
                .font(.subheadline.weight(.semibold))
        }
    }
}

#Preview {
    let container = try! AppModelContainer.make(inMemory: true)
    let context = ModelContext(container)
    try! SeedData.seedIfNeeded(context: context)
    let cash = try! context.fetch(FetchDescriptor<Account>()).first!
    let apartment = try! context.fetch(FetchDescriptor<Business>())
        .first { $0.name == "Căn hộ dịch vụ" }!
    let unit = RentalUnit(
        name: "Phòng 101", listPrice: 5_000_000,
        note: "Tầng 1, ban công", business: apartment)
    context.insert(unit)
    let calendar = AppCalendar.vietnam
    let lease = RentalLease(
        tenantName: "Nguyễn Văn A", tenantPhone: "090 123 4567",
        startDate: calendar.date(byAdding: .month, value: -8, to: .now)!,
        monthlyRent: 5_000_000, deposit: 5_000_000, paymentDay: 5,
        unit: unit)
    context.insert(lease)
    for offset in [-7, -6, -5, -4] {
        let month = RentalSnapshot.monthStart(
            of: calendar.date(byAdding: .month, value: offset, to: .now)!,
            calendar: calendar)
        context.insert(LedgerTransaction(
            kind: .income, amount: 5_000_000,
            date: calendar.date(byAdding: .day, value: 4, to: month)!,
            note: "Tiền Phòng 101 \(RentalActions.monthTitle(of: month, calendar: calendar))",
            account: cash, business: apartment,
            rentalLease: lease, rentalPeriod: month))
    }
    return NavigationStack {
        RentalUnitDetailView(unit: unit)
    }
    .modelContainer(container)
}
