import Foundation
import SwiftData

/// Encodes the store to a `BackupDocument` JSON file and decodes it back.
/// Dates are ISO 8601 with fractional seconds so `updatedAt` ordering and
/// `createdAt` equality survive a round trip.
enum BackupCodec {
    /// The newest backup format this build writes; files at version 1 or 2
    /// are accepted on read (v1 lacks `loanRateChanges`, decoded as empty).
    static let formatVersion = 2

    /// Version string stamped into every exported document.
    static var appVersion: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "1.0"
    }

    // MARK: - Encode

    /// Builds the document from fetched rows. Arrays are sorted so repeated
    /// exports of unchanged data produce identical files.
    static func document(
        accounts: [Account],
        categories: [LedgerCategory],
        businesses: [Business],
        transactions: [LedgerTransaction],
        loanRateChanges: [LoanRateChange],
        exportedAt: Date = .now,
        appVersion: String = appVersion
    ) -> BackupDocument {
        BackupDocument(
            formatVersion: formatVersion,
            exportedAt: exportedAt,
            appVersion: appVersion,
            accounts: accounts
                .sorted { ($0.sortOrder, $0.name) < ($1.sortOrder, $1.name) }
                .map(BackupAccount.init),
            categories: categories
                .sorted { ($0.kindRaw, $0.sortOrder, $0.name) < ($1.kindRaw, $1.sortOrder, $1.name) }
                .map(BackupCategory.init),
            businesses: businesses
                .sorted { ($0.sortOrder, $0.name) < ($1.sortOrder, $1.name) }
                .map(BackupBusiness.init),
            transactions: transactions
                .sorted { ($0.date, $0.createdAt, $0.id.uuidString) < ($1.date, $1.createdAt, $1.id.uuidString) }
                .map(BackupTransaction.init),
            loanRateChanges: loanRateChanges
                .sorted {
                    ($0.account?.id.uuidString ?? "", $0.fromInstallment, $0.id.uuidString)
                        < ($1.account?.id.uuidString ?? "", $1.fromInstallment, $1.id.uuidString)
                }
                .map(BackupLoanRateChange.init)
        )
    }

    /// Fetches everything in `context` and returns the encoded backup file.
    static func encode(context: ModelContext, exportedAt: Date = .now) throws -> Data {
        let doc = document(
            accounts: try context.fetch(FetchDescriptor<Account>()),
            categories: try context.fetch(FetchDescriptor<LedgerCategory>()),
            businesses: try context.fetch(FetchDescriptor<Business>()),
            transactions: try context.fetch(FetchDescriptor<LedgerTransaction>()),
            loanRateChanges: try context.fetch(FetchDescriptor<LoanRateChange>()),
            exportedAt: exportedAt
        )
        return try encode(doc)
    }

    static func encode(_ document: BackupDocument) throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .custom { date, encoder in
            var container = encoder.singleValueContainer()
            try container.encode(BackupDateCodec.string(from: date))
        }
        return try encoder.encode(document)
    }

    // MARK: - Decode

    /// Reads a backup file. Throws `.unsupportedVersion` when the file was
    /// written by a newer app and `.malformed` when it is not a readable
    /// backup — in both cases nothing is decoded into the store.
    static func decode(_ data: Data) throws -> BackupDocument {
        let decoder = makeDecoder()
        let header: BackupDocumentHeader
        do {
            header = try decoder.decode(BackupDocumentHeader.self, from: data)
        } catch {
            throw BackupError.malformed
        }
        guard header.formatVersion <= formatVersion else {
            throw BackupError.unsupportedVersion(found: header.formatVersion)
        }
        do {
            return try decoder.decode(BackupDocument.self, from: data)
        } catch {
            throw BackupError.malformed
        }
    }

    private static func makeDecoder() -> JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .custom { decoder in
            let container = try decoder.singleValueContainer()
            let string = try container.decode(String.self)
            guard let date = BackupDateCodec.date(from: string) else {
                throw DecodingError.dataCorruptedError(
                    in: container,
                    debugDescription: "Invalid ISO 8601 date: \(string)"
                )
            }
            return date
        }
        return decoder
    }

    // MARK: - File name stamp

    /// "20261122-1405" — timestamp chunk used in export file names, in the
    /// Vietnam time zone like every other date in the app.
    static func fileStamp(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.calendar = AppCalendar.vietnam
        formatter.timeZone = AppCalendar.vietnam.timeZone
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyyMMdd-HHmm"
        return formatter.string(from: date)
    }
}

/// Errors the user can hit while picking a file to restore. Descriptions are
/// Vietnamese because they surface directly in an alert.
enum BackupError: LocalizedError, Equatable, Sendable {
    /// The file was written by a newer app version.
    case unsupportedVersion(found: Int)
    /// Not a readable backup: wrong JSON shape, corrupt file, bad dates.
    case malformed

    var errorDescription: String? {
        switch self {
        case .unsupportedVersion(let found):
            return "Tệp sao lưu được tạo bởi phiên bản ứng dụng mới hơn (định dạng \(found)). Hãy cập nhật ứng dụng rồi thử lại."
        case .malformed:
            return "Tệp không phải là bản sao lưu hợp lệ hoặc đã bị hỏng."
        }
    }
}

/// Just the version field — decoded first so a too-new file is reported as
/// "newer version" instead of "malformed" when its body also has new fields.
private struct BackupDocumentHeader: Codable {
    var formatVersion: Int
}

/// ISO 8601 with fractional seconds on write; accepts both the fractional
/// and the plain internet-date-time form on read.
enum BackupDateCodec {
    static func string(from date: Date) -> String {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter.string(from: date)
    }

    static func date(from string: String) -> Date? {
        let withFraction = ISO8601DateFormatter()
        withFraction.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = withFraction.date(from: string) { return date }
        let plain = ISO8601DateFormatter()
        plain.formatOptions = [.withInternetDateTime]
        return plain.date(from: string)
    }
}
