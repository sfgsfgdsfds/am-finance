import Foundation
import SwiftData

/// How a decoded backup is applied to the current store.
enum BackupRestoreMode: Sendable {
    /// Upsert by id: new rows are inserted, existing rows are updated — for
    /// transactions only when the backup copy has the newer `updatedAt`.
    case merge
    /// Delete everything first, then insert the backup's rows.
    case replace
}

/// Outcome of a restore, shown to the user as counts.
struct BackupRestoreResult: Equatable, Sendable {
    var inserted = 0
    var updated = 0
    var skipped = 0

    /// Adds one row's outcome to the counts.
    mutating func count(_ outcome: BackupRowOutcome) {
        switch outcome {
        case .inserted: inserted += 1
        case .updated: updated += 1
        case .skipped: skipped += 1
        }
    }
}

/// What happened to one row an `upsertRow` was applied to.
enum BackupRowOutcome {
    case inserted
    case updated
    case skipped
}

/// Per-entity id→row lookup tables. `restore` builds them once from the
/// store (or empty for `.replace`); the sync engine builds them on demand
/// for the pull-apply path. Inserted rows are registered back into the
/// maps so later children re-link against them.
struct BackupRowMaps {
    var accounts: [UUID: Account] = [:]
    var categories: [UUID: LedgerCategory] = [:]
    var businesses: [UUID: Business] = [:]
    var transactions: [UUID: LedgerTransaction] = [:]
    var rateChanges: [UUID: LoanRateChange] = [:]
    var budgets: [UUID: Budget] = [:]
    var recurringRules: [UUID: RecurringRule] = [:]
    var rentalUnits: [UUID: RentalUnit] = [:]
    var rentalLeases: [UUID: RentalLease] = [:]
}

/// Applies a decoded `BackupDocument` to a `ModelContext`. Every change
/// happens in the caller's context and is committed by a single `save()`;
/// any failure rolls back so a failed restore never leaves partial data.
enum BackupRestorer {

    @discardableResult
    static func restore(
        _ document: BackupDocument,
        mode: BackupRestoreMode,
        into context: ModelContext
    ) throws -> BackupRestoreResult {
        guard document.formatVersion <= BackupCodec.formatVersion else {
            throw BackupError.unsupportedVersion(found: document.formatVersion)
        }

        var result = BackupRestoreResult()
        do {
            var maps: BackupRowMaps

            if mode == .replace {
                try deleteAllRows(in: context)
                maps = BackupRowMaps()
            } else {
                maps = BackupRowMaps(
                    accounts: try context.fetch(FetchDescriptor<Account>())
                        .reduce(into: [:]) { $0[$1.id] = $1 },
                    categories: try context.fetch(FetchDescriptor<LedgerCategory>())
                        .reduce(into: [:]) { $0[$1.id] = $1 },
                    businesses: try context.fetch(FetchDescriptor<Business>())
                        .reduce(into: [:]) { $0[$1.id] = $1 },
                    transactions: try context.fetch(FetchDescriptor<LedgerTransaction>())
                        .reduce(into: [:]) { $0[$1.id] = $1 },
                    rateChanges: try context.fetch(FetchDescriptor<LoanRateChange>())
                        .reduce(into: [:]) { $0[$1.id] = $1 },
                    budgets: try context.fetch(FetchDescriptor<Budget>())
                        .reduce(into: [:]) { $0[$1.id] = $1 },
                    recurringRules: try context.fetch(FetchDescriptor<RecurringRule>())
                        .reduce(into: [:]) { $0[$1.id] = $1 },
                    rentalUnits: try context.fetch(FetchDescriptor<RentalUnit>())
                        .reduce(into: [:]) { $0[$1.id] = $1 },
                    rentalLeases: try context.fetch(FetchDescriptor<RentalLease>())
                        .reduce(into: [:]) { $0[$1.id] = $1 }
                )
            }

            // Parents first so transaction references resolve against the
            // rows just inserted as well as pre-existing ones. Businesses
            // come before accounts because an account's `business` link is
            // re-applied from the restored set.
            for dto in document.categories {
                result.count(upsertRow(dto, into: context, maps: &maps))
            }
            for dto in document.businesses {
                result.count(upsertRow(dto, into: context, maps: &maps))
            }
            for dto in document.accounts {
                result.count(upsertRow(dto, into: context, maps: &maps))
            }

            // Rental units re-link their business; leases re-link their
            // unit — both before the transaction pass, which re-links
            // `rentalLeaseID` against the lease map.
            for dto in document.rentalUnits {
                result.count(upsertRow(dto, into: context, maps: &maps))
            }
            for dto in document.rentalLeases {
                result.count(upsertRow(dto, into: context, maps: &maps))
            }

            for dto in document.transactions {
                result.count(upsertRow(dto, into: context, maps: &maps))
            }

            // Rate changes re-link against the restored loan accounts, so
            // they come after the accounts pass — like transactions do.
            for dto in document.loanRateChanges {
                result.count(upsertRow(dto, into: context, maps: &maps))
            }

            // Budgets re-link their watched category; recurring rules
            // re-link accounts, category and business — like transactions,
            // they come after the parent passes.
            for dto in document.budgets {
                result.count(upsertRow(dto, into: context, maps: &maps))
            }
            for dto in document.recurringRules {
                result.count(upsertRow(dto, into: context, maps: &maps))
            }

            try context.save()
            return result
        } catch {
            context.rollback()
            throw error
        }
    }

