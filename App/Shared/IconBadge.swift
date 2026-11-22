import SwiftUI

/// An SF Symbol on a colored circle — the standard row icon for accounts,
/// categories and businesses. `colorHex` is the model string ("RRGGBB");
/// an empty `symbol` falls back to a default icon.
struct IconBadge: View {
    let symbol: String
    let colorHex: String
    let size: CGFloat

    init(symbol: String, colorHex: String, size: CGFloat = 40) {
        self.symbol = symbol
        self.colorHex = colorHex
        self.size = size
    }

    private var resolvedSymbol: String {
        symbol.isEmpty ? AppTheme.fallbackSymbol : symbol
    }

    var body: some View {
        Image(systemName: resolvedSymbol)
            .font(.system(size: size * 0.45, weight: .medium))
            .foregroundStyle(.white)
            .frame(width: size, height: size)
            .background(Color(hex: colorHex), in: Circle())
            .accessibilityHidden(true)
    }
}

#Preview {
    VStack(spacing: 12) {
        HStack(spacing: 12) {
            IconBadge(symbol: "fork.knife", colorHex: "FF9500")
            IconBadge(symbol: "banknote.fill", colorHex: "34C759")
            IconBadge(symbol: "car.fill", colorHex: "0A84FF")
            IconBadge(symbol: "", colorHex: "8E8E93")
        }
        HStack(spacing: 12) {
            IconBadge(symbol: "heart.fill", colorHex: "FF3B30", size: 28)
            IconBadge(symbol: "briefcase.fill", colorHex: "30D158", size: 56)
        }
    }
    .padding()
}
