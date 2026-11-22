import Foundation
import FinanceCore

/// One flattened transaction row for the spreadsheet export: names instead
/// of relationships, already in the user's language.
struct BackupCSVRow: Equatable, Sendable {
    var date: Date
    var kindRaw: String
    var amount: Int64
    var accountName: String
    var toAccountName: String
    var categoryName: String
    var businessName: String
    var note: String
}

extension BackupCSVRow {
    init(_ transaction: LedgerTransaction) {
        date = transaction.date
        kindRaw = transaction.kindRaw
        amount = transaction.amount
        accountName = transaction.account?.name ?? ""
        toAccountName = transaction.toAccount?.name ?? ""
        categoryName = transaction.category?.name ?? ""
        businessName = transaction.business?.name ?? ""
        note = transaction.note
    }
}

/// Pure CSV writer for the transaction spreadsheet. Output is UTF-8 with a
/// BOM and CRLF line endings so Excel detects the encoding correctly.
enum BackupCSV {
    /// Vietnamese column order: date, kind, amount, account, destination
    /// account, category, business, note.
    static let header = [
        "Ngày", "Loại", "Số tiền", "Tài khoản",
        "Tài khoản đích", "Danh mục", "Doanh nghiệp", "Ghi chú",
    ]

    /// Rows filtered to `from...to` (inclusive instants; nil means unbounded)
    /// and sorted by date. Always starts with the BOM + header line, even
    /// when the range selects nothing.
    static func data(
        rows: [BackupCSVRow],
        from: Date? = nil,
        to: Date? = nil,
        calendar: Calendar = AppCalendar.vietnam
    ) -> Data {
        Data(string(rows: rows, from: from, to: to, calendar: calendar).utf8)
    }

    static func string(
        rows: [BackupCSVRow],
        from: Date? = nil,
        to: Date? = nil,
        calendar: Calendar = AppCalendar.vietnam
    ) -> String {
        let formatter = DateFormatter()
        formatter.calendar = calendar
        formatter.timeZone = calendar.timeZone
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd HH:mm"

        var text = "\u{FEFF}" + line(header)
        for row in rows.sorted(by: { $0.date < $1.date }) {
            if let from, row.date < from { continue }
            if let to, row.date > to { continue }
            text += line([
                formatter.string(from: row.date),
                kindName(row.kindRaw),
                String(row.amount),
                row.accountName,
                row.toAccountName,
                row.categoryName,
                row.businessName,
                row.note,
            ])
        }
        return text
    }

    /// Vietnamese label for the raw kind; an unknown value is passed through
    /// rather than being silently relabeled.
    private static func kindName(_ kindRaw: String) -> String {
        TransactionKind(rawValue: kindRaw)?.displayName ?? kindRaw
    }

    private static func line(_ fields: [String]) -> String {
        fields.map(escape).joined(separator: ",") + "\r\n"
    }

    /// RFC 4180 quoting: a field containing a comma, quote or line break is
    /// wrapped in quotes and its quotes doubled.
    private static func escape(_ field: String) -> String {
        guard field.contains(where: { $0 == "," || $0 == "\"" || $0 == "\n" || $0 == "\r" }) else {
            return field
        }
        return "\"" + field.replacingOccurrences(of: "\"", with: "\"\"") + "\""
    }
}