    // MARK: - Per-row upserts (shared with the sync pull-apply path)

    /// Find-or-create one row by DTO id, copy every field and re-link its
    /// references through `maps`, then register the row back into `maps`
    /// so later children resolve against it. Exactly what `restore` does
    /// per row — the same rules (transactions keep the newer `updatedAt`).
    /// The context's `save()` is left to the caller.
    @discardableResult
    static func upsertRow(
        _ dto: BackupCategory,
        into context: ModelContext,
        maps: inout BackupRowMaps
    ) -> BackupRowOutcome {
        if let existing = maps.categories[dto.id] {
            apply(dto, to: existing)
            return .updated
        }
        let category = LedgerCategory(id: dto.id, name: "", kind: .expense)
        apply(dto, to: category)
        context.insert(category)
        maps.categories[dto.id] = category
        return .inserted
    }

    @discardableResult
    static func upsertRow(
        _ dto: BackupBusiness,
        into context: ModelContext,
        maps: inout BackupRowMaps
    ) -> BackupRowOutcome {
        if let existing = maps.businesses[dto.id] {
            apply(dto, to: existing)
            return .updated
        }
        let business = Business(id: dto.id, name: "")
        apply(dto, to: business)
        context.insert(business)
        maps.businesses[dto.id] = business
        return .inserted
    }

    @discardableResult
    static func upsertRow(
        _ dto: BackupAccount,
        into context: ModelContext,
        maps: inout BackupRowMaps
    ) -> BackupRowOutcome {
        if let existing = maps.accounts[dto.id] {
            apply(dto, to: existing, businesses: maps.businesses)
            return .updated
        }
        let account = Account(id: dto.id, name: "", kind: .cash)
        apply(dto, to: account, businesses: maps.businesses)
        context.insert(account)
        maps.accounts[dto.id] = account
        return .inserted
    }

    @discardableResult
    static func upsertRow(
        _ dto: BackupRentalUnit,
        into context: ModelContext,
        maps: inout BackupRowMaps
    ) -> BackupRowOutcome {
        if let existing = maps.rentalUnits[dto.id] {
            apply(dto, to: existing, businesses: maps.businesses)
            return .updated
        }
        let unit = RentalUnit(id: dto.id, name: "")
        apply(dto, to: unit, businesses: maps.businesses)
        context.insert(unit)
        maps.rentalUnits[dto.id] = unit
        return .inserted
    }

    @discardableResult
    static func upsertRow(
        _ dto: BackupRentalLease,
        into context: ModelContext,
        maps: inout BackupRowMaps
    ) -> BackupRowOutcome {
        if let existing = maps.rentalLeases[dto.id] {
            apply(dto, to: existing, units: maps.rentalUnits)
            return .updated
        }
        let lease = RentalLease(id: dto.id, tenantName: "")
        apply(dto, to: lease, units: maps.rentalUnits)
        context.insert(lease)
        maps.rentalLeases[dto.id] = lease
        return .inserted
    }

    /// The row with the newer `updatedAt` wins; an equal stamp means the
    /// copies agree and nothing needs writing — `.skipped`.
    @discardableResult
    static func upsertRow(
        _ dto: BackupTransaction,
        into context: ModelContext,
        maps: inout BackupRowMaps
    ) -> BackupRowOutcome {
        if let existing = maps.transactions[dto.id] {
            guard dto.updatedAt > existing.updatedAt else { return .skipped }
            apply(dto, to: existing, accounts: maps.accounts,
                  categories: maps.categories,
                  businesses: maps.businesses, leases: maps.rentalLeases)
            return .updated
        }
        let transaction = LedgerTransaction(id: dto.id, kind: .expense, amount: 0)
        apply(dto, to: transaction, accounts: maps.accounts,
              categories: maps.categories,
              businesses: maps.businesses, leases: maps.rentalLeases)
        context.insert(transaction)
        maps.transactions[dto.id] = transaction
        return .inserted
    }

