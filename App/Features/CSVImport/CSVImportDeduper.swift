import Foundation
import CryptoKit

/// Assigns every draft a stable `externalID` and filters out the ones the
/// ledger already knows — imported earlier or deleted-and-tombstoned.
///
/// With a reference column the bank's own id is used. Without one the id
/// is a SHA-256 of account id + date + signed amount + note + the
/// occurrence index among identical rows, so two truly identical rows on
/// the same day still import as two, while re-importing the same file
/// yields the same ids and inserts nothing.
enum CSVImportDeduper {
    /// `externalSource` marker on imported rows — also the tombstone key.
    static let externalSource = "csv"

    /// Fills `externalID` on each draft, in order so occurrence indexes
    /// are stable for a given file.
    static func assignIDs(
        to drafts: inout [CSVImportDraft],
        accountID: UUID,
        calendar: Calendar = AppCalendar.vietnam
    ) {
        var occurrences: [String: Int] = [:]
        for index in drafts.indices {
            var draft = drafts[index]
            if let reference = draft.reference, !reference.isEmpty {
                draft.externalID = reference
            } else {
                let identity = "\(dateStamp(draft.date, calendar: calendar))"
                    + "|\(draft.signedAmount)|\(draft.note)"
                let occurrence = occurrences[identity, default: 0]
                occurrences[identity] = occurrence + 1
                draft.externalID = hashedID(
                    accountID: accountID, date: draft.date,
                    signedAmount: draft.signedAmount, note: draft.note,
                    occurrence: occurrence, calendar: calendar)
            }
            drafts[index] = draft
        }
    }

    /// The drafts whose ids are not in `known` — `known` being every
    /// `externalID` the ledger already holds for this source plus every
    /// tombstoned one.
    static func droppingDuplicates(
        of drafts: [CSVImportDraft],
        known: Set<String>
    ) -> (importable: [CSVImportDraft], skipped: Int) {
        var importable: [CSVImportDraft] = []
        importable.reserveCapacity(drafts.count)
        var seen = known
        var skipped = 0
        for draft in drafts {
            guard let externalID = draft.externalID, !externalID.isEmpty else {
                importable.append(draft)
                continue
            }
            if seen.insert(externalID).inserted {
                importable.append(draft)
            } else {
                skipped += 1
            }
        }
        return (importable, skipped)
    }

    /// Deterministic id for a row with no bank reference.
    static func hashedID(
        accountID: UUID,
        date: Date,
        signedAmount: Int64,
        note: String,
        occurrence: Int,
        calendar: Calendar = AppCalendar.vietnam
    ) -> String {
        let canonical = [
            accountID.uuidString.lowercased(),
            dateStamp(date, calendar: calendar),
            String(signedAmount),
            note,
            String(occurrence),
        ].joined(separator: "|")
        let digest = SHA256.hash(data: Data(canonical.utf8))
        return digest.map { String(format: "%02x", $0) }.joined()
    }

    /// "2026-11-22T14:05:30" in the Vietnam calendar — part of the hash
    /// input, rendered by hand so no formatter quirks sneak in.
    private static func dateStamp(_ date: Date, calendar: Calendar) -> String {
        let c = calendar.dateComponents(
            [.year, .month, .day, .hour, .minute, .second], from: date)
        return String(
            format: "%04d-%02d-%02dT%02d:%02d:%02d",
            c.year ?? 0, c.month ?? 0, c.day ?? 0,
            c.hour ?? 0, c.minute ?? 0, c.second ?? 0)
    }
}
