import SwiftUI
import FinanceCore

/// One-hand đồng entry: a grouped display line plus large digit keys, a
/// "000" shortcut and backspace (long-press clears). All editing rules live
/// in `AmountKeypadState`; this view only forwards key presses.
struct AmountKeypad: View {
    @Binding var amount: Int64

    init(amount: Binding<Int64>) {
        _amount = amount
    }

    private let columns = Array(
        repeating: GridItem(.flexible(), spacing: 8),
        count: 3
    )

    var body: some View {
        VStack(spacing: 12) {
            Text(VND.format(amount))
                .font(.title.weight(.semibold))
                .monospacedDigit()
                .frame(maxWidth: .infinity, alignment: .trailing)
                .padding(.horizontal, 4)
                .accessibilityLabel("Số tiền")

            LazyVGrid(columns: columns, spacing: 8) {
                ForEach(1...9, id: \.self) { digit in
                    key("\(digit)", accessibilityLabel: "\(digit)") {
                        press { $0.appendDigit(digit) }
                    }
                }
                key("000") {
                    press { $0.appendTripleZero() }
                }
                key("0") {
                    press { $0.appendDigit(0) }
                }
                backspaceKey
            }
        }
    }

    private var backspaceKey: some View {
        Button {
            press { $0.backspace() }
        } label: {
            Image(systemName: "delete.backward.fill")
                .font(.title3)
                .frame(maxWidth: .infinity, minHeight: 56)
                .background(Color(.secondarySystemFill), in: RoundedRectangle(cornerRadius: 12))
        }
        .buttonStyle(KeypadButtonStyle())
        .accessibilityLabel("Xoá")
        .simultaneousGesture(
            LongPressGesture(minimumDuration: 0.5).onEnded { _ in
                press { $0.clear() }
            }
        )
    }

    private func key(
        _ title: String,
        accessibilityLabel: String? = nil,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            Text(title)
                .font(.title3.weight(.medium))
                .frame(maxWidth: .infinity, minHeight: 56)
                .background(Color(.secondarySystemFill), in: RoundedRectangle(cornerRadius: 12))
        }
        .buttonStyle(KeypadButtonStyle())
        .accessibilityLabel(accessibilityLabel ?? title)
    }

    /// Run the key press through the reducer, then publish the result.
    /// The reducer guarantees a non-negative, digit-limited value.
    private func press(_ edit: (inout AmountKeypadState) -> Void) {
        var state = AmountKeypadState(amount)
        edit(&state)
        amount = state.value
    }
}

/// Pressed keys dim — the only feedback a keypad needs.
private struct KeypadButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .foregroundStyle(.primary)
            .opacity(configuration.isPressed ? 0.4 : 1)
    }
}

#Preview {
    @Previewable @State var amount: Int64 = 1_250_000
    return AmountKeypad(amount: $amount)
        .padding()
}
