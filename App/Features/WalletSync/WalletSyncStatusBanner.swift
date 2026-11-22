import SwiftUI
import SwiftData
import FinanceCore

/// Compact dashboard card for the wallet link: pending-review count, the
/// last sync time or the last error, a manual refresh, and a link into the
/// inbox. Self-contained — queries its own data and owns a coordinator —
/// and renders nothing until at least one account is linked.
struct WalletSyncStatusBanner: View {
    @Environment(\.modelContext) private var context
    @Query(sort: \Account.sortOrder) private var accounts: [Account]
    @Query private var pending: [LedgerTransaction]

    private let coordinator: WalletSyncCoordinator?
    private let defaults: UserDefaults
    @State private var own: WalletSyncCoordinator?

    init(
        coordinator: WalletSyncCoordinator? = nil,
        defaults: UserDefaults = .standard
    ) {
        self.coordinator = coordinator
        self.defaults = defaults
        _pending = Query(
            filter: #Predicate { $0.needsReview == true },
            sort: \.date, order: .reverse)
    }

    private var linked: [Account] {
        accounts.filter {
            $0.externalSource == WalletSyncEngine.externalSource
        }
    }

    private var resolved: WalletSyncCoordinator? {
        coordinator ?? own
    }

    var body: some View {
        if !linked.isEmpty {
            card
                .task {
                    if resolved == nil {
                        own = .live(context: context, defaults: defaults)
                    }
                }
        }
    }

    private var card: some View {
        HStack(spacing: 12) {
            NavigationLink {
                WalletSyncInboxView()
            } label: {
                HStack(spacing: 12) {
                    IconBadge(
                        symbol: pending.isEmpty
                            ? "checkmark.circle.fill" : "tray.full.fill",
                        colorHex: pending.isEmpty ? "0A84FF" : "FF9500",
                        size: 36)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(title)
                            .font(.subheadline.weight(.medium))
                            .foregroundStyle(.primary)
                        Text(subtitle)
                            .font(.caption)
                            .foregroundStyle(
                                resolved?.errorMessage != nil
                                    ? Color.red : Color.secondary)
                            .lineLimit(2)
                    }
                }
            }
            .buttonStyle(.plain)
            Spacer(minLength: 4)
            Button {
                Task { await resolved?.syncNow() }
            } label: {
                if resolved?.isSyncing == true {
                    ProgressView()
                } else {
                    Image(systemName: "arrow.clockwise")
                        .font(.body.weight(.semibold))
                }
            }
            .disabled(resolved == nil || resolved?.isSyncing == true)
            .accessibilityLabel("Đồng bộ ngay")
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            Color(.secondarySystemGroupedBackground),
            in: RoundedRectangle(cornerRadius: 16)
        )
        .accessibilityElement(children: .contain)
    }

    private var title: String {
        pending.isEmpty
            ? "Đồng bộ ngân hàng"
            : "\(pending.count) giao dịch chờ phân loại"
    }

    private var subtitle: String {
        if let error = resolved?.errorMessage { return error }
        if let last = resolved?.lastSyncAt {
            return "Đồng bộ: \(AppDateFormat.shortDate(last)) \(AppDateFormat.time(last))"
        }
        return "Chưa đồng bộ — chạm mũi tên để đồng bộ."
    }
}

#Preview {
    let container = try! AppModelContainer.make(inMemory: true)
    let context = ModelContext(container)
    try! SeedData.seedIfNeeded(context: context)
    let bank = Account(
        name: "VPBank *1234", kind: .bank,
        icon: "building.columns.fill", colorHex: "0A84FF")
    bank.externalSource = "wallet.amx.vn"
    bank.externalAccountID = "12"
    context.insert(bank)
    context.insert(LedgerTransaction(
        kind: .expense, amount: 155_000,
        note: "GRAB BIKE SGN", account: bank, needsReview: true))
    context.insert(LedgerTransaction(
        kind: .income, amount: 15_000_000,
        note: "LUONG THANG 11", account: bank, needsReview: true))
    return ScrollView {
        WalletSyncStatusBanner()
            .padding(16)
    }
    .background(Color(.systemGroupedBackground))
    .modelContainer(container)
}
