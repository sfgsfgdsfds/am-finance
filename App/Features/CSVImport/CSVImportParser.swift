import Foundation

/// Field separators a bank CSV can use. `rawValue` is the separator itself.
enum CSVImportDelimiter: String, Codable, CaseIterable, Sendable {
    case comma = ","
    case semicolon = ";"
    case tab = "\t"

    var character: Character { Character(rawValue) }

    /// Vietnamese label for the UI.
    var displayName: String {
        switch self {
        case .comma: return "dấu phẩy (,)"
        case .semicolon: return "dấu chấm phẩy (;)"
        case .tab: return "dấu tab"
        }
    }
}

/// Pure RFC 4180 CSV reader: quoted fields, `""` escapes, embedded
/// newlines and delimiters, and CRLF/LF/CR line endings. Output is a list
/// of rows, each a list of raw cell strings — a line that is empty on its
/// own yields a one-cell row, so callers decide whether to skip it.
enum CSVImportParser {
    static func parse(_ text: String, delimiter: CSVImportDelimiter) -> [[String]] {
        let separator = delimiter.character
        var rows: [[String]] = []
        var row: [String] = []
        var field = ""
        var inQuotes = false
        var index = text.startIndex

        func endField() {
            row.append(field)
            field = ""
        }
        func endRow() {
            endField()
            rows.append(row)
            row = []
        }

        while index < text.endIndex {
            let char = text[index]
            if inQuotes {
                if char == "\"" {
                    let next = text.index(after: index)
                    if next < text.endIndex, text[next] == "\"" {
                        field.append("\"")
                        index = next
                    } else {
                        inQuotes = false
                    }
                } else {
                    field.append(char)
                }
            } else if char == "\"", field.isEmpty {
                inQuotes = true
            } else if char == separator {
                endField()
            } else if char == "\r\n" || char == "\r" || char == "\n" {
                // "\r\n" is a single Character (grapheme cluster) in Swift,
                // so a CRLF is consumed in one step.
                endRow()
            } else {
                field.append(char)
            }
            index = text.index(after: index)
        }

        // The last row has no terminator; a trailing newline leaves nothing.
        if !field.isEmpty || !row.isEmpty {
            endRow()
        }
        return rows
    }
}
