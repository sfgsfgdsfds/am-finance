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
}
