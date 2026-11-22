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
            var accounts: [UUID: Account]
            var categories: [UUID: LedgerCategory]
            var businesses: [UUID: Business]
            var transactions: [UUID: LedgerTransaction]
            var rateChanges: [UUID: LoanRateChange]
            var budgets: [UUID: Budget]
            var recurringRules: [UUID: RecurringRule]

            if mode == .replace {
                for row in try context.fetch(FetchDescriptor<LedgerTransaction>()) { context.delete(row) }
                for row in try context.fetch(FetchDescriptor<LoanRateChange>()) { context.delete(row) }
                for row in try context.fetch(FetchDescriptor<Budget>()) { context.delete(row) }
                for row in try context.fetch(FetchDescriptor<RecurringRule>()) { context.delete(row) }
                for row in try context.fetch(FetchDescriptor<Account>()) { context.delete(row) }
                for row in try context.fetch(FetchDescriptor<LedgerCategory>()) { context.delete(row) }
                for row in try context.fetch(FetchDescriptor<Business>()) { context.delete(row) }
                accounts = [:]
                categories = [:]
                businesses = [:]
                transactions = [:]
                rateChanges = [:]
                budgets = [:]
                recurringRules = [:]
            } else {
                accounts = try context.fetch(FetchDescriptor<Account>())
                    .reduce(into: [:]) { $0[$1.id] = $1 }
                categories = try context.fetch(FetchDescriptor<LedgerCategory>())
                    .reduce(into: [:]) { $0[$1.id] = $1 }
                businesses = try context.fetch(FetchDescriptor<Business>())
                    .reduce(into: [:]) { $0[$1.id] = $1 }
                transactions = try context.fetch(FetchDescriptor<LedgerTransaction>())
                    .reduce(into: [:]) { $0[$1.id] = $1 }
                rateChanges = try context.fetch(FetchDescriptor<LoanRateChange>())
                    .reduce(into: [:]) { $0[$1.id] = $1 }
                budgets = try context.fetch(FetchDescriptor<Budget>())
                    .reduce(into: [:]) { $0[$1.id] = $1 }
                recurringRules = try context.fetch(FetchDescriptor<RecurringRule>())
                    .reduce(into: [:]) { $0[$1.id] = $1 }
            }

            // Parents first so transaction references resolve against the
            // rows just inserted as well as pre-existing ones. Businesses
            // come before accounts because an account's `business` link is
            // re-applied from the restored set.
            for dto in document.categories {
                if let existing = categories[dto.id] {
                    apply(dto, to: existing)
                    result.updated += 1
                } else {
                    let category = LedgerCategory(id: dto.id, name: "", kind: .expense)
                    apply(dto, to: category)
                    context.insert(category)
                    categories[dto.id] = category
                    result.inserted += 1
                }
            }

            for dto in document.businesses {
                if let existing = businesses[dto.id] {
                    apply(dto, to: existing)
                    result.updated += 1
                } else {
                    let business = Business(id: dto.id, name: "")
                    apply(dto, to: business)
                    context.insert(business)
                    businesses[dto.id] = business
                    result.inserted += 1
                }
            }

            for dto in document.accounts {
                if let existing = accounts[dto.id] {
                    apply(dto, to: existing, businesses: businesses)
                    result.updated += 1
                } else {
                    let account = Account(id: dto.id, name: "", kind: .cash)
                    apply(dto, to: account, businesses: businesses)
                    context.insert(account)
                    accounts[dto.id] = account
                    result.inserted += 1
                }
            }

            for dto in document.transactions {
                if let existing = transactions[dto.id] {
                    // The row with the newer updatedAt wins; an equal stamp
                    // means the copies agree and nothing needs writing.
                    if dto.updatedAt > existing.updatedAt {
                        apply(dto, to: existing, accounts: accounts, categories: categories, businesses: businesses)
                        result.updated += 1
                    } else {
                        result.skipped += 1
                    }
                } else {
                    let transaction = LedgerTransaction(id: dto.id, kind: .expense, amount: 0)
                    apply(dto, to: transaction, accounts: accounts, categories: categories, businesses: businesses)
                    context.insert(transaction)
                    transactions[dto.id] = transaction
                    result.inserted += 1
                }
            }

            // Rate changes re-link against the restored loan accounts, so
            // they come after the accounts pass — like transactions do.
            for dto in document.loanRateChanges {
                if let existing = rateChanges[dto.id] {
                    apply(dto, to: existing, accounts: accounts)
                    result.updated += 1
                } else {
                    let change = LoanRateChange(
                        id: dto.id, fromInstallment: 0, annualRatePercent: 0
                    )
                    apply(dto, to: change, accounts: accounts)
                    context.insert(change)
                    rateChanges[dto.id] = change
                    result.inserted += 1
                }
            }

            // Budgets re-link their watched category; recurring rules
            // re-link accounts, category and business — like transactions,
            // they come after the parent passes.
            for dto in document.budgets {
                if let existing = budgets[dto.id] {
                    apply(dto, to: existing, categories: categories)
                    result.updated += 1
                } else {
                    let budget = Budget(id: dto.id, monthlyLimit: 0)
                    apply(dto, to: budget, categories: categories)
                    context.insert(budget)
                    budgets[dto.id] = budget
                    result.inserted += 1
                }
            }

            for dto in document.recurringRules {
                if let existing = recurringRules[dto.id] {
                    apply(dto, to: existing, accounts: accounts,
                          categories: categories, businesses: businesses)
                    result.updated += 1
                } else {
                    let rule = RecurringRule(
                        id: dto.id, title: "", kind: .expense, amount: 0,
                        frequency: .monthly, startDate: .now
                    )
                    apply(dto, to: rule, accounts: accounts,
                          categories: categories, businesses: businesses)
                    context.insert(rule)
                    recurringRules[dto.id] = rule
                    result.inserted += 1
                }
            }

            try context.save()
            return result
        } catch {
            context.rollback()
            throw error
        }
    }

    // MARK: - Applying DTOs

    /// Copies every stored field; `kindRaw` is assigned directly so a value
    /// this build does not know still round-trips verbatim. `businessID`
    /// (a receivable account's business) is re-linked to a live object; an
    /// id that exists neither in the backup nor in the store becomes nil.
    private static func apply(
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

    private static func apply(_ dto: BackupCategory, to category: LedgerCategory) {
        category.name = dto.name
        category.kindRaw = dto.kindRaw
        category.icon = dto.icon
        category.colorHex = dto.colorHex
        category.sortOrder = dto.sortOrder
        category.isArchived = dto.isArchived
    }

    private static func apply(_ dto: BackupBusiness, to business: Business) {
        business.name = dto.name
        business.icon = dto.icon
        business.colorHex = dto.colorHex
        business.note = dto.note
        business.sortOrder = dto.sortOrder
        business.isArchived = dto.isArchived
    }

    /// The account reference is re-linked to a live loan account; an id
    /// that exists neither in the backup nor in the store becomes nil.
    private static func apply(
        _ dto: BackupLoanRateChange,
        to change: LoanRateChange,
        accounts: [UUID: Account]
    ) {
        change.fromInstallment = dto.fromInstallment
        change.annualRatePercent = dto.annualRatePercent
        change.account = dto.accountID.flatMap { accounts[$0] }
    }

    /// IDs in the DTO are re-linked to live objects; an id that exists
    /// neither in the backup nor in the store becomes nil.
    private static func apply(
        _ dto: BackupTransaction,
        to transaction: LedgerTransaction,
        accounts: [UUID: Account],
        categories: [UUID: LedgerCategory],
        businesses: [UUID: Business]
    ) {
        transaction.kindRaw = dto.kindRaw
        transaction.amount = dto.amount
        transaction.date = dto.date
        transaction.note = dto.note
        transaction.account = dto.accountID.flatMap { accounts[$0] }
        transaction.toAccount = dto.toAccountID.flatMap { accounts[$0] }
        transaction.category = dto.categoryID.flatMap { categories[$0] }
        transaction.business = dto.businessID.flatMap { businesses[$0] }
        transaction.needsReview = dto.needsReview
        transaction.externalSource = dto.externalSource
        transaction.externalID = dto.externalID
        transaction.createdAt = dto.createdAt
        transaction.updatedAt = dto.updatedAt
    }

    /// The watched category is re-linked to a live object; an id that
    /// exists neither in the backup nor in the store becomes nil — the
    /// budget then reads as the overall monthly one.
    private static func apply(
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
    private static func apply(
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
