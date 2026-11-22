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

    /// A query folded once instead of per row — `normalized` is the text
    /// match, `digits` the amount match when the query is digits and
    /// grouping separators only.
    struct NormalizedQuery: Equatable, Sendable {
        let normalized: String
        let digits: String?

        var isEmpty: Bool { normalized.isEmpty }
    }

    /// Folds the raw search text once per keystroke — the old
    /// `matches(_:query:)` re-folded it inside every row's check.
    static func normalizedQuery(_ query: String) -> NormalizedQuery {
        let normalized = normalize(query)
        return NormalizedQuery(
            normalized: normalized,
            digits: normalized.isEmpty ? nil : amountDigits(of: normalized))
    }

    /// Every searchable field folded once per row — built once per row
    /// per data change, so each keystroke only re-runs the substring
    /// checks. Kept as separate fields (not one joined blob) so matching
    /// stays field-scoped, exactly like `matches(_:query:)`.
    static func searchableFields(for row: TransactionListRow) -> [String] {
        [row.note, row.categoryName, row.accountName,
         row.toAccountName, row.businessName]
            .compactMap { $0 }
            .map { normalize($0) }
            .filter { !$0.isEmpty }
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

    /// Same match against a pre-folded query; `searchable` is the row's
    /// `searchableFields(for:)` output, built inline when the caller did
    /// not prebuild it.
    static func matches(
        _ row: TransactionListRow,
        query normalized: NormalizedQuery,
        searchable: [String]? = nil
    ) -> Bool {
        guard !normalized.normalized.isEmpty else { return true }
        if let digits = normalized.digits {
            return String(row.amount).contains(digits)
        }
        return (searchable ?? searchableFields(for: row))
            .contains { $0.contains(normalized.normalized) }
    }
}
