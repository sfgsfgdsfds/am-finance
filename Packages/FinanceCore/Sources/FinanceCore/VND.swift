/// Money handling for VND. Amounts are always stored as `Int64` đồng —
/// the currency has no decimal subunit, so there is never a fraction.
///
/// Display conventions (vi-VN):
/// - Full: `1.250.000 ₫` — "." groups thousands, space before ₫.
/// - Compact: `1,2 tr`, `3,5 tỷ`, `500 k`, `850 ₫` — "," is the decimal mark,
///   at most one fraction digit, rounded half-up.
/// - Parse accepts grouped digits (`1.250.000`), raw digits (`1250000`),
///   decimal + magnitude (`1,2tr`, `3,5 tỷ`), suffixes k/tr/tỷ and currency
///   marks (đ, ₫, vnd). Returns nil for anything ambiguous or non-numeric.
public enum VND {

    // MARK: - Full format: "1.250.000 ₫"

    public static func format(_ dong: Int64) -> String {
        let digits = String(dong.magnitude)
        var grouped = ""
        grouped.reserveCapacity(digits.count + digits.count / 3 + 2)
        for (i, ch) in digits.enumerated() {
            if i > 0, (digits.count - i) % 3 == 0 { grouped.append(".") }
            grouped.append(ch)
        }
        return (dong < 0 ? "-" : "") + grouped + " ₫"
    }

    // MARK: - Compact format: "1,2 tr", "3,5 tỷ", "500 k", "850 ₫"

    private static let compactTiers: [(threshold: UInt64, suffix: String)] = [
        (1_000_000_000, "tỷ"),
        (1_000_000, "tr"),
        (1_000, "k"),
    ]

    public static func compact(_ dong: Int64) -> String {
        let abs = dong.magnitude
        var tierIndex = compactTiers.firstIndex { abs >= $0.threshold }
        if tierIndex == nil { return format(dong) }

        var unit = compactTiers[tierIndex!].threshold
        var suffix = compactTiers[tierIndex!].suffix
        var whole = abs / unit
        var tenth = Int((abs % unit * 10 + unit / 2) / unit)
        if tenth == 10 { whole += 1; tenth = 0 }
        if whole >= 1_000, tierIndex! > 0 {
            // carry over to the next tier: 1000 k -> 1 tr
            tierIndex! -= 1
            unit = compactTiers[tierIndex!].threshold
            suffix = compactTiers[tierIndex!].suffix
            whole = 1
            tenth = 0
        }

        let number = tenth == 0 ? "\(whole)" : "\(whole),\(tenth)"
        return (dong < 0 ? "-" : "") + number + " " + suffix
    }

    // MARK: - Parse

    private static let currencySuffixes = ["đồng", "dong", "vnd", "vnđ", "₫", "đ", "d"]

    /// (suffix, 10^exponent). Longer suffixes first so "triệu" wins over "m".
    private static let magnitudeSuffixes: [(suffix: String, exponent: Int)] = [
        ("triệu", 6), ("trieu", 6),
        ("nghìn", 3), ("nghin", 3), ("ngàn", 3), ("ngan", 3),
        ("tr", 6), ("ty", 9), ("ti", 9), ("tỷ", 9), ("tỉ", 9),
        ("m", 6), ("k", 3), ("t", 9), ("b", 9),
    ]

    /// Parses user-typed text into đồng. Returns nil for empty, non-numeric,
    /// ambiguous or overflowing input. Examples:
    ///   "1.250.000" -> 1_250_000     "1250000" -> 1_250_000
    ///   "1,2tr"     -> 1_200_000     "3,5 tỷ"  -> 3_500_000_000
    ///   "500k"      -> 500_000       "-2tr"    -> -2_000_000
    ///   "1.000đ"    -> 1_000         "abc"     -> nil
    public static func parse(_ raw: String) -> Int64? {
        var s = String(raw.lowercased().filter { !$0.isWhitespace && $0 != "_" })
        guard !s.isEmpty else { return nil }

        if s.hasPrefix("₫") { s.removeFirst() }
        var negative = false
        if s.hasPrefix("-") { negative = true; s.removeFirst() }
        else if s.hasPrefix("+") { s.removeFirst() }
        guard !s.isEmpty else { return nil }

        for suffix in currencySuffixes where s.hasSuffix(suffix) {
            s.removeLast(suffix.count)
            break
        }
        guard !s.isEmpty else { return nil }

        var exponent = 0
        for (suffix, exp) in magnitudeSuffixes where s.hasSuffix(suffix) {
            s.removeLast(suffix.count)
            exponent = exp
            break
        }
        guard !s.isEmpty else { return nil }

        // With a magnitude suffix the last "." or "," is a decimal mark;
        // without one, separators are only allowed as thousands groupers.
        var intPart = Substring(s)
        var fracPart: Substring = ""
        if exponent > 0, let idx = s.lastIndex(where: { $0 == "." || $0 == "," }) {
            intPart = s[..<idx]
            fracPart = s[s.index(after: idx)...]
        }

        guard let whole = groupedNumber(intPart), fracPart.allSatisfy(\.isNumber) else {
            return nil
        }

        var (total, overflow) = whole.multipliedReportingOverflow(by: pow10(exponent))
        guard !overflow else { return nil }

        let kept = fracPart.prefix(exponent)
        if let frac = Int64(kept), frac > 0 {
            let scaled = frac * pow10(exponent - kept.count)
            (total, overflow) = total.addingReportingOverflow(scaled)
            guard !overflow else { return nil }
        }
        return negative ? -total : total
    }

    /// Strict "digits with thousands separators": bare digits, or groups of
    /// exactly 3 digits after a first group of 1-3 ("1.250.000", "12,500").
    private static func groupedNumber(_ s: Substring) -> Int64? {
        guard !s.isEmpty else { return nil }
        var groups: [[Character]] = [[]]
        for ch in s {
            if ch.isNumber {
                groups[groups.count - 1].append(ch)
            } else if ch == "." || ch == "," {
                groups.append([])
            } else {
                return nil
            }
        }
        guard groups.allSatisfy({ !$0.isEmpty }) else { return nil }
        if groups.count > 1 {
            guard groups[0].count <= 3,
                  groups.dropFirst().allSatisfy({ $0.count == 3 }) else { return nil }
        }
        return Int64(groups.map { String($0) }.joined())
    }

    private static func pow10(_ exponent: Int) -> Int64 {
        var result: Int64 = 1
        for _ in 0..<exponent { result *= 10 }
        return result
    }
}
