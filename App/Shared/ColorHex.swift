import SwiftUI

/// Pure parsing for "RRGGBB" hex strings stored on models (`colorHex`).
/// Kept separate from SwiftUI so it can be tested without rendering views.
enum HexColor {
    /// Parses "RRGGBB" (an optional leading "#" is allowed, surrounding
    /// whitespace is ignored) into sRGB components in 0...1.
    /// Returns nil for anything that is not exactly six hex digits.
    static func parse(_ string: String) -> (red: Double, green: Double, blue: Double)? {
        var text = string.trimmingCharacters(in: .whitespacesAndNewlines)
        if text.hasPrefix("#") { text.removeFirst() }
        guard text.count == 6, let value = UInt32(text, radix: 16) else { return nil }
        return (
            red: Double((value >> 16) & 0xFF) / 255,
            green: Double((value >> 8) & 0xFF) / 255,
            blue: Double(value & 0xFF) / 255
        )
    }
}

extension Color {
    /// Color from a model `colorHex` string ("RRGGBB", optional "#").
    /// Invalid input falls back to system gray so a bad string never breaks
    /// the layout or renders as an unexpected color.
    init(hex: String) {
        if let rgb = HexColor.parse(hex) {
            self.init(.sRGB, red: rgb.red, green: rgb.green, blue: rgb.blue, opacity: 1)
        } else {
            self.init(.systemGray)
        }
    }
}
