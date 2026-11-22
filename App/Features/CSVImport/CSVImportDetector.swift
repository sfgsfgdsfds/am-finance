import Foundation
import CoreFoundation

/// The date layouts a bank statement can use, each with an optional
/// "HH:mm[:ss]" time part after a space or a "T" separator.
enum CSVImportDateFormat: String, Codable, CaseIterable, Sendable {
    /// 22/11/2026
    case dayMonthYearSlash
    /// 22-11-2026
    case dayMonthYearDash
    /// 22.11.2026
    case dayMonthYearDot
    /// 2026-11-22 (also 2026-11-22T14:05:00)
    case yearMonthDayDash
    /// 2026/11/22
    case yearMonthDaySlash
    /// 22/11/26
    case dayMonthYearSlashShort
    /// 22-11-26
    case dayMonthYearDashShort

    var displayName: String {
        switch self {
        case .dayMonthYearSlash: return "22/11/2026 (ngày/tháng/năm)"
        case .dayMonthYearDash: return "22-11-2026 (ngày-tháng-năm)"
        case .dayMonthYearDot: return "22.11.2026 (ngày.tháng.năm)"
        case .yearMonthDayDash: return "2026-11-22 (năm-tháng-ngày)"
        case .yearMonthDaySlash: return "2026/11/22 (năm/tháng/ngày)"
        case .dayMonthYearSlashShort: return "22/11/26 (năm 2 số)"
        case .dayMonthYearDashShort: return "22-11-26 (năm 2 số)"
        }
    }

    /// The character splitting day/month/year inside the date part.
    fileprivate var separator: Character {
        switch self {
        case .dayMonthYearSlash, .dayMonthYearSlashShort, .yearMonthDaySlash: return "/"
        case .dayMonthYearDash, .dayMonthYearDashShort, .yearMonthDayDash: return "-"
        case .dayMonthYearDot: return "."
        }
    }

    /// Year first (ISO order) or last (VN order).
    fileprivate var yearFirst: Bool {
        self == .yearMonthDayDash || self == .yearMonthDaySlash
    }

    fileprivate var twoDigitYear: Bool {
        self == .dayMonthYearSlashShort || self == .dayMonthYearDashShort
    }
}

/// How the statement writes numbers: which character groups thousands and
/// which marks the decimal part. Only the ambiguous one-separator shapes
/// (e.g. "12,345") differ between the two styles.
enum CSVImportNumberFormatStyle: String, Codable, CaseIterable, Sendable {
    /// Vietnamese: "." groups thousands, "," is the decimal mark.
    case vietnamese
    /// English: "," groups thousands, "." is the decimal mark.
    case international

    var displayName: String {
        switch self {
        case .vietnamese: return "1.234.567 (kiểu Việt Nam)"
        case .international: return "1,234,567.89 (kiểu quốc tế)"
        }
    }

    fileprivate var groupSeparator: Character {
        self == .vietnamese ? "." : ","
    }

    fileprivate var decimalSeparator: Character {
        self == .vietnamese ? "," : "."
    }
}

/// File-reading and shape detection for CSV statements: text encoding,
/// the field separator, the header row under any preamble, plus guesses
/// for the date format, number format and column roles from Vietnamese
/// and English header names. All pure functions — no I/O beyond the
/// `Data` handed in.
enum CSVImportDetector {

    // MARK: - Encoding

    /// Windows-1258 ("Vietnamese (Windows)") via CoreFoundation — older
    /// bank exports saved on Windows use it for Vietnamese text.
    static let windowsVietnameseEncoding = String.Encoding(
        rawValue: CFStringConvertEncodingToNSStringEncoding(
            CFStringEncoding(CFStringEncodings.windowsVietnamese.rawValue)))

