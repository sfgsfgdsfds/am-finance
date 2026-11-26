import FinanceCore
import Foundation
import SwiftData

/// Makes a pulled edit visible on screen right after the cycle that
/// applied it — values AND Observation.
///
/// The engine saves on its own background `ModelContext`. SwiftData merges
/// that save's inserts and deletes into the main context (a `@Query`-style
/// fetch sees them immediately), but an object the main context has already
/// loaded keeps its old property values until something fetches it again.
/// Measured: that re-fetch updates the registered instance in place and
/// does NOT go through the `@Model` setters, so `withObservationTracking`
/// / SwiftUI never hear about it and a row already on screen stays stale.
///
/// Applying whole pages on the main context would notify for free, but it
/// would also do every pull on the main actor. Instead, after the re-fetch
/// this refresher writes each synced property back through its setter
/// (`touch`). The setter always runs `withMutation`, which is what
/// Observation listens to — including properties whose value the re-fetch
/// already changed silently. The write dirties the main context, so it is
/// saved inside `FinanceSyncSaveFilter.asEngine`: the save notification
/// is engine-origin and cannot schedule another push, and the bytes match
/// the row the engine just stored.
enum FinanceSyncMainContextRefresher {
    /// Fetch chunk — keeps each `IN` predicate small.
    private static let chunk = 200

    /// Hooks the refresher onto `engine` for `container.mainContext`.
    static func install(on engine: FinanceSyncEngine, container: ModelContainer) async {
        await engine.addChangedRowObserver { rows in
            await MainActor.run {
                refresh(rows, in: container.mainContext)
            }
        }
    }

