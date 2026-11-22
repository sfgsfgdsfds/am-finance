import SwiftUI
import SwiftData
import FinanceCore

/// "Đặt số dư thực tế" — for accounts whose transactions arrive without
/// balances (e.g. imported from the bank). The user types the real balance
/// as of now (the real debt, positive, on liabilities); the sheet shows the
/// computed balance and the difference, then offers the two reconcile modes
/// of `BalanceTrendAnchor`. Presented as a sheet, so it owns a
/// `NavigationStack`.
struct BalanceTrendAnchorSheet: View {
    let account: Account

    @Environment(\.modelContext) private var context
    @Environment(\.dismiss) private var dismiss
    @State private var typed: Int64
    @State private var mode: BalanceTrendAnchorMode = .openingBalance

    init(account: Account) {
        self.account = account
        // The shared ledger cache when the account is already in a
        // container — otherwise the direct relationship walk.
        let balance = account.modelContext
            .map {
                LedgerBalanceStores.shared(for: $0.container)
                    .balance(of: account)
            } ?? account.balance
        let displayed = BalanceTrendSeries.displayed(
            balance, isLiability: account.kind.isLiability
        )
        _typed = State(initialValue: max(0, displayed))
    }

    private var isLiability: Bool { account.kind.isLiability }

    private var computedBalance: Int64 {
        LedgerBalanceStores.shared(for: context.container)
            .balance(of: account)
    }

    /// Signed target behind the keypad number (debt → negative balance).
    private var target: Int64 {
        BalanceTrendAnchor.signedTarget(typed: typed, isLiability: isLiability)
    }

    /// The delta still needed — nil only on Int64 overflow.
    private var delta: Int64? {
        BalanceTrendAnchor.adjustmentDelta(
            computed: computedBalance, target: target)
    }

    /// "Chênh lệch" in displayed terms: positive = the user typed more than
    /// the app shows. 0 disables the action.
    private var displayedDifference: Int64 {
        BalanceTrendAnchor.displayedDifference(
            computed: computedBalance, target: target, isLiability: isLiability
        ) ?? 0
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Text(
                        isLiability
                            ? "Nhập dư nợ thực tế của \"\(account.name)\" tính đến hiện tại."
                            : "Nhập số dư thực tế của \"\(account.name)\" tính đến hiện tại."
                    )
                    .font(.subheadline)
                    .foregroundStyle(.secondary)

                    AmountKeypad(amount: $typed)
                        .padding(.vertical, 4)

                    LabeledContent(
                        isLiability ? "Dư nợ trong app" : "Số dư trong app",
                        value: VND.format(
                            BalanceTrendSeries.displayed(computedBalance, isLiability: isLiability)
                        )
                    )
                    LabeledContent {
                        AmountText(amount: displayedDifference)
                    } label: {
                        Text("Chênh lệch")
                    }
                }

                Section {
                    ForEach(BalanceTrendAnchorMode.allCases) { option in
                        Button {
                            mode = option
                        } label: {
                            HStack(alignment: .top, spacing: 12) {
                                VStack(alignment: .leading, spacing: 4) {
                                    Text(option.displayName)
                                        .foregroundStyle(.primary)
                                    Text(option.explanation)
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                }
                                Spacer(minLength: 8)
                                if mode == option {
                                    Image(systemName: "checkmark")
                                        .font(.body.weight(.semibold))
                                        .foregroundStyle(Color.accentColor)
                                }
                            }
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .accessibilityAddTraits(mode == option ? .isSelected : [])
                    }
                } header: {
                    Text("Cách xử lý")
                } footer: {
                    if delta == 0 {
                        Text("Số dư đã khớp — không cần điều chỉnh.")
                    }
                }
            }
            .navigationTitle("Đặt số dư thực tế")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Huỷ") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Áp dụng") { apply() }
                        .disabled(delta == nil || delta == 0)
                }
            }
        }
    }

    private func apply() {
        let computed = computedBalance
        switch mode {
        case .openingBalance:
            if let newOpening = BalanceTrendAnchor.newOpeningBalance(
                opening: account.openingBalance, computed: computed, target: target
            ) {
                account.openingBalance = newOpening
            }
        case .adjustmentTransaction:
            if let adjustment = BalanceTrendAnchor.adjustment(computed: computed, target: target) {
                context.insert(LedgerTransaction(
                    kind: adjustment.kind,
                    amount: adjustment.amount,
                    note: BalanceTrendAnchor.adjustmentNote,
                    account: account
                ))
            }
        }
        dismiss()
    }
}

#Preview("Tài khoản ngân hàng") {
    let container = try! AppModelContainer.make(inMemory: true)
    let context = ModelContext(container)
    let account = Account(
        name: "Ngân hàng", kind: .bank,
        openingBalance: 8_000_000, colorHex: "0A84FF"
    )
    context.insert(account)
    context.insert(LedgerTransaction(
        kind: .expense, amount: 1_200_000, note: "Hoá đơn", account: account
    ))
    return BalanceTrendAnchorSheet(account: account)
        .modelContainer(container)
}

#Preview("Thẻ tín dụng") {
    let container = try! AppModelContainer.make(inMemory: true)
    let context = ModelContext(container)
    let card = Account(
        name: "Thẻ Visa", kind: .creditCard,
        openingBalance: -3_500_000, colorHex: "FF9500"
    )
    context.insert(card)
    return BalanceTrendAnchorSheet(account: card)
        .modelContainer(container)
}