    /// Best-effort decode: UTF-8 with or without a BOM, UTF-16 via BOM or
    /// a NUL-byte heuristic, Windows-1258, then Latin-1 which always works
    /// (a wrong guess degrades accents, it never fails).
    static func decode(_ data: Data) -> String {
        guard !data.isEmpty else { return "" }

        if data.starts(with: [0xEF, 0xBB, 0xBF]) {
            if let text = String(data: data.dropFirst(3), encoding: .utf8) {
                return text
            }
        }
        if data.starts(with: [0xFE, 0xFF]),
           let text = String(data: data.dropFirst(2), encoding: .utf16BigEndian) {
            return text
        }
        if data.starts(with: [0xFF, 0xFE]),
           let text = String(data: data.dropFirst(2), encoding: .utf16LittleEndian) {
            return text
        }
        if let text = String(data: data, encoding: .utf8) {
            return text
        }

        // UTF-16 without a BOM: ASCII-heavy CSV shows NULs on one side.
        let sample = data.prefix(400)
        var evenZeros = 0
        var oddZeros = 0
        for (index, byte) in sample.enumerated() where byte == 0 {
            if index % 2 == 0 { evenZeros += 1 } else { oddZeros += 1 }
        }
        if max(evenZeros, oddZeros) >= sample.count / 4 {
            let encodings: [String.Encoding] = evenZeros > oddZeros
                ? [.utf16BigEndian, .utf16LittleEndian]
                : [.utf16LittleEndian, .utf16BigEndian]
            for encoding in encodings {
                if let text = String(data: data, encoding: encoding) {
                    return text
                }
            }
        }

        if let text = String(data: data, encoding: windowsVietnameseEncoding) {
            return text
        }
        return String(data: data, encoding: .isoLatin1) ?? ""
    }

    // MARK: - Delimiter

    /// Tries each separator: the winner explains the most columns across
    /// the most rows. Defaults to comma for single-column files.
    static func detectDelimiter(_ text: String) -> CSVImportDelimiter {
        var best = CSVImportDelimiter.comma
        var bestScore = 0
        for candidate in CSVImportDelimiter.allCases {
            let rows = CSVImportParser.parse(text, delimiter: candidate)
            var frequency: [Int: Int] = [:]
            for row in rows.prefix(200) where row.count > 1 {
                frequency[row.count, default: 0] += 1
            }
            guard let (columns, rowsWithThatCount) = frequency.max(by: {
                $0.value != $1.value ? $0.value < $1.value : $0.key < $1.key
            }) else { continue }
            let score = columns * rowsWithThatCount
            if score > bestScore {
                bestScore = score
                best = candidate
            }
        }
        return best
    }

    // MARK: - Header row

    /// A plausible column title: short, mostly letters — so a preamble of
    /// bank name / report title / blank lines doesn't count, and neither
    /// does a data row of dates and numbers.
    static func looksLikeColumnTitle(_ cell: String) -> Bool {
        let trimmed = cell.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.count >= 2, trimmed.count <= 60,
              trimmed.contains(where: { $0.isLetter })
        else { return false }
        let digits = trimmed.filter(\.isNumber).count
        return digits * 2 <= trimmed.count
    }

    private static func nonEmptyCellCount(_ row: [String]) -> Int {
        row.filter { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }.count
    }

    /// Index of the header row: the first row with at least three
    /// title-looking cells that is followed by a data row (the next
    /// non-empty row has at least two filled cells). Returns nil when the
    /// file has no table.
    static func findHeaderRow(in rows: [[String]]) -> Int? {
        for index in rows.indices {
            guard rows[index].filter(looksLikeColumnTitle).count >= 3 else { continue }
            for next in (index + 1)..<rows.count {
                let filled = nonEmptyCellCount(rows[next])
                if filled == 0 { continue }
                if filled >= 2 { return index }
                break
            }
        }
        return nil
    }

    // MARK: - Column guessing

