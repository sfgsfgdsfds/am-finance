import Foundation
import FinanceCore

/// Pure builder turning the rows a background sync just inserted into the
/// local notifications to deliver. Vietnamese texts, VND formatting,
/// stable identifiers — deterministic across runs so a re-run of the same
/// import replaces instead of duplicating.
enum BackgroundRefreshNotificationPlan {
    /// One local notification to deliver immediately.
    struct Item: Equatable, Sendable {
        var identifier: String
        var title: String
        var body: String
    }

    /// Up to this many inserted rows get their own notification; above it
    /// a single summary goes out instead.
    static let perTransactionLimit = 3

    /// `amfinance.banksync.tx.<externalID>` — one per imported row.
    static let transactionPrefix = "amfinance.banksync.tx."
    /// `amfinance.banksync.summary.<hash>` — the many-rows roll-up.
    static let summaryPrefix = "amfinance.banksync.summary."
    /// Title of the summary notification.
    static let summaryTitle = "Giao dịch ngân hàng mới"

    /// The plan for one sync's inserted rows, in the order they were
    /// committed. Empty input plans nothing.
    ///
    /// - ≤ `perTransactionLimit` rows → one item each:
    ///   title "VPBank *1234: -150.000 ₫", body the bank note.
    /// - More rows → one summary: "7 giao dịch mới, tổng chi 1.250.000 ₫,
    ///   tổng thu 3.000.000 ₫" (each total only when non-zero).
    static func plan(
        inserted: [WalletSyncInsertedTransaction]
    ) -> [Item] {
        if inserted.count <= perTransactionLimit {
            return inserted.map { row in
                Item(
                    identifier: transactionPrefix + row.externalID,
                    title: "\(row.accountName): \(VND.format(row.signedAmount))",
                    body: row.note
                )
            }
        }
        var expense: Int64 = 0
        var income: Int64 = 0
        for row in inserted {
            if row.signedAmount < 0 {
                expense = expense &+ magnitude(of: row.signedAmount)
            } else {
                income = income &+ row.signedAmount
            }
        }
        var parts = ["\(inserted.count) giao dịch mới"]
        if expense > 0 { parts.append("tổng chi \(VND.format(expense))") }
        if income > 0 { parts.append("tổng thu \(VND.format(income))") }
        return [Item(
            identifier: summaryIdentifier(for: inserted),
            title: summaryTitle,
            body: parts.joined(separator: ", ")
        )]
    }

    /// Overflow-safe |amount| — Int64.min has no positive counterpart.
    private static func magnitude(of amount: Int64) -> Int64 {
        amount == Int64.min ? Int64.max : -amount
    }

    /// Stable per-set identifier: a re-import of the exact same rows
    /// produces the same request id, so the notification is replaced, not
    /// duplicated. FNV-1a over the sorted external ids — `hashValue` is
    /// not stable across launches.
    private static func summaryIdentifier(
        for inserted: [WalletSyncInsertedTransaction]
    ) -> String {
        var hash: UInt64 = 0xcbf2_9ce4_8422_2325
        for id in inserted.map(\.externalID).sorted() {
            for byte in id.utf8 {
                hash = (hash ^ UInt64(byte)) &* 0x0000_0100_0000_01b3
            }
        }
        return summaryPrefix + String(hash, radix: 16)
    }
}
