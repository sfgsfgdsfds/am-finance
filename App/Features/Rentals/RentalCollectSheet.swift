import SwiftUI
import SwiftData
import FinanceCore

/// "Thu tiền" — records one month's rent as business income. The month
/// defaults to the covering lease's oldest unpaid month; the keypad is
/// pre-filled with what is still owed for it and can be switched to a
/// second, optional amount for utilities ("Điện, nước, dịch vụ") with its
/// own note. Saving posts income rows through `RentalActions`: the rent
/// part is tagged with `rentalPeriod`, the extra part is not — so it never
/// counts as rent. Owns its NavigationStack.
struct RentalCollectSheet: View {
    let lease: RentalLease

    @Environment(\.modelContext) private var context
    @Environment(\.dismiss) private var dismiss
    @Query(sort: \Account.sortOrder) private var accounts: [Account]
    @Query(sort: \LedgerCategory.sortOrder) private var categories: [LedgerCategory]

    /// Which part the keypad edits — mirrors `LoanPaymentSheet`.
    private enum Part { case rent, extra }

    @State private var month: Date
    @State private var part = Part.rent
    @State private var amount: Int64
    @State private var extra: Int64 = 0
    @State private var extraNote: String = "Điện, nước, dịch vụ"
    @State private var note: String
    @State private var receiver: Account?
    @State private var date: Date = .now
    @State private var saveFailed = false

    init(lease: RentalLease, month: Date) {
        self.lease = lease
        let calendar = AppCalendar.vietnam
        let monthStart = RentalSnapshot.monthStart(of: month, calendar: calendar)
        _month = State(initialValue: monthStart)
        let payments = RentalSnapshot.payments(of: lease)
        let span = RentalLeaseSpan(lease)
        _amount = State(initialValue: Self.remaining(
            of: span, payments: payments, month: monthStart, calendar: calendar
        ))
        _note = State(initialValue: RentalActions.rentNote(
            unitName: lease.unit?.name ?? "", month: monthStart, calendar: calendar
        ))
    }

    private var span: RentalLeaseSpan { RentalLeaseSpan(lease) }
    private var payments: [RentalPaymentEntry] { RentalSnapshot.payments(of: lease) }
    private var calendar: Calendar { AppCalendar.vietnam }

    /// What is still owed for `month` — the keypad pre-fill.
    private static func remaining(
        of span: RentalLeaseSpan,
        payments: [RentalPaymentEntry],
        month: Date,
        calendar: Calendar
    ) -> Int64 {
        max(0, span.monthlyRent - RentalSnapshot.collected(
            payments: payments, leaseID: span.id, month: month, calendar: calendar
        ))
    }

    /// Months the picker offers — every covered month up to the current
    /// one (plus the lease's first month when it only starts later).
    private var months: [Date] {
        RentalSnapshot.collectableMonths(of: span, now: .now, calendar: calendar)
    }

    private var receivers: [Account] {
        RentalActions.receivers(accounts)
    }

    private var canSave: Bool {
        receiver != nil && (amount > 0 || extra > 0)
    }

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                VStack(spacing: 8) {
                    Picker("Tháng", selection: $month) {
                        ForEach(months, id: \.self) { option in
                            Text(AppDateFormat.monthTitle(option)).tag(option)
                        }
                    }
                    .pickerStyle(.menu)
                    .onChange(of: month) { _, newMonth in
                        amount = Self.remaining(
                            of: span, payments: payments,
                            month: newMonth, calendar: calendar
                        )
                        note = RentalActions.rentNote(
                            unitName: lease.unit?.name ?? "",
                            month: newMonth, calendar: calendar
                        )
                    }

                    Picker("Phần tiền", selection: $part) {
                        Text("Tiền phòng").tag(Part.rent)
                        Text("Thu thêm").tag(Part.extra)
                    }
                    .pickerStyle(.segmented)

                    AmountKeypad(amount: amountBinding)
                    LabeledContent("Còn phải thu", value: VND.format(currentRemaining))
                    if extra > 0 {
                        LabeledContent("Thu thêm", value: VND.format(extra))
                        LabeledContent("Tổng thu", value: VND.format(amount + extra))
                    }
                }
                .padding(.horizontal)
                .padding(.top, 8)
                .padding(.bottom, 12)

