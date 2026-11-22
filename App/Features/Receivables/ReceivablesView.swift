import SwiftUI
import SwiftData
import FinanceCore

/// "Khoản ứng hộ khách" — every client receivable account, optionally
/// scoped to one business. Unpaid clients sort by outstanding descending
/// and carry a "Quá 30 ngày" tag when the oldest unpaid advance is over a
/// month old; settled clients sit in a collapsed section. Rows push
/// `ReceivableDetailView`; the toolbar "+" creates a client.
/// Pushed inside an existing NavigationStack — it does not own one.
struct ReceivablesView: View {
    /// nil lists every client; non-nil scopes to one business.
    let business: Business?

    @Query(sort: \Account.sortOrder) private var accounts: [Account]

    @State private var isCreating = false
    @State private var showsSettled = false

    init(business: Business? = nil) {
        self.business = business
    }

    private var clients: [Account] {
        accounts.filter {
            $0.kind == .receivable && !$0.isArchived
                && (business == nil || $0.business?.id == business?.id)
        }
    }

    private var rows: [(account: Account, snapshot: ReceivableSnapshot)] {
        clients.map { ($0, ReceivableSnapshot.make(account: $0)) }
    }

    private var outstandingRows: [(account: Account, snapshot: ReceivableSnapshot)] {
        rows
            .filter { !$0.snapshot.isSettled }
            .sorted {
                $0.snapshot.outstanding != $1.snapshot.outstanding
                    ? $0.snapshot.outstanding > $1.snapshot.outstanding
                    : $0.account.name < $1.account.name
            }
    }

    /// Clients in credit — they prepaid, so later advances consume the
    /// credit. Not "đang nợ" and not "đã tất toán".
    private var prepaidRows: [(account: Account, snapshot: ReceivableSnapshot)] {
        rows
            .filter { $0.snapshot.hasPrepaid }
            .sorted {
                $0.snapshot.prepaid != $1.snapshot.prepaid
                    ? $0.snapshot.prepaid > $1.snapshot.prepaid
                    : $0.account.name < $1.account.name
            }
    }

    private var settledRows: [(account: Account, snapshot: ReceivableSnapshot)] {
        rows.filter { $0.snapshot.isSettled && !$0.snapshot.hasPrepaid }
    }

    /// "Tổng phải thu" — positive outstandings only; prepaid credit is
    /// excluded and totalled on its own.
    private var totalOutstanding: Int64 {
        rows.reduce(0) { $0 + $1.snapshot.outstanding }
    }

    private var totalPrepaid: Int64 {
        rows.reduce(0) { $0 + $1.snapshot.prepaid }
    }

    var body: some View {
        Group {
            if clients.isEmpty {
                EmptyStateView(
                    symbol: "person.badge.clock.fill",
                    title: "Chưa có khách hàng",
                    message: "Tạo một khách hàng để theo dõi tiền bạn ứng hộ — tiền ứng và tiền hoàn là chuyển khoản nên không ảnh hưởng báo cáo chi tiêu.",
                    actionTitle: "Thêm khách hàng",
                    action: { isCreating = true }
                )
            } else {
                list
            }
        }
        .navigationTitle(business.map { "Ứng hộ — \($0.name)" } ?? "Khoản ứng hộ khách")
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button {
                    isCreating = true
                } label: {
                    Image(systemName: "plus")
                }
                .accessibilityLabel("Thêm khách hàng")
            }
        }
        .sheet(isPresented: $isCreating) {
            ReceivableClientEditView(business: business)
        }
    }

    private var list: some View {
        List {
            Section {
                LabeledContent("Tổng khách đang nợ") {
                    AmountText(amount: totalOutstanding)
                        .font(.headline)
                }
                if totalPrepaid > 0 {
                    LabeledContent("Tổng khách ứng trước") {
                        Text(VND.format(totalPrepaid))
                            .font(.headline)
                            .monospacedDigit()
                            .foregroundStyle(.secondary)
                    }
                }
            }

            if !outstandingRows.isEmpty {
                Section("Đang nợ") {
                    ForEach(outstandingRows, id: \.account.id) { row in
                        clientRow(row.account, snapshot: row.snapshot)
                    }
                }
            }

            if !prepaidRows.isEmpty {
                Section("Khách ứng trước") {
                    ForEach(prepaidRows, id: \.account.id) { row in
                        clientRow(row.account, snapshot: row.snapshot)
                    }
                }
            }

            if !settledRows.isEmpty {
                Section {
                    DisclosureGroup(isExpanded: $showsSettled) {
                        ForEach(settledRows, id: \.account.id) { row in
                            clientRow(row.account, snapshot: row.snapshot)
                        }
                    } label: {
                        HStack {
                            Text("Đã tất toán")
                            Spacer()
                            Text("\(settledRows.count)")
                                .foregroundStyle(.secondary)
                                .monospacedDigit()
                        }
                    }
                }
            }
        }
        .listStyle(.insetGrouped)
    }

    private func clientRow(_ account: Account, snapshot: ReceivableSnapshot) -> some View {
        NavigationLink {
            ReceivableDetailView(account: account)
        } label: {
            HStack(spacing: 12) {
                IconBadge(symbol: account.icon, colorHex: account.colorHex, size: 36)
                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 6) {
                        Text(account.name)
                            .lineLimit(1)
                        if snapshot.isOverdue(now: .now) {
                            overdueTag
                        }
                    }
                    Text(account.business?.name ?? "Cá nhân")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                Spacer(minLength: 8)
                if snapshot.hasPrepaid {
                    Text("Khách ứng trước: \(VND.format(snapshot.prepaid))")
                        .font(.subheadline.weight(.semibold))
                        .monospacedDigit()
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .minimumScaleFactor(0.5)
                } else {
                    AmountText(amount: snapshot.outstanding)
                        .font(.subheadline.weight(.semibold))
                }
            }
        }
    }

    /// "Quá 30 ngày" — the oldest unpaid advance is more than a month old.
    private var overdueTag: some View {
        Text("Quá 30 ngày")
            .font(.caption2.weight(.medium))
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(Color.orange.opacity(0.15), in: Capsule())
            .foregroundStyle(.orange)
            .lineLimit(1)
    }
}

