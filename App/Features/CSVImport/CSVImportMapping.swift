import Foundation

/// Which columns of a bank CSV feed the import, plus the two format
/// settings and the sign flip for card statements that print spending as
/// positive. Column indexes refer to the header row.
struct CSVImportMapping: Equatable, Codable, Sendable {
    var dateColumn: Int?
    /// Single signed-amount column; nil when the statement splits money
    /// out / money in into two columns.
    var amountColumn: Int?
    /// "Ghi nợ" — money leaving the account, as a positive magnitude.
    var moneyOutColumn: Int?
    /// "Ghi có" — money arriving, as a positive magnitude.
    var moneyInColumn: Int?
    var descriptionColumn: Int?
    var referenceColumn: Int?

    var dateFormat: CSVImportDateFormat = .dayMonthYearSlash
    var numberFormat: CSVImportNumberFormatStyle = .vietnamese
    /// "Đảo dấu" — flip every parsed sign for statements that show
    /// spending as a positive amount.
    var flipSign: Bool = false

    /// True while the mapping uses one signed column rather than the
    /// debit/credit pair.
    var usesSingleAmount: Bool {
        amountColumn != nil
    }

    /// Everything the import needs to proceed: a date, a description and
    /// at least one amount column.
    var isComplete: Bool {
        dateColumn != nil
            && descriptionColumn != nil
            && (amountColumn != nil
                || moneyOutColumn != nil
                || moneyInColumn != nil)
    }
}

/// The mapping as it is remembered per account — column *names*, not
/// indexes, so the next file from the same bank resolves against its own
/// header row even when columns moved.
struct CSVImportSavedMapping: Equatable, Codable, Sendable {
    var dateHeader: String?
    var amountHeader: String?
    var moneyOutHeader: String?
    var moneyInHeader: String?
    var descriptionHeader: String?
    var referenceHeader: String?
    var dateFormat: CSVImportDateFormat
    var numberFormat: CSVImportNumberFormatStyle
    var flipSign: Bool

    init(from mapping: CSVImportMapping, headers: [String]) {
        func header(_ index: Int?) -> String? {
            guard let index, headers.indices.contains(index) else { return nil }
            return headers[index]
        }
        dateHeader = header(mapping.dateColumn)
        amountHeader = header(mapping.amountColumn)
        moneyOutHeader = header(mapping.moneyOutColumn)
        moneyInHeader = header(mapping.moneyInColumn)
        descriptionHeader = header(mapping.descriptionColumn)
        referenceHeader = header(mapping.referenceColumn)
        dateFormat = mapping.dateFormat
        numberFormat = mapping.numberFormat
        flipSign = mapping.flipSign
    }

    /// Resolves the stored header names against this file's headers —
    /// folded-name equality, first match wins. Unresolved slots keep the
    /// fallback's guess.
    func resolved(
        headers: [String],
        fallback: CSVImportMapping
    ) -> CSVImportMapping {
        let folded = headers.map {
            SettingsNameNormalizer.fold($0).lowercased()
        }
        func index(of name: String?) -> Int? {
            guard let name else { return nil }
            let want = SettingsNameNormalizer.fold(name).lowercased()
            guard !want.isEmpty else { return nil }
            return folded.firstIndex(of: want)
        }
        var mapping = fallback
        if let date = index(of: dateHeader) { mapping.dateColumn = date }
        if let amount = index(of: amountHeader) {
            mapping.amountColumn = amount
            mapping.moneyOutColumn = nil
            mapping.moneyInColumn = nil
        }
        if let out = index(of: moneyOutHeader) {
            mapping.moneyOutColumn = out
            mapping.amountColumn = nil
        }
        if let `in` = index(of: moneyInHeader) {
            mapping.moneyInColumn = `in`
            mapping.amountColumn = nil
        }
        if let description = index(of: descriptionHeader) {
            mapping.descriptionColumn = description
        }
        if let reference = index(of: referenceHeader) {
            mapping.referenceColumn = reference
        }
        mapping.dateFormat = dateFormat
        mapping.numberFormat = numberFormat
        mapping.flipSign = flipSign
        return mapping
    }
}

/// Storage seam for remembered mappings — UserDefaults in the app,
/// in-memory in tests.
protocol CSVImportMappingStoring: Sendable {
    func mapping(for accountID: UUID) -> CSVImportSavedMapping?
    func saveMapping(_ mapping: CSVImportSavedMapping, for accountID: UUID)
    /// Drops every remembered mapping — the "Xoá tất cả" reset uses it.
    func removeAllMappings()
}

/// One JSON blob `[accountUUID: mapping]` in UserDefaults.
final class CSVImportMappingStore: CSVImportMappingStoring, @unchecked Sendable {
    static let key = "csvImport.mappings"

    let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    private var all: [String: CSVImportSavedMapping] {
        get {
            guard let data = defaults.data(forKey: Self.key),
                  let decoded = try? JSONDecoder().decode(
                      [String: CSVImportSavedMapping].self, from: data)
            else { return [:] }
            return decoded
        }
        set {
            defaults.set(try? JSONEncoder().encode(newValue), forKey: Self.key)
        }
    }

    func mapping(for accountID: UUID) -> CSVImportSavedMapping? {
        all[accountID.uuidString]
    }

    func saveMapping(_ mapping: CSVImportSavedMapping, for accountID: UUID) {
        var copy = all
        copy[accountID.uuidString] = mapping
        all = copy
    }

    func removeAllMappings() {
        defaults.removeObject(forKey: Self.key)
    }
}

/// Volatile `CSVImportMappingStoring` for tests and previews.
final class CSVImportInMemoryMappingStore: CSVImportMappingStoring, @unchecked Sendable {
    private var saved: [UUID: CSVImportSavedMapping] = [:]

    init(saved: [UUID: CSVImportSavedMapping] = [:]) {
        self.saved = saved
    }

    func mapping(for accountID: UUID) -> CSVImportSavedMapping? {
        saved[accountID]
    }

    func saveMapping(_ mapping: CSVImportSavedMapping, for accountID: UUID) {
        saved[accountID] = mapping
    }

    func removeAllMappings() {
        saved = [:]
    }
}