    /// Header keywords per role, already folded (case/diacritics removed,
    /// whitespace collapsed) the way `SettingsNameNormalizer.fold` does.
    /// Exact matches always count; keywords of 4+ characters also match as
    /// a substring so "Số tiền ghi nợ" still finds "ghi nợ".
    private static let headerKeywords: [(role: CSVImportColumnRole, names: [String])] = [
        (.date, [
            "ngay", "ngay giao dich", "ngay hieu luc", "ngay gd", "ngay val",
            "date", "transaction date", "posting date", "effective date",
            "value date", "thoi gian", "time",
        ]),
        (.moneyOut, [
            "ghi no", "no", "phat sinh no", "ps no", "tien ra", "chi",
            "debit", "debit amount", "rut", "rut tien", "withdrawal",
            "withdrawal amount", "payment", "dr", "so tien ghi no", "so tien rut",
        ]),
        (.moneyIn, [
            "ghi co", "co", "phat sinh co", "ps co", "tien vao", "thu",
            "credit", "credit amount", "gui", "gui tien", "nop tien",
            "deposit", "deposit amount", "cr", "so tien ghi co", "so tien gui",
        ]),
        (.amount, [
            "so tien", "so tien giao dich", "amount", "thanh tien",
            "gia tri", "transaction amount", "money", "tong tien",
            "bien dong", "bien dong so du", "debit/credit",
        ]),
        (.description, [
            "noi dung", "noi dung giao dich", "dien giai", "mo ta",
            "mo ta giao dich", "description", "ghi chu", "chi tiet",
            "transaction details", "details", "narrative", "remark",
            "remarks", "memo", "particulars", "content", "ly do",
        ]),
        (.reference, [
            "so tham chieu", "ma gd", "ma giao dich", "reference",
            "reference number", "ref", "ref no", "transaction id", "id",
            "so chung tu", "so ct", "trace", "ft", "seq", "so seq",
            "deal code", "but toan",
        ]),
    ]

    /// Index of the first column whose folded name matches one of `names`:
    /// exact matches win over substring matches.
    private static func columnIndex(
        matching names: [String],
        in foldedHeaders: [String],
        excluding used: Set<Int>
    ) -> Int? {
        for index in foldedHeaders.indices where !used.contains(index) {
            if names.contains(foldedHeaders[index]) { return index }
        }
        for index in foldedHeaders.indices where !used.contains(index) {
            let header = foldedHeaders[index]
            if names.contains(where: { $0.count >= 4 && header.contains($0) }) {
                return index
            }
        }
        return nil
    }

    /// Guesses the column mapping from header names. Money-out/money-in
    /// are resolved before the generic signed amount so "Số tiền ghi nợ"
    /// claims the debit role instead of the signed one.
    static func guessMapping(headers: [String]) -> CSVImportMapping {
        let folded = headers.map {
            SettingsNameNormalizer.fold($0).lowercased()
        }
        var used: Set<Int> = []
        var mapping = CSVImportMapping()

        func take(_ role: CSVImportColumnRole) -> Int? {
            guard let names = headerKeywords.first(where: { $0.role == role })?.names,
                  let index = columnIndex(
                      matching: names, in: folded, excluding: used)
            else { return nil }
            used.insert(index)
            return index
        }

        mapping.moneyOutColumn = take(.moneyOut)
        mapping.moneyInColumn = take(.moneyIn)
        mapping.dateColumn = take(.date)
        mapping.descriptionColumn = take(.description)
        mapping.referenceColumn = take(.reference)
        if mapping.moneyOutColumn == nil || mapping.moneyInColumn == nil {
            mapping.amountColumn = take(.amount)
        }
        // A clean debit/credit pair never needs the signed column.
        if mapping.moneyOutColumn != nil && mapping.moneyInColumn != nil {
            mapping.amountColumn = nil
        }
        return mapping
    }

    // MARK: - Date format

    /// The format that parses the most non-empty samples; nil when none do.
    static func detectDateFormat(
        _ samples: [String],
        calendar: Calendar = AppCalendar.vietnam
    ) -> CSVImportDateFormat? {
        var best: (format: CSVImportDateFormat, count: Int)?
        for format in CSVImportDateFormat.allCases {
            let count = samples.reduce(0) {
                $0 + (parseDate($1, format: format, calendar: calendar) != nil ? 1 : 0)
            }
            if count > (best?.count ?? 0) {
                best = (format, count)
            }
        }
        return best?.format
    }

