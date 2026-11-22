import Foundation

/// Search matching for the transactions list: Vietnamese diacritic- and
/// case-insensitive text lookup plus a digit-only amount lookup.
enum TransactionListSearch {

    /// Maximum rows shown for a cross-month search.
    static let resultCap = 300

    /// Lowercased, diacritic-folded, whitespace-collapsed text — so
    /// "an nhau" finds "Ăn nhậu" and "di choi" finds "Đi chơi".
    /// `String.folding` keeps "đ" intact (it is a distinct letter, not
    /// d + mark), so it is replaced first.
    static func normalize(_ text: String) -> String {
        text.lowercased()
            .replacingOccurrences(of: "đ", with: "d")
            .folding(
                options: [.diacriticInsensitive],
                locale: Locale(identifier: "vi_VN")
            )
            .split(whereSeparator: \.isWhitespace)
            .joined(separator: " ")
    }

    /// The digit string a query asks for when it is only digits and
    /// grouping separators — "125", "1250000", "1.250.000". Nil when the
    /// query contains anything else (letters, symbols).
    static func amountDigits(of query: String) -> String? {
        let normalized = normalize(query)
        let digits = normalized.filter { $0 != "." && $0 != "," }
        guard !digits.isEmpty, digits.allSatisfy(\.isNumber) else { return nil }
        return digits
    }

    /// Text fields the query is checked against: note, category, both
    /// accounts of a transfer and the business name.
    static func matches(_ row: TransactionListRow, query: String) -> Bool {
        let normalized = normalize(query)
        guard !normalized.isEmpty else { return true }

        if let digits = amountDigits(of: normalized) {
            return String(row.amount).contains(digits)
        }
        return [row.note, row.categoryName, row.accountName,
                row.toAccountName, row.businessName]
            .compactMap { $0 }
            .contains { normalize($0).contains(normalized) }
    }
}
