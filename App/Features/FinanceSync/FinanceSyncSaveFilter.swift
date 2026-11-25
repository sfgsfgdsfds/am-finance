import CoreData
import Foundation
import SwiftData

/// Decides whether a save notification is a REAL user edit of the app
/// store — the only kind that may schedule a debounced sync.
///
/// Both `ModelContext.didSave` and `NSManagedObjectContextDidSave` are
/// process-global: they also fire for the sync engine's own writes (the
/// background context applying pulled rows) and for every save of the
/// separate `FinanceSync.store` shadow/state container. Reacting to those
/// made each cycle schedule the next one (observed in production as an
/// empty `pull` every ~3 s). Three layers keep the trigger honest:
///
/// 1. Engine origin — the engine (and the bootstrap's restore) run their
///    app-store `save()` inside `asEngine`. Both notifications are posted
///    synchronously on the saving thread, so a thread-local mark tells the
///    observer the save is ours without confusing it with a user save
///    happening concurrently on another thread.
/// 2. Entity names — only a save touching one of the nine synced app
///    entities counts; the shadow container's `SyncShadowEntry`/
///    `SyncQuarantineEntry`/`SyncShadowState` never match, and neither do
///    unsynced app models.
/// 3. Container — a `ModelContext.didSave` must come from the app
///    container itself.
enum FinanceSyncSaveFilter {
    private static let originKey = "vn.amx.finance.sync.engineSave"

    /// Runs a synchronous app-store write (`context.save()`) tagged as
    /// engine-originated on the current thread.
    static func asEngine<T>(_ body: () throws -> T) rethrows -> T {
        let dictionary = Thread.current.threadDictionary
        let previous = dictionary[originKey]
        dictionary[originKey] = true
        defer {
            if let previous {
                dictionary[originKey] = previous
            } else {
                dictionary.removeObject(forKey: originKey)
            }
        }
        return try body()
    }

    /// True while the calling thread is inside `asEngine`.
    static var isEngineSave: Bool {
        Thread.current.threadDictionary[originKey] != nil
    }

    /// Model type names of the nine synced entities — SwiftData names the
    /// Core Data entity after the model class.
    static let syncedEntityNames: Set<String> = [
        String(describing: Account.self),
        String(describing: LedgerCategory.self),
        String(describing: Business.self),
        String(describing: LedgerTransaction.self),
        String(describing: LoanRateChange.self),
        String(describing: Budget.self),
        String(describing: RecurringRule.self),
        String(describing: RentalUnit.self),
        String(describing: RentalLease.self),
    ]

    static func isSyncedEntity(named name: String?) -> Bool {
        guard let name else { return false }
        return syncedEntityNames.contains { name == $0 || name.hasSuffix(".\($0)") }
    }

    /// Whether `notification` is a user edit of `container`'s app store.
    /// MUST be called synchronously from the notification observer (so the
    /// thread-local engine mark is still readable).
    static func isUserSave(
        _ notification: Notification, container: ModelContainer
    ) -> Bool {
        if isEngineSave { return false }
        if notification.name == ModelContext.didSave {
            guard let context = notification.object as? ModelContext,
                  context.container === container
            else { return false }
            let keys: [ModelContext.NotificationKey] = [
                .insertedIdentifiers, .updatedIdentifiers, .deletedIdentifiers,
            ]
            for key in keys {
                let identifiers = notification.userInfo?[key.rawValue]
                    as? [PersistentIdentifier] ?? []
                if identifiers.contains(where: {
                    isSyncedEntity(named: $0.entityName)
                }) { return true }
            }
            return false
        }
        if notification.name == .NSManagedObjectContextDidSave {
            let keys = [
                NSInsertedObjectsKey, NSUpdatedObjectsKey, NSDeletedObjectsKey,
            ]
            for key in keys {
                let objects = notification.userInfo?[key]
                    as? Set<NSManagedObject> ?? []
                if objects.contains(where: {
                    isSyncedEntity(named: $0.entity.name)
                }) { return true }
            }
            return false
        }
        return false
    }
}
