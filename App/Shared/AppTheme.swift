import SwiftUI
import FinanceCore

/// Semantic colors and the pickable icon/color palettes shared by all
/// feature screens. Semantic system colors adapt to dark mode automatically.
enum AppTheme {

    // MARK: - Semantic transaction colors

    /// Thu — money in.
    static let income = Color(.systemGreen)
    /// Chi — money out.
    static let expense = Color(.systemRed)
    /// Chuyển khoản — movement between own accounts, neither income nor expense.
    static let transfer = Color(hex: "64748B")

    /// Semantic color for a transaction kind; use on amounts, icons and chips.
    static func color(for kind: TransactionKind) -> Color {
        switch kind {
        case .income: return income
        case .expense: return expense
        case .transfer: return transfer
        }
    }

    // MARK: - Pickable palette ("RRGGBB", stored on models)

    /// The 12 colors offered by `ColorHexPickerGrid`. Matches the palette
    /// used by the seed data so user-picked and seeded rows look alike.
    static let palette: [String] = [
        "FF3B30", "FF9500", "FFCC00", "34C759",
        "00C7BE", "30B0C7", "0A84FF", "5E5CE6",
        "AF52DE", "FF2D55", "A2845E", "8E8E93",
    ]

    // MARK: - Pickable SF Symbols

    /// Icon choices for categories, accounts and businesses — offered by
    /// `IconPickerGrid`. All names are valid SF Symbols on iOS 17.
    static let symbols: [String] = [
        // Money & accounts
        "banknote", "banknote.fill", "creditcard.fill", "wallet.pass.fill",
        "building.columns.fill", "percent", "chart.line.uptrend.xyaxis",
        "tray.and.arrow.down.fill", "arrow.uturn.backward.circle.fill",
        "doc.text.fill",
        // Food & living
        "fork.knife", "cup.and.saucer.fill", "wineglass.fill", "cart.fill",
        "bag.fill", "gift.fill", "house.fill", "building.2.fill",
        "bed.double.fill", "bolt.fill", "drop.fill", "wifi",
        // Transport & travel
        "car.fill", "fuelpump.fill", "airplane", "ticket.fill",
        // Work & business
        "briefcase.fill", "storefront.fill", "megaphone.fill", "target",
        "wrench.and.screwdriver.fill", "chevron.left.forwardslash.chevron.right",
        "person.2.fill",
        // Health, learning & fun
        "heart.fill", "cross.case.fill", "pills.fill", "graduationcap.fill",
        "book.fill", "iphone", "tv.fill", "music.note", "camera.fill",
        "gamecontroller.fill", "figure.run", "pawprint.fill",
        // Fallback
        "ellipsis.circle.fill",
    ]

    /// Symbol used when a model's icon string is empty or not pickable.
    static let fallbackSymbol = "tag.fill"
}

#Preview {
    ScrollView {
        VStack(alignment: .leading, spacing: 16) {
            HStack(spacing: 8) {
                Text("Thu").foregroundStyle(AppTheme.income)
                Text("Chi").foregroundStyle(AppTheme.expense)
                Text("Chuyển").foregroundStyle(AppTheme.transfer)
            }
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 36))], spacing: 8) {
                ForEach(AppTheme.palette, id: \.self) { hex in
                    Circle()
                        .fill(Color(hex: hex))
                        .frame(width: 32, height: 32)
                }
            }
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 32))], spacing: 8) {
                ForEach(AppTheme.symbols, id: \.self) { symbol in
                    Image(systemName: symbol)
                }
            }
        }
        .padding()
    }
}