/// Sheet behind the "+" button: name, optional business and note create one
/// receivable `Account` — the client. Owns its NavigationStack.
struct ReceivableClientEditView: View {
    @Environment(\.modelContext) private var context
    @Environment(\.dismiss) private var dismiss
    @Query(sort: \Account.sortOrder) private var existingAccounts: [Account]
    @Query(sort: \Business.sortOrder) private var businesses: [Business]

    @State private var draft: ReceivableClientDraft
    @State private var error: ReceivableClientDraftError?
    @FocusState private var nameFocused: Bool

    init(business: Business? = nil) {
        _draft = State(initialValue: ReceivableClientDraft(business: business))
    }

    private var activeBusinesses: [Business] {
        businesses.filter { !$0.isArchived }
    }

    var body: some View {
        NavigationStack {
            Form {
                Section("Khách hàng") {
                    TextField("Tên khách hàng", text: $draft.name)
                        .focused($nameFocused)
                    Picker("Mảng kinh doanh", selection: $draft.business) {
                        Text("Không có").tag(nil as Business?)
                        ForEach(activeBusinesses, id: \.id) { business in
                            Text(business.name).tag(business as Business?)
                        }
                    }
                }
                Section("Ghi chú") {
                    TextField("Ghi chú (không bắt buộc)", text: $draft.note, axis: .vertical)
                        .lineLimit(2...4)
                }
            }
            .navigationTitle("Khách hàng mới")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Huỷ") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Thêm") { save() }
                }
            }
            .onAppear {
                DispatchQueue.main.async { nameFocused = true }
            }
            .alert(
                "Không thể lưu",
                isPresented: errorAlertPresented,
                presenting: error
            ) { _ in
                Button("OK", role: .cancel) {}
            } message: { draftError in
                Text(draftError.errorDescription ?? "")
            }
        }
    }

    private var errorAlertPresented: Binding<Bool> {
        Binding(
            get: { error != nil },
            set: { if !$0 { error = nil } }
        )
    }

    private func save() {
        if let validationError = draft.validate() {
            error = validationError
            return
        }
        let next = (existingAccounts.map(\.sortOrder).max() ?? -1) + 1
        context.insert(draft.makeAccount(sortOrder: next))
        try? context.save()
        dismiss()
    }
}

#Preview("Tất cả khách hàng") {
    let container = try! AppModelContainer.make(inMemory: true)
    let context = ModelContext(container)
    try! SeedData.seedIfNeeded(context: context)
    let cash = try! context.fetch(FetchDescriptor<Account>()).first!
    let ads = try! context.fetch(FetchDescriptor<Business>())
        .first { $0.name == "Chạy quảng cáo thuê" }!
    let calendar = AppCalendar.vietnam
    let clientA = Account(
        name: "Khách A — Spa", kind: .receivable, colorHex: "0A84FF", sortOrder: 1
    )
    clientA.business = ads
    let clientB = Account(
        name: "Khách B — Quán cafe", kind: .receivable, colorHex: "34C759", sortOrder: 2
    )
    let clientC = Account(
        name: "Khách C — cũ", kind: .receivable, colorHex: "8E8E93", sortOrder: 3
    )
    for client in [clientA, clientB, clientC] { context.insert(client) }
    context.insert(LedgerTransaction(
        kind: .transfer, amount: 15_000_000,
        date: calendar.date(byAdding: .day, value: -45, to: .now)!,
        account: cash, toAccount: clientA))
    context.insert(LedgerTransaction(
        kind: .transfer, amount: 3_000_000,
        date: calendar.date(byAdding: .day, value: -5, to: .now)!,
        account: cash, toAccount: clientB))
    return NavigationStack {
        ReceivablesView()
    }
    .modelContainer(container)
}
