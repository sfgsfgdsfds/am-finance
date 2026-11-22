import SwiftUI
import SwiftData
import FinanceCore

/// "Phòng cho thuê" — the serviced-apartment rooms and who rents them for
/// the displayed month. The month card switches months and totals expected,
/// collected and still-to-collect rent; each room row shows its tenant and
/// the month's status ("Đã thu" / "Thu một phần" / "Chưa thu" / "Quá hạn N
/// ngày" / "Trống"), with a swipe to collect. Rows push
/// `RentalUnitDetailView`; the toolbar "+" creates a room; archived rooms
/// sit in a collapsed section. Pushed inside an existing NavigationStack —
/// it does not own one.
struct RentalsView: View {
    /// nil lists every room; non-nil scopes to one business.
    let business: Business?

    @Query(sort: \RentalUnit.sortOrder) private var units: [RentalUnit]

    /// Always the first day of the displayed month — the switcher shifts it.
    @State private var monthAnchor: Date
    @State private var isCreating = false
    @State private var showsArchived = false
    @State private var collecting: RentalCollectContext?

    init(business: Business? = nil) {
        self.business = business
        _monthAnchor = State(initialValue:
            RentalSnapshot.monthStart(of: .now, calendar: AppCalendar.vietnam))
    }

    private var scopedUnits: [RentalUnit] {
        units
            .filter { business == nil || $0.business?.id == business?.id }
            .sorted {
                $0.sortOrder != $1.sortOrder ? $0.sortOrder < $1.sortOrder : $0.name < $1.name
            }
    }

    private var board: RentalBoard {
        RentalSnapshot.board(
            units: scopedUnits, month: monthAnchor,
            calendar: AppCalendar.vietnam
        ).summary
    }

    private var activeRooms: [RentalUnit] {
        scopedUnits.filter { !$0.isArchived }
    }

    private var archivedRooms: [RentalUnit] {
        scopedUnits.filter(\.isArchived)
    }

    private func monthInfo(of unit: RentalUnit) -> RentalUnitMonth {
        RentalSnapshot.make(unit: unit, month: monthAnchor, calendar: AppCalendar.vietnam)
    }

