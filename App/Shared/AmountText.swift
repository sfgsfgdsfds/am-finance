import SwiftUI
import FinanceCore

/// A money amount rendered through `VND` with monospaced digits and a
/// semantic color. With a `kind` it signs the text ("+" thu, "−" chi) and
/// colors it green/red/blue-gray; without a kind it signs and colors by the
/// amount's own sign.
struct AmountText: View {
    let amount: Int64
    let kind: TransactionKind?
    let compact: Bool

    init(amount: Int64, kind: TransactionKind? = nil, compact: Bool = false) {
        self.amount = amount
        self.kind = kind
        self.compact = compact
    }

    var body: some View {
        Text(text)
            .monospacedDigit()
            .foregroundStyle(color)
    }

    private var text: String {
        let format = compact ? VND.compact : VND.format
        switch kind {
        case .income:
            return "+" + format(amount)
        case .expense:
            return format(-amount)
        case .transfer:
            return format(amount)
        case nil:
            return amount > 0 ? "+" + format(amount) : format(amount)
        }
    }

    private var color: Color {
        switch kind {
        case .income: return AppTheme.income
        case .expense: return AppTheme.expense
        case .transfer: return AppTheme.transfer
        case nil:
            if amount > 0 { return AppTheme.income }
            if amount < 0 { return AppTheme.expense }
            return .primary
        }
    }
}

#Preview {
    VStack(alignment: .trailing, spacing: 8) {
        AmountText(amount: 1_250_000, kind: .income)
        AmountText(amount: 1_250_000, kind: .expense)
        AmountText(amount: 1_250_000, kind: .transfer)
        AmountText(amount: 1_250_000)
        AmountText(amount: -500_000)
        AmountText(amount: 3_500_000_000, compact: true)
    }
    .font(.title3)
    .padding()
}