    @discardableResult
    static func upsertRow(
        _ dto: BackupLoanRateChange,
        into context: ModelContext,
        maps: inout BackupRowMaps
    ) -> BackupRowOutcome {
        if let existing = maps.rateChanges[dto.id] {
            apply(dto, to: existing, accounts: maps.accounts)
            return .updated
        }
        let change = LoanRateChange(
            id: dto.id, fromInstallment: 0, annualRatePercent: 0
        )
        apply(dto, to: change, accounts: maps.accounts)
        context.insert(change)
        maps.rateChanges[dto.id] = change
        return .inserted
    }

    @discardableResult
    static func upsertRow(
        _ dto: BackupBudget,
        into context: ModelContext,
        maps: inout BackupRowMaps
    ) -> BackupRowOutcome {
        if let existing = maps.budgets[dto.id] {
            apply(dto, to: existing, categories: maps.categories)
            return .updated
        }
        let budget = Budget(id: dto.id, monthlyLimit: 0)
        apply(dto, to: budget, categories: maps.categories)
        context.insert(budget)
        maps.budgets[dto.id] = budget
        return .inserted
    }

    @discardableResult
    static func upsertRow(
        _ dto: BackupRecurringRule,
        into context: ModelContext,
        maps: inout BackupRowMaps
    ) -> BackupRowOutcome {
        if let existing = maps.recurringRules[dto.id] {
            apply(dto, to: existing, accounts: maps.accounts,
                  categories: maps.categories, businesses: maps.businesses)
            return .updated
        }
        let rule = RecurringRule(
            id: dto.id, title: "", kind: .expense, amount: 0,
            frequency: .monthly, startDate: .now
        )
        apply(dto, to: rule, accounts: maps.accounts,
              categories: maps.categories, businesses: maps.businesses)
        context.insert(rule)
        maps.recurringRules[dto.id] = rule
        return .inserted
    }

    /// Deletes every row of every model in `AppSchema` — children before
    /// parents so relationship nullification never fights the deletes.
    /// Nothing is saved here: the caller's `save()` commits the deletions
    /// together with whatever it does next (`.replace` restore inserts,
    /// the data reset's reseed). Shared by `.replace` restores and the
    /// "Xoá dữ liệu" reset.
    static func deleteAllRows(in context: ModelContext) throws {
        for row in try context.fetch(FetchDescriptor<LedgerTransaction>()) { context.delete(row) }
        for row in try context.fetch(FetchDescriptor<LoanRateChange>()) { context.delete(row) }
        for row in try context.fetch(FetchDescriptor<Budget>()) { context.delete(row) }
        for row in try context.fetch(FetchDescriptor<RecurringRule>()) { context.delete(row) }
        for row in try context.fetch(FetchDescriptor<RentalLease>()) { context.delete(row) }
        for row in try context.fetch(FetchDescriptor<RentalUnit>()) { context.delete(row) }
        for row in try context.fetch(FetchDescriptor<Account>()) { context.delete(row) }
        for row in try context.fetch(FetchDescriptor<LedgerCategory>()) { context.delete(row) }
        for row in try context.fetch(FetchDescriptor<Business>()) { context.delete(row) }
    }

    // MARK: - Applying DTOs

    /// Copies every stored field; `kindRaw` is assigned directly so a value
    /// this build does not know still round-trips verbatim. `businessID`
    /// (a receivable account's business) is re-linked to a live object; an
    /// id that exists neither in the backup nor in the store becomes nil.
    /// Internal (not private) so the sync applier can reuse it per row.
    static func apply(
        _ dto: BackupAccount,
        to account: Account,
        businesses: [UUID: Business]
    ) {
        account.name = dto.name
        account.kindRaw = dto.kindRaw
        account.openingBalance = dto.openingBalance
        account.icon = dto.icon
        account.colorHex = dto.colorHex
        account.note = dto.note
        account.sortOrder = dto.sortOrder
        account.isArchived = dto.isArchived
        account.createdAt = dto.createdAt
        account.creditLimit = dto.creditLimit
        account.statementDay = dto.statementDay
        account.graceDays = dto.graceDays
        account.loanPrincipal = dto.loanPrincipal
        account.loanAnnualRatePercent = dto.loanAnnualRatePercent
        account.loanTermMonths = dto.loanTermMonths
        account.loanStartDate = dto.loanStartDate
        account.loanPaymentDay = dto.loanPaymentDay
        account.loanMethodRaw = dto.loanMethodRaw
        account.externalSource = dto.externalSource
        account.externalAccountID = dto.externalAccountID
        account.business = dto.businessID.flatMap { businesses[$0] }
    }

    static func apply(_ dto: BackupCategory, to category: LedgerCategory) {
        category.name = dto.name
        category.kindRaw = dto.kindRaw
        category.icon = dto.icon
        category.colorHex = dto.colorHex
        category.sortOrder = dto.sortOrder
        category.isArchived = dto.isArchived
    }

    static func apply(_ dto: BackupBusiness, to business: Business) {
        business.name = dto.name
        business.icon = dto.icon
        business.colorHex = dto.colorHex
        business.note = dto.note
        business.sortOrder = dto.sortOrder
        business.isArchived = dto.isArchived
    }

