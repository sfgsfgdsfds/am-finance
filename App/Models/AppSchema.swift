import Foundation
import SwiftData

/// Every SwiftData model in the app, listed in one place.
enum AppSchema {
    static let allModels: [any PersistentModel.Type] = [
        Account.self,
        LedgerCategory.self,
        Business.self,
        LedgerTransaction.self,
        LoanRateChange.self,
        Budget.self,
        RecurringRule.self,
        RentalUnit.self,
        RentalLease.self,
    ]
}

/// Factory for the app's model container. Local store only for now —
/// `cloudKitDatabase: .none` keeps the models CloudKit-compatible without
/// requiring a configured iCloud container.
enum AppModelContainer {
    static func make(inMemory: Bool = false) throws -> ModelContainer {
        let schema = Schema(AppSchema.allModels)
        let configuration = ModelConfiguration(
            schema: schema,
            isStoredInMemoryOnly: inMemory,
            cloudKitDatabase: .none
        )
        return try ModelContainer(for: schema, configurations: [configuration])
    }

    /// The legacy on-disk store the app used before the online-only
    /// launch — `Application Support/default.store` (SwiftData's default
    /// location for a nameless configuration). Only the one-time legacy
    /// migration opens it; `directory` is injectable so tests use a temp
    /// folder.
    static func makeLegacyOnDisk(directory: URL) throws -> ModelContainer {
        let schema = Schema(AppSchema.allModels)
        let configuration = ModelConfiguration(
            schema: schema,
            url: directory.appendingPathComponent(legacyStoreFileName),
            cloudKitDatabase: .none
        )
        return try ModelContainer(for: schema, configurations: [configuration])
    }

    static let legacyStoreFileName = "default.store"
}
