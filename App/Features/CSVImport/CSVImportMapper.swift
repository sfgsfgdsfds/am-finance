import Foundation

/// A bank CSV decoded into a table: the detected delimiter, the header
/// cells and every row after the header, each tagged with its 1-based
/// row number in the parsed table so error messages can name it.
struct CSVImportDocument: Equatable, Sendable {
    struct Row: Equatable, Sendable {
        /// 1-based index in the parsed table — close to the file line.
        var number: Int
        var cells: [String]
    }

    var fileName: String
    var delimiter: CSVImportDelimiter
    var headers: [String]
    var rows: [Row]

    /// Reads a file into a document: decode, detect the delimiter, parse
    /// RFC 4180 rows and find the header row under any preamble.
    init(fileName: String, data: Data) throws {
        guard !data.isEmpty else {
            throw CSVImportDocumentError.emptyFile
        }
        let text = CSVImportDetector.decode(data)
        let delimiter = CSVImportDetector.detectDelimiter(text)
        let rows = CSVImportParser.parse(text, delimiter: delimiter)
        guard let headerIndex = CSVImportDetector.findHeaderRow(in: rows) else {
            throw CSVImportDocumentError.headerNotFound
        }
        let dataRows = rows[(headerIndex + 1)...].enumerated().map {
            Row(number: headerIndex + 2 + $0.offset, cells: $0.element)
        }
        self.fileName = fileName
        self.delimiter = delimiter
        self.headers = rows[headerIndex]
        self.rows = dataRows
    }
}

/// Why a file could not be read at all — the alert messages on step 1.
enum CSVImportDocumentError: Error, Equatable {
    case emptyFile
    case headerNotFound

    var message: String {
        switch self {
        case .emptyFile:
            return "Tệp rỗng — không có nội dung nào để nhập."
        case .headerNotFound:
            return "Không tìm thấy dòng tiêu đề (cần một dòng có ít nhất 3 tên cột) hoặc không có dữ liệu sau tiêu đề."
        }
    }
}

/// One parsed statement row ready to become a `LedgerTransaction`.
struct CSVImportDraft: Equatable, Sendable {
    /// 1-based row number in the parsed table — for error/report text.
    var rowNumber: Int
    var date: Date
    /// Signed magnitude in đồng: positive is money in, negative money
    /// out — already flipped when `flipSign` is on.
    var signedAmount: Int64
    var note: String
    var reference: String?
    /// Filled by `CSVImportDeduper.assignIDs` before dedupe/import.
    var externalID: String?
}

/// A row that could not be turned into a draft, with a Vietnamese reason.
struct CSVImportRowError: Equatable, Sendable {
    var rowNumber: Int
    var reason: String
}

/// The mapper's output: importable drafts plus per-row errors.
struct CSVImportMappedRows: Equatable, Sendable {
    var drafts: [CSVImportDraft]
    var errors: [CSVImportRowError]
}

/// Turns document rows into drafts using the chosen column mapping —
/// one signed amount column or the debit/credit pair, the date and
/// number formats, and the "đảo dấu" flip. Rows that fail to parse are
/// reported, never dropped silently; fully empty rows are skipped.
enum CSVImportMapper {

    static func map(
        rows: [CSVImportDocument.Row],
        mapping: CSVImportMapping,
        calendar: Calendar = AppCalendar.vietnam
    ) -> CSVImportMappedRows {
        var drafts: [CSVImportDraft] = []
        var errors: [CSVImportRowError] = []

        func cell(_ cells: [String], at index: Int?) -> String {
            guard let index, cells.indices.contains(index) else { return "" }
            return cells[index].trimmingCharacters(in: .whitespacesAndNewlines)
        }

        for row in rows {
            let cells = row.cells
            let allEmpty = cells.allSatisfy {
                $0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            }
            if allEmpty { continue }

            // Date
            let dateText = cell(cells, at: mapping.dateColumn)
            guard !dateText.isEmpty else {
                errors.append(.init(rowNumber: row.number, reason: "Thiếu ngày"))
                continue
            }
            guard let date = CSVImportDetector.parseDate(
                dateText, format: mapping.dateFormat, calendar: calendar)
            else {
                errors.append(.init(
                    rowNumber: row.number,
                    reason: "Không đọc được ngày \"\(dateText)\""))
                continue
            }

            // Amount — one signed column or the out/in pair.
            var signed: Int64
            var amountMissing = false
            if let amountColumn = mapping.amountColumn {
                let amountText = cell(cells, at: amountColumn)
                if amountText.isEmpty {
                    errors.append(.init(rowNumber: row.number, reason: "Thiếu số tiền"))
                    continue
                }
                guard let value = CSVImportDetector.parseAmount(
                    amountText, style: mapping.numberFormat)
                else {
                    errors.append(.init(
                        rowNumber: row.number,
                        reason: "Không đọc được số tiền \"\(amountText)\""))
                    continue
                }
                signed = value
            } else {
                let outText = cell(cells, at: mapping.moneyOutColumn)
                let inText = cell(cells, at: mapping.moneyInColumn)
                var out: Int64 = 0
                var `in`: Int64 = 0
                for (text, name) in [(outText, "ghi nợ"), (inText, "ghi có")]
                where !text.isEmpty {
                    guard let value = CSVImportDetector.parseAmount(
                        text, style: mapping.numberFormat)
                    else {
                        errors.append(.init(
                            rowNumber: row.number,
                            reason: "Không đọc được số tiền \(name) \"\(text)\""))
                        amountMissing = true
                        break
                    }
                    // Magnitudes — Int64.min has no positive counterpart.
                    let magnitude = value == Int64.min ? Int64.max : abs(value)
                    if name == "ghi nợ" { out = magnitude } else { `in` = magnitude }
                }
                if amountMissing { continue }
                signed = `in` - out
                if signed == 0 && outText.isEmpty && inText.isEmpty {
                    errors.append(.init(rowNumber: row.number, reason: "Thiếu số tiền"))
                    continue
                }
            }
            if signed == 0 {
                errors.append(.init(rowNumber: row.number, reason: "Số tiền bằng 0"))
                continue
            }
            if mapping.flipSign { signed = -signed }

            let note = cell(cells, at: mapping.descriptionColumn)
            let referenceText = cell(cells, at: mapping.referenceColumn)
            drafts.append(.init(
                rowNumber: row.number,
                date: date,
                signedAmount: signed,
                note: note,
                reference: referenceText.isEmpty ? nil : referenceText))
        }
        return .init(drafts: drafts, errors: errors)
    }
}