                Form {
                    Section {
                        if receivers.isEmpty {
                            Text("Chưa có tài khoản để nhận — hãy tạo tiền mặt, ngân hàng hoặc ví điện tử trước.")
                                .foregroundStyle(.secondary)
                        } else {
                            receiverPicker
                        }
                        DatePicker(
                            "Ngày thu",
                            selection: $date,
                            displayedComponents: .date
                        )
                        .environment(\.calendar, AppCalendar.vietnam)
                        TextField("Ghi chú tiền phòng", text: $note)
                    }
                    if part == .extra || extra > 0 {
                        Section("Thu thêm") {
                            TextField("Nội dung thu thêm", text: $extraNote)
                        }
                    }
                }
            }
            .background(Color(.systemGroupedBackground))
            .navigationTitle("Thu tiền \(lease.unit?.name ?? "")")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Huỷ") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Lưu") { save() }
                        .disabled(!canSave)
                }
            }
            .onAppear {
                if receiver == nil { receiver = receivers.first }
            }
            .alert("Không thể lưu", isPresented: $saveFailed) {
                Button("Đóng", role: .cancel) {}
            } message: {
                Text("Không ghi được khoản thu. Vui lòng thử lại.")
            }
        }
    }

    /// Still owed for the selected month — drives the summary line.
    private var currentRemaining: Int64 {
        Self.remaining(of: span, payments: payments, month: month, calendar: calendar)
    }

    /// The keypad edits whichever part the segmented control selects.
    private var amountBinding: Binding<Int64> {
        Binding(
            get: { part == .rent ? amount : extra },
            set: {
                if part == .rent { amount = $0 } else { extra = $0 }
            }
        )
    }

    private var receiverPicker: some View {
        Picker(selection: $receiver) {
            ForEach(receivers, id: \.id) { candidate in
                Label {
                    HStack {
                        Text(candidate.name)
                        Spacer(minLength: 8)
                        AmountText(amount: candidate.balance, compact: true)
                            .font(.subheadline)
                    }
                } icon: {
                    IconBadge(symbol: candidate.icon, colorHex: candidate.colorHex, size: 28)
                }
                .tag(candidate as Account?)
            }
        } label: {
            Text("Nhận vào")
        }
        .pickerStyle(.navigationLink)
    }

    /// One income row for the rent part (`rentalPeriod` tagged), plus a
    /// second for the extra part (untagged) when it was typed.
    private func save() {
        guard canSave, let receiver else { return }
        let category = RentalActions.rentCategory(in: categories)
        let trimmedNote = note.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedExtra = extraNote.trimmingCharacters(in: .whitespacesAndNewlines)
        do {
            if amount > 0 {
                context.insert(RentalActions.rentPayment(
                    lease: lease, month: month, amount: amount, date: date,
                    note: trimmedNote.isEmpty
                        ? RentalActions.rentNote(
                            unitName: lease.unit?.name ?? "",
                            month: month, calendar: calendar)
                        : trimmedNote,
                    into: receiver, category: category
                ))
            }
            if extra > 0 {
                context.insert(RentalActions.extraPayment(
                    lease: lease, amount: extra, date: date,
                    note: trimmedExtra.isEmpty
                        ? RentalActions.extraNote(
                            unitName: lease.unit?.name ?? "",
                            month: month, calendar: calendar)
                        : trimmedExtra,
                    into: receiver, category: category
                ))
            }
            try context.save()
            dismiss()
        } catch {
            saveFailed = true
        }
    }
}

#Preview {
    let container = try! AppModelContainer.make(inMemory: true)
    let context = ModelContext(container)
    try! SeedData.seedIfNeeded(context: context)
    let apartment = try! context.fetch(FetchDescriptor<Business>())
        .first { $0.name == "Căn hộ dịch vụ" }!
    let unit = RentalUnit(name: "Phòng 101", listPrice: 5_000_000, business: apartment)
    context.insert(unit)
    let lease = RentalLease(
        tenantName: "Nguyễn Văn A", tenantPhone: "090 123 4567",
        startDate: AppCalendar.vietnam.date(byAdding: .month, value: -4, to: .now)!,
        monthlyRent: 5_000_000, deposit: 5_000_000, paymentDay: 5,
        unit: unit)
    context.insert(lease)
    return RentalCollectSheet(
        lease: lease,
        month: RentalSnapshot.defaultCollectMonth(
            of: RentalLeaseSpan(lease), payments: [],
            now: .now, calendar: AppCalendar.vietnam)
    )
    .modelContainer(container)
}
