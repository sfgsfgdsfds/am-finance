import FinanceCore
import Foundation
import SwiftData

/// Makes a pulled edit visible on screen right after the cycle that
/// applied it.
///
/// Mechanism: the engine saves on its own background `ModelContext`.
/// SwiftData merges that save's INSERTS and DELETES into the main context
/// (so `@Query` lists gain/lose rows), but an object the main context has
/// already loaded keeps its old property values — measured in
/// `FinanceSyncPullApplyTests`: after a background save the registered
/// instance still reads the old amount, and only a later fetch on the main
/// context updates that same instance (and fires its observation) — which
/// is why an edit used to show up "after a while", whenever something else
/// happened to re-fetch it. So after each commit that overwrote existing
/// rows the engine awaits this refresher, which re-fetches exactly the
/// overwritten rows that the main context has registered (rows it never
/// loaded are read fresh on first use anyway).
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

    /// Re-fetches the registered subset of `rows` on `context`, updating
    /// the stale instances in place.
    @MainActor
    static func refresh(_ rows: [SyncChangedRow], in context: ModelContext) {
        func registered<T: PersistentModel>(
            _ entity: SyncEntity, as type: T.Type
        ) -> [UUID] {
            rows.filter {
                $0.entity == entity
                    && context.registeredModel(for: $0.identifier) as T? != nil
            }.map(\.id)
        }
        func refetch(_ ids: [UUID], _ fetch: ([UUID]) throws -> Void) {
            var rest = ids[...]
            while !rest.isEmpty {
                let part = Array(rest.prefix(chunk))
                rest = rest.dropFirst(part.count)
                try? fetch(part)
            }
        }
        refetch(registered(.account, as: Account.self)) { ids in
            _ = try context.fetch(FetchDescriptor<Account>(
                predicate: #Predicate { ids.contains($0.id) }))
        }
        refetch(registered(.category, as: LedgerCategory.self)) { ids in
            _ = try context.fetch(FetchDescriptor<LedgerCategory>(
                predicate: #Predicate { ids.contains($0.id) }))
        }
        refetch(registered(.business, as: Business.self)) { ids in
            _ = try context.fetch(FetchDescriptor<Business>(
                predicate: #Predicate { ids.contains($0.id) }))
        }
        refetch(registered(.transaction, as: LedgerTransaction.self)) { ids in
            _ = try context.fetch(FetchDescriptor<LedgerTransaction>(
                predicate: #Predicate { ids.contains($0.id) }))
        }
        refetch(registered(.loanRateChange, as: LoanRateChange.self)) { ids in
            _ = try context.fetch(FetchDescriptor<LoanRateChange>(
                predicate: #Predicate { ids.contains($0.id) }))
        }
        refetch(registered(.budget, as: Budget.self)) { ids in
            _ = try context.fetch(FetchDescriptor<Budget>(
                predicate: #Predicate { ids.contains($0.id) }))
        }
        refetch(registered(.recurringRule, as: RecurringRule.self)) { ids in
            _ = try context.fetch(FetchDescriptor<RecurringRule>(
                predicate: #Predicate { ids.contains($0.id) }))
        }
        refetch(registered(.rentalUnit, as: RentalUnit.self)) { ids in
            _ = try context.fetch(FetchDescriptor<RentalUnit>(
                predicate: #Predicate { ids.contains($0.id) }))
        }
        refetch(registered(.rentalLease, as: RentalLease.self)) { ids in
            _ = try context.fetch(FetchDescriptor<RentalLease>(
                predicate: #Predicate { ids.contains($0.id) }))
        }
    }
}