    /// The account reference is re-linked to a live loan account; an id
    /// that exists neither in the backup nor in the store becomes nil.
    static func apply(
        _ dto: BackupLoanRateChange,
        to change: LoanRateChange,
        accounts: [UUID: Account]
    ) {
        change.fromInstallment = dto.fromInstallment
        change.annualRatePercent = dto.annualRatePercent
        change.account = dto.accountID.flatMap { accounts[$0] }
    }

    /// A unit's business is re-linked to a live object; an id that exists
    /// neither in the backup nor in the store becomes nil.
    static func apply(
        _ dto: BackupRentalUnit,
        to unit: RentalUnit,
        businesses: [UUID: Business]
    ) {
        unit.name = dto.name
        unit.listPrice = dto.listPrice
        unit.note = dto.note
        unit.sortOrder = dto.sortOrder
        unit.isArchived = dto.isArchived
        unit.createdAt = dto.createdAt
        unit.business = dto.businessID.flatMap { businesses[$0] }
    }

    /// A lease's room is re-linked to a live object; an id that exists
    /// neither in the backup nor in the store becomes nil.
    static func apply(
        _ dto: BackupRentalLease,
        to lease: RentalLease,
        units: [UUID: RentalUnit]
    ) {
        lease.tenantName = dto.tenantName
        lease.tenantPhone = dto.tenantPhone
        lease.startDate = dto.startDate
        lease.endDate = dto.endDate
        lease.monthlyRent = dto.monthlyRent
        lease.deposit = dto.deposit
        lease.paymentDay = dto.paymentDay
        lease.isActive = dto.isActive
        lease.note = dto.note
        lease.createdAt = dto.createdAt
        lease.unit = dto.unitID.flatMap { units[$0] }
    }

    /// IDs in the DTO are re-linked to live objects; an id that exists
    /// neither in the backup nor in the store becomes nil.
    static func apply(
        _ dto: BackupTransaction,
        to transaction: LedgerTransaction,
        accounts: [UUID: Account],
        categories: [UUID: LedgerCategory],
        businesses: [UUID: Business],
        leases: [UUID: RentalLease]
    ) {
        transaction.kindRaw = dto.kindRaw
        transaction.amount = dto.amount
        transaction.date = dto.date
        transaction.note = dto.note
        transaction.account = dto.accountID.flatMap { accounts[$0] }
        transaction.toAccount = dto.toAccountID.flatMap { accounts[$0] }
        transaction.category = dto.categoryID.flatMap { categories[$0] }
        transaction.business = dto.businessID.flatMap { businesses[$0] }
        transaction.rentalLease = dto.rentalLeaseID.flatMap { leases[$0] }
        transaction.rentalPeriod = dto.rentalPeriod
        transaction.needsReview = dto.needsReview
        transaction.externalSource = dto.externalSource
        transaction.externalID = dto.externalID
        transaction.createdAt = dto.createdAt
        transaction.updatedAt = dto.updatedAt
    }

    /// The watched category is re-linked to a live object; an id that
    /// exists neither in the backup nor in the store becomes nil — the
    /// budget then reads as the overall monthly one.
    static func apply(
        _ dto: BackupBudget,
        to budget: Budget,
        categories: [UUID: LedgerCategory]
    ) {
        budget.monthlyLimit = dto.monthlyLimit
        budget.isActive = dto.isActive
        budget.note = dto.note
        budget.createdAt = dto.createdAt
        budget.category = dto.categoryID.flatMap { categories[$0] }
    }

    /// `kindRaw`/`frequencyRaw` are assigned directly so a value this build
    /// does not know still round-trips verbatim.
    static func apply(
        _ dto: BackupRecurringRule,
        to rule: RecurringRule,
        accounts: [UUID: Account],
        categories: [UUID: LedgerCategory],
        businesses: [UUID: Business]
    ) {
        rule.title = dto.title
        rule.kindRaw = dto.kindRaw
        rule.amount = dto.amount
        rule.note = dto.note
        rule.account = dto.accountID.flatMap { accounts[$0] }
        rule.toAccount = dto.toAccountID.flatMap { accounts[$0] }
        rule.category = dto.categoryID.flatMap { categories[$0] }
        rule.business = dto.businessID.flatMap { businesses[$0] }
        rule.frequencyRaw = dto.frequencyRaw
        rule.interval = dto.interval
        rule.startDate = dto.startDate
        rule.endDate = dto.endDate
        rule.maximumOccurrences = dto.maximumOccurrences
        rule.lastGeneratedDate = dto.lastGeneratedDate
        rule.autoCreate = dto.autoCreate
        rule.isActive = dto.isActive
        rule.createdAt = dto.createdAt
    }
}