    var body: some View {
        Group {
            if scopedUnits.isEmpty {
                EmptyStateView(
                    symbol: "bed.double.fill",
                    title: "Chưa có phòng",
                    message: "Thêm phòng để theo dõi ai đang thuê và tiền thuê từng tháng đã thu chưa.",
                    actionTitle: "Thêm phòng",
                    action: { isCreating = true }
                )
            } else {
                VStack(spacing: 0) {
                    monthHeader
                    list
                }
                .background(Color(.systemGroupedBackground))
            }
        }
        .navigationTitle(business.map { "Phòng — \($0.name)" } ?? "Phòng cho thuê")
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button {
                    isCreating = true
                } label: {
                    Image(systemName: "plus")
                }
                .accessibilityLabel("Thêm phòng")
            }
        }
        .sheet(isPresented: $isCreating) {
            RentalUnitEditView(business: business)
        }
        .sheet(item: $collecting) { target in
            RentalCollectSheet(lease: target.lease, month: target.month)
        }
    }

    // MARK: - Month header

    private var monthHeader: some View {
        VStack(spacing: 12) {
            HStack {
                shiftButton(-1, symbol: "chevron.left", label: "Tháng trước")
                Spacer()
                Text(AppDateFormat.monthTitle(monthAnchor))
                    .font(.headline)
                    .lineLimit(1)
                    .minimumScaleFactor(0.7)
                Spacer()
                shiftButton(1, symbol: "chevron.right", label: "Tháng sau")
            }

            VStack(alignment: .leading, spacing: 6) {
                HStack {
                    Text("Đang thuê \(board.occupied)/\(board.total) phòng")
                        .font(.subheadline.weight(.medium))
                    Spacer()
                    Text(board.occupancyFraction
                        .formatted(.percent.precision(.fractionLength(0))))
                        .font(.subheadline)
                        .monospacedDigit()
                        .foregroundStyle(.secondary)
                }
                ProgressView(value: board.occupancyFraction)
                    .tint(.accentColor)
                HStack(spacing: 0) {
                    totalCell("Phải thu", amount: board.expected)
                    totalCell("Đã thu", amount: board.collected, tint: AppTheme.income)
                    totalCell("Còn phải thu", amount: board.remaining,
                              tint: board.remaining > 0 ? AppTheme.expense : nil)
                }
            }
        }
        .padding(16)
        .background(
            Color(.secondarySystemGroupedBackground),
            in: RoundedRectangle(cornerRadius: 16)
        )
        .padding(.horizontal, 16)
        .padding(.top, 8)
        .padding(.bottom, 8)
    }

    private func totalCell(
        _ title: String, amount: Int64, tint: Color? = nil
    ) -> some View {
        VStack(spacing: 2) {
            Text(title)
                .font(.caption)
                .foregroundStyle(.secondary)
            Text(VND.compact(amount))
                .font(.subheadline.weight(.semibold))
                .monospacedDigit()
                .foregroundStyle(tint ?? .primary)
                .lineLimit(1)
                .minimumScaleFactor(0.5)
        }
        .frame(maxWidth: .infinity)
    }

    private func shiftButton(
        _ offset: Int, symbol: String, label: String
    ) -> some View {
        Button {
            guard let shifted = AppCalendar.vietnam.date(
                byAdding: .month, value: offset, to: monthAnchor
            ) else { return }
            monthAnchor = shifted
        } label: {
            Image(systemName: symbol)
                .font(.headline)
                .frame(width: 36, height: 28)
                .contentShape(Rectangle())
        }
        .accessibilityLabel(label)
    }

    // MARK: - List

    private var list: some View {
        List {
            Section {
                ForEach(activeRooms, id: \.id) { unit in
                    roomRow(unit, month: monthInfo(of: unit))
                }
            }
            if !archivedRooms.isEmpty {
                Section {
                    DisclosureGroup(isExpanded: $showsArchived) {
                        ForEach(archivedRooms, id: \.id) { unit in
                            roomRow(unit, month: monthInfo(of: unit))
                        }
                    } label: {
                        HStack {
                            Text("Đã lưu trữ")
                            Spacer()
                            Text("\(archivedRooms.count)")
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

    private func roomRow(_ unit: RentalUnit, month info: RentalUnitMonth) -> some View {
        NavigationLink {
            RentalUnitDetailView(unit: unit)
        } label: {
            HStack(spacing: 12) {
                IconBadge(
                    symbol: "bed.double.fill",
                    colorHex: unit.business?.colorHex ?? "30B0C7",
                    size: 36
                )
                VStack(alignment: .leading, spacing: 2) {
                    Text(unit.name)
                        .lineLimit(1)
                    Text(info.tenantName ?? "Trống")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                Spacer(minLength: 8)
                VStack(alignment: .trailing, spacing: 4) {
                    Text(VND.compact(rentAmount(of: unit, month: info)))
                        .font(.subheadline.weight(.semibold))
                        .monospacedDigit()
                        .lineLimit(1)
                        .minimumScaleFactor(0.6)
                    statusTag(info)
                }
            }
        }
        .swipeActions(edge: .trailing, allowsFullSwipe: false) {
            if let lease = coveringLease(of: unit, month: info) {
                Button {
                    collecting = RentalCollectContext(lease: lease, month: monthAnchor)
                } label: {
                    Label("Thu tiền", systemImage: "banknote.fill")
                }
                .tint(AppTheme.income)
            }
        }
    }

    /// The rent a row displays: the covering lease's agreed rent, or the
    /// room's list price while it is vacant.
    private func rentAmount(of unit: RentalUnit, month info: RentalUnitMonth) -> Int64 {
        info.status == .vacant ? unit.listPrice : info.expected
    }

    /// The live lease covering the displayed month — the collect sheet's
    /// target; nil while the room is vacant that month.
    private func coveringLease(
        of unit: RentalUnit, month info: RentalUnitMonth
    ) -> RentalLease? {
        guard let leaseID = info.leaseID else { return nil }
        return (unit.leases ?? []).first { $0.id == leaseID }
    }

    // MARK: - Status tag

    /// "Đã thu" / "Thu một phần" / "Chưa thu" / "Trống" — and "Quá hạn N
    /// ngày" in the expense color once the due date passes unpaid.
    private func statusTag(_ info: RentalUnitMonth) -> some View {
        let overdue = info.overdueDays(now: .now, calendar: AppCalendar.vietnam)
        let text = overdue > 0
            ? "Quá hạn \(overdue) ngày"
            : statusText(info.status)
        let color = tagColor(info.status, overdue: overdue)
        return Text(text)
            .font(.caption2.weight(.medium))
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(color.opacity(0.15), in: Capsule())
            .foregroundStyle(color)
            .lineLimit(1)
    }

    private func statusText(_ status: RentalMonthStatus) -> String {
        switch status {
        case .vacant: return "Trống"
        case .unpaid: return "Chưa thu"
        case .partial: return "Thu một phần"
        case .paid: return "Đã thu"
        }
    }

    private func tagColor(_ status: RentalMonthStatus, overdue: Int) -> Color {
        if overdue > 0 { return AppTheme.expense }
        switch status {
        case .vacant: return .secondary
        case .unpaid: return .secondary
        case .partial: return Color(.systemOrange)
        case .paid: return AppTheme.income
        }
    }
}

/// `.sheet(item:)` payload for the collect sheet: the covering lease plus
/// the month the collection applies to.
struct RentalCollectContext: Identifiable {
    let id = UUID()
    let lease: RentalLease
    /// First day of the month the collection covers.
    let month: Date
}

#Preview("Phòng cho thuê") {
    let container = try! AppModelContainer.make(inMemory: true)
    let context = ModelContext(container)
    try! SeedData.seedIfNeeded(context: context)
    let cash = try! context.fetch(FetchDescriptor<Account>()).first!
    let apartment = try! context.fetch(FetchDescriptor<Business>())
        .first { $0.name == "Căn hộ dịch vụ" }!
    let calendar = AppCalendar.vietnam
    let monthStart = RentalSnapshot.monthStart(of: .now, calendar: calendar)

    let roomA = RentalUnit(name: "Phòng 101", listPrice: 5_000_000, sortOrder: 0, business: apartment)
    let roomB = RentalUnit(name: "Phòng 102", listPrice: 4_500_000, sortOrder: 1, business: apartment)
    let roomC = RentalUnit(name: "Phòng 201", listPrice: 6_000_000, sortOrder: 2, business: apartment)
    for unit in [roomA, roomB, roomC] { context.insert(unit) }
    let leaseA = RentalLease(
        tenantName: "Nguyễn Văn A", tenantPhone: "090 123 4567",
        startDate: calendar.date(byAdding: .month, value: -8, to: .now)!,
        monthlyRent: 5_000_000, deposit: 5_000_000, paymentDay: 5,
        unit: roomA)
    let leaseB = RentalLease(
        tenantName: "Trần Thị B", tenantPhone: "098 765 4321",
        startDate: calendar.date(byAdding: .month, value: -3, to: .now)!,
        monthlyRent: 4_800_000, deposit: 4_800_000, paymentDay: 1,
        unit: roomB)
    context.insert(leaseA)
    context.insert(leaseB)
    context.insert(LedgerTransaction(
        kind: .income, amount: 5_000_000, date: .now,
        account: cash, business: apartment,
        rentalLease: leaseA, rentalPeriod: monthStart))
    return NavigationStack {
        RentalsView()
    }
    .modelContainer(container)
}

#Preview("Trống") {
    let container = try! AppModelContainer.make(inMemory: true)
    try! SeedData.seedIfNeeded(context: ModelContext(container))
    return NavigationStack {
        RentalsView()
    }
    .modelContainer(container)
}