    /// Strict hand-rolled parse: components are assigned by the format's
    /// order, ranges are checked, and the rebuilt date must round-trip
    /// exactly (so 31/02 never silently becomes March).
    static func parseDate(
        _ raw: String,
        format: CSVImportDateFormat,
        calendar: Calendar = AppCalendar.vietnam
    ) -> Date? {
        var text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return nil }

        var timePart: Substring = ""
        if let cut = text.firstIndex(where: { $0 == " " || $0 == "T" || $0 == "t" }) {
            timePart = text[text.index(after: cut)...]
            text = String(text[..<cut])
            // "22/11/2026 14:05 lúc" — keep only the first time token.
            if let space = timePart.firstIndex(of: " ") {
                timePart = timePart[..<space]
            }
        }

        let parts = text.split(separator: format.separator)
        guard parts.count == 3,
              let first = Int(parts[0]),
              let second = Int(parts[1]),
              let third = Int(parts[2])
        else { return nil }

        let day, month, year: Int
        if format.yearFirst {
            (year, month, day) = (first, second, third)
        } else {
            (day, month, year) = (first, second, third)
        }
        let fullYear = format.twoDigitYear ? year + 2000 : year
        guard fullYear >= 1900, fullYear <= 2100,
              (1...12).contains(month), (1...31).contains(day)
        else { return nil }

        var hour = 0
        var minute = 0
        var secondOfMinute = 0
        if !timePart.isEmpty {
            let time = timePart.split(separator: ":")
            guard (2...3).contains(time.count),
                  let h = Int(time[0]), let m = Int(time[1]),
                  (0...23).contains(h), (0...59).contains(m)
            else { return nil }
            if time.count == 3 {
                guard let s = Int(time[2]), (0...59).contains(s) else { return nil }
                secondOfMinute = s
            }
            hour = h
            minute = m
        }