    /// Re-fetches the registered subset of `rows` on `context`, then
/// re-assigns every synced property so Observation fires, and saves
/// inside `asEngine` so the write is not a user edit.
    @MainActor
    static func refresh(_ rows: [SyncChangedRow], in context: ModelContext) {
        func registered<T: PersistentModel>(
            _ entity: SyncEntity, as type: T.Type
        ) -> [T] {
            rows.compactMap { row in
                guard row.entity == entity else { return nil }
                return context.registeredModel(for: row.identifier) as T?
            }
        }
        let accounts = registered(.account, as: Account.self)
        let categories = registered(.category, as: LedgerCategory.self)
        let businesses = registered(.business, as: Business.self)
        let transactions = registered(.transaction, as: LedgerTransaction.self)
        let rateChanges = registered(.loanRateChange, as: LoanRateChange.self)
        let budgets = registered(.budget, as: Budget.self)
        let rules = registered(.recurringRule, as: RecurringRule.self)
        let units = registered(.rentalUnit, as: RentalUnit.self)
        let leases = registered(.rentalLease, as: RentalLease.self)

        func refetch(_ ids: [UUID], _ fetch: ([UUID]) throws -> Void) {
            var rest = ids[...]
            while !rest.isEmpty {
                let part = Array(rest.prefix(chunk))
                rest = rest.dropFirst(part.count)
                try? fetch(part)
            }
        }
        refetch(accounts.map(\.id)) { ids in
            _ = try context.fetch(FetchDescriptor<Account>(
                predicate: #Predicate { ids.contains($0.id) }))
        }
        refetch(categories.map(\.id)) { ids in
            _ = try context.fetch(FetchDescriptor<LedgerCategory>(
                predicate: #Predicate { ids.contains($0.id) }))
        }
        refetch(businesses.map(\.id)) { ids in
            _ = try context.fetch(FetchDescriptor<Business>(
                predicate: #Predicate { ids.contains($0.id) }))
        }
        refetch(transactions.map(\.id)) { ids in
            _ = try context.fetch(FetchDescriptor<LedgerTransaction>(
                predicate: #Predicate { ids.contains($0.id) }))
        }
        refetch(rateChanges.map(\.id)) { ids in
            _ = try context.fetch(FetchDescriptor<LoanRateChange>(
                predicate: #Predicate { ids.contains($0.id) }))
        }
        refetch(budgets.map(\.id)) { ids in
            _ = try context.fetch(FetchDescriptor<Budget>(
                predicate: #Predicate { ids.contains($0.id) }))
        }
        refetch(rules.map(\.id)) { ids in
            _ = try context.fetch(FetchDescriptor<RecurringRule>(
                predicate: #Predicate { ids.contains($0.id) }))
        }
        refetch(units.map(\.id)) { ids in
            _ = try context.fetch(FetchDescriptor<RentalUnit>(
                predicate: #Predicate { ids.contains($0.id) }))
        }
        refetch(leases.map(\.id)) { ids in
            _ = try context.fetch(FetchDescriptor<RentalLease>(
                predicate: #Predicate { ids.contains($0.id) }))
        }

        // Setters after the re-fetch: the values are already the server's,
        // and writing them back is what notifies observers.
        do {
            try FinanceSyncSaveFilter.asEngine {
                for account in accounts { touch(account) }
                for category in categories { touch(category) }
                for business in businesses { touch(business) }
                for transaction in transactions { touch(transaction) }
                for change in rateChanges { touch(change) }
                for budget in budgets { touch(budget) }
                for rule in rules { touch(rule) }
                for unit in units { touch(unit) }
                for lease in leases { touch(lease) }
                if context.hasChanges { try context.save() }
            }
        } catch {
            // The store already holds the pulled values; drop the dirty
            // flag so a later autosave cannot look like a user edit.
            context.rollback()
        }
    }

    /// Writes each synced stored property back through its setter.
    /// To-many inverses are left alone — assigning those replaces the
    /// relationship.
    private static func touch<T, M>(
        _ model: M, _ keyPath: ReferenceWritableKeyPath<M, T>
    ) {
        model[keyPath: keyPath] = model[keyPath: keyPath]
    }

    private static func touch(_ account: Account) {
        touch(account, \.name)
        touch(account, \.kindRaw)
        touch(account, \.openingBalance)
        touch(account, \.icon)
        touch(account, \.colorHex)
        touch(account, \.note)
        touch(account, \.sortOrder)
        touch(account, \.isArchived)
        touch(account, \.createdAt)
        touch(account, \.creditLimit)
        touch(account, \.statementDay)
        touch(account, \.graceDays)
        touch(account, \.loanPrincipal)
        touch(account, \.loanAnnualRatePercent)
        touch(account, \.loanTermMonths)
        touch(account, \.loanStartDate)
        touch(account, \.loanPaymentDay)
        touch(account, \.loanMethodRaw)
        touch(account, \.externalSource)
        touch(account, \.externalAccountID)
        touch(account, \.business)
    }

    private static func touch(_ category: LedgerCategory) {
        touch(category, \.name)
        touch(category, \.kindRaw)
        touch(category, \.icon)
        touch(category, \.colorHex)
        touch(category, \.sortOrder)
        touch(category, \.isArchived)
    }

    private static func touch(_ business: Business) {
        touch(business, \.name)
        touch(business, \.icon)
        touch(business, \.colorHex)
        touch(business, \.note)
        touch(business, \.sortOrder)
        touch(business, \.isArchived)
    }

    private static func touch(_ transaction: LedgerTransaction) {
        touch(transaction, \.kindRaw)
        touch(transaction, \.amount)
        touch(transaction, \.date)
        touch(transaction, \.note)
        touch(transaction, \.needsReview)
        touch(transaction, \.externalSource)
        touch(transaction, \.externalID)
        touch(transaction, \.createdAt)
        touch(transaction, \.updatedAt)
        touch(transaction, \.rentalPeriod)
        touch(transaction, \.account)
        touch(transaction, \.toAccount)
        touch(transaction, \.category)
        touch(transaction, \.business)
        touch(transaction, \.rentalLease)
    }

    private static func touch(_ change: LoanRateChange) {
        touch(change, \.fromInstallment)
        touch(change, \.annualRatePercent)
        touch(change, \.account)
    }

    private static func touch(_ budget: Budget) {
        touch(budget, \.monthlyLimit)
        touch(budget, \.isActive)
        touch(budget, \.note)
        touch(budget, \.createdAt)
        touch(budget, \.category)
    }

    private static func touch(_ rule: RecurringRule) {
        touch(rule, \.title)
        touch(rule, \.kindRaw)
        touch(rule, \.amount)
        touch(rule, \.note)
        touch(rule, \.frequencyRaw)
        touch(rule, \.interval)
        touch(rule, \.startDate)
        touch(rule, \.endDate)
        touch(rule, \.maximumOccurrences)
        touch(rule, \.lastGeneratedDate)
        touch(rule, \.autoCreate)
        touch(rule, \.isActive)
        touch(rule, \.createdAt)
        touch(rule, \.account)
        touch(rule, \.toAccount)
        touch(rule, \.category)
        touch(rule, \.business)
    }

    private static func touch(_ unit: RentalUnit) {
        touch(unit, \.name)
        touch(unit, \.listPrice)
        touch(unit, \.note)
        touch(unit, \.sortOrder)
        touch(unit, \.isArchived)
        touch(unit, \.createdAt)
        touch(unit, \.business)
    }

    private static func touch(_ lease: RentalLease) {
        touch(lease, \.tenantName)
        touch(lease, \.tenantPhone)
        touch(lease, \.startDate)
        touch(lease, \.endDate)
        touch(lease, \.monthlyRent)
        touch(lease, \.deposit)
        touch(lease, \.paymentDay)
        touch(lease, \.isActive)
        touch(lease, \.note)
        touch(lease, \.createdAt)
        touch(lease, \.unit)
    }
}
