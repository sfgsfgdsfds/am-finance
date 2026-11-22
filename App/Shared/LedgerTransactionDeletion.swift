import Foundation
import SwiftData

/// Deletes `LedgerTransaction` rows so bank imports stay deleted.
///
/// A row imported by wallet sync carries `externalSource`/`externalID`.
/// Deleting it through this helper first records the id as a tombstone
/// in the sync state store, so the daily full rescan never resurrects
/// it. Every place that deletes a `LedgerTransaction` goes through here.
enum LedgerTransactionDeletion {
    /// Tombstones the row's external id (when it has one) and deletes it
    /// from `context`. `tombstones` is the wallet-sync state store —
    /// UserDefaults-backed in the app, injectable in tests.
    static func delete(
        _ transaction: LedgerTransaction,
        in context: ModelContext,
        tombstones: any WalletSyncStateStoring = WalletSyncStateStore()
    ) {
        if let source = transaction.externalSource, !source.isEmpty,
           let externalID = transaction.externalID, !externalID.isEmpty {
            tombstones.recordTombstones([externalID], source: source)
        }
        context.delete(transaction)
    }
}