        guard let date = calendar.date(from: DateComponents(
            year: fullYear, month: month, day: day,
            hour: hour, minute: minute, second: secondOfMinute
        )) else { return nil }
        // Round-trip check — Calendar normalizes overflow silently.
        let back = calendar.dateComponents(
            [.year, .month, .day, .hour, .minute, .second], from: date)
        guard back.year == fullYear, back.month == month, back.day == day,
              back.hour == hour, back.minute == minute,
              back.second == secondOfMinute
        else { return nil }
        return date
    }

    // MARK: - Number format

    /// Currency tokens stripped from an amount cell before parsing.
    private static let currencyTokens = [
        "đồng", "dong", "vnd", "vnđ", "đ", "₫", "d",
    ]

    /// Signed đồng from a statement cell, rounded to the nearest đồng.
    /// Accepts both separator styles, currency marks, "(x)" and
    /// leading/trailing "+" and "−". Returns nil on anything non-numeric.
    static func parseAmount(
        _ raw: String,
        style: CSVImportNumberFormatStyle
    ) -> Int64? {
        guard let value = parseDecimal(raw, style: style) else { return nil }
        let rounded = value.rounded(.toNearestOrAwayFromZero)
        guard rounded >= Double(Int64.min), rounded <= Double(Int64.max) else { return nil }
        return Int64(rounded)
    }

    /// The parsed value before đồng rounding — kept fractional so format
    /// detection can tell a real decimal from a regrouped integer.
    static func parseDecimal(
        _ raw: String,
        style: CSVImportNumberFormatStyle
    ) -> Double? {
        var text = raw.trimmingCharacters(
            in: .whitespacesAndNewlines.union(.init(charactersIn: "\u{00A0}")))
        guard !text.isEmpty else { return nil }

        var negative = false
        if text.hasPrefix("("), text.hasSuffix(")") {
            negative = true
            text = String(text.dropFirst().dropLast())
                .trimmingCharacters(in: .whitespaces)
        }
        if text.hasPrefix("-") || text.hasPrefix("−") {  // U+2212 minus
            negative = true
            text = String(text.dropFirst())
        } else if text.hasPrefix("+") {
            text = String(text.dropFirst())
        }
        if text.hasSuffix("-") || text.hasSuffix("−") {
            negative = true
            text = String(text.dropLast())
        } else if text.hasSuffix("+") {
            text = String(text.dropLast())
        }
        text = text.trimmingCharacters(in: .whitespacesAndNewlines)
        text = text.replacingOccurrences(of: "\u{00A0}", with: "")
        text = text.replacingOccurrences(of: " ", with: "")
        for token in currencyTokens {
            if text.lowercased().hasSuffix(token) {
                text = String(text.dropLast(token.count))
                break
            }
        }
        guard !text.isEmpty,
              text.allSatisfy({ $0.isNumber || $0 == "." || $0 == "," })
        else { return nil }

        let digits = text.filter(\.isNumber)
        guard !digits.isEmpty else { return nil }

        var integer = text
        var fraction = ""

        let dots = text.filter { $0 == "." }.count
        let commas = text.filter { $0 == "," }.count
        if dots > 0 && commas > 0 {
            // Both separators: the last one is the decimal mark, the
            // earlier one groups thousands.
            guard let lastSep = text.lastIndex(where: { $0 == "." || $0 == "," }) else {
                return nil
            }
            integer = String(text[..<lastSep].filter { $0 != "." && $0 != "," })
            fraction = String(text[text.index(after: lastSep)...])
        } else if dots + commas == 1 {
            let separator: Character = dots == 1 ? "." : ","
            let split = text.split(separator: separator, omittingEmptySubsequences: false)
            let after = split.count == 2 ? split[1].count : 0
            if after == 3 {
                // "12,345": grouped in the style whose grouping char this
                // is, a decimal in the other style.
                if separator == style.groupSeparator {
                    integer = split.joined()
                    fraction = ""
                } else {
                    integer = String(split[0])
                    fraction = String(split[1])
                }
            } else if after <= 2, after > 0 {
                integer = String(split[0])
                fraction = String(split[1])
            } else if after == 0 {
                integer = String(split[0])
            } else {
                return nil
            }
        } else if dots + commas > 1 {
            // Repeated separator: every group after the first must be 3
            // digits or it isn't a number at all ("1,2,3" fails both ways).
            let separator: Character = dots > 0 ? "." : ","
            let groups = text.split(
                separator: separator, omittingEmptySubsequences: false)
            guard groups.count >= 2,
                  groups[0].count >= 1, groups[0].count <= 3,
                  groups.dropFirst().allSatisfy({ $0.count == 3 })
            else { return nil }
            integer = groups.joined()
        }

        guard !integer.isEmpty,
              integer.allSatisfy(\.isNumber),
              fraction.allSatisfy(\.isNumber)
        else { return nil }

        var value = Double(integer) ?? 0
        if !fraction.isEmpty {
            var scale = 1.0
            for _ in fraction { scale *= 10 }
            value += (Double(fraction) ?? 0) / scale
        }
        return negative ? -value : value
    }

    /// Picks the style that parses the most samples, preferring the one
    /// that yields whole đồng (statements almost never carry decimals —
    /// that is what disambiguates "12,345").
    static func detectNumberFormat(
        _ samples: [String]
    ) -> CSVImportNumberFormatStyle {
        let cells = samples
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        func score(_ style: CSVImportNumberFormatStyle) -> (parsed: Int, whole: Int) {
            var parsed = 0
            var whole = 0
            for cell in cells {
                guard let value = parseDecimal(cell, style: style) else { continue }
                parsed += 1
                if value.rounded(.toNearestOrAwayFromZero) == value { whole += 1 }
            }
            return (parsed, whole)
        }
        let vietnamese = score(.vietnamese)
        let international = score(.international)
        if vietnamese == international { return .vietnamese }
        return vietnamese > international ? .vietnamese : .international
    }
}

/// The header-role slots column guessing fills.
enum CSVImportColumnRole: String, Codable, Sendable {
    case date
    case amount
    case moneyOut
    case moneyIn
    case description
    case reference
}
