import Foundation

/// A versioned JSON snapshot of the whole local store — every account,
/// category, business and transaction, with relationships written as UUID
/// references. `formatVersion` gates restores: a file written by a newer
/// app is refused instead of being half-read.
///
/// Version history:
/// - 1: accounts, categories, businesses, transactions.
/// - 2: adds `loanRateChanges`.
/// - 3: adds `budgets` and `recurringRules`. Older files still decode —
///   absent keys are read as empty lists.
/// - 4: adds `businessID` on accounts — the business a receivable account
///   belongs to. Older files decode it as nil.
/// - 5: adds `rentalUnits`/`rentalLeases` (the serviced-apartment rooms and
///   tenancies) plus `rentalLeaseID`/`rentalPeriod` on transactions — the
///   lease a rent collection belongs to and the month it covers. Older
///   files decode the new keys as empty lists / nil.
struct BackupDocument: Codable, Equatable, Sendable {
    var formatVersion: Int
    var exportedAt: Date
    var appVersion: String
    var accounts: [BackupAccount]
    var categories: [BackupCategory]
    var businesses: [BackupBusiness]
    var transactions: [BackupTransaction]
    var loanRateChanges: [BackupLoanRateChange]
    var budgets: [BackupBudget]
    var recurringRules: [BackupRecurringRule]
    var rentalUnits: [BackupRentalUnit]
    var rentalLeases: [BackupRentalLease]

    init(
        formatVersion: Int,
        exportedAt: Date,
        appVersion: String,
        accounts: [BackupAccount],
        categories: [BackupCategory],
        businesses: [BackupBusiness],
        transactions: [BackupTransaction],
        loanRateChanges: [BackupLoanRateChange] = [],
        budgets: [BackupBudget] = [],
        recurringRules: [BackupRecurringRule] = [],
        rentalUnits: [BackupRentalUnit] = [],
        rentalLeases: [BackupRentalLease] = []
    ) {
        self.formatVersion = formatVersion
        self.exportedAt = exportedAt
        self.appVersion = appVersion
        self.accounts = accounts
        self.categories = categories
        self.businesses = businesses
        self.transactions = transactions
        self.loanRateChanges = loanRateChanges
        self.budgets = budgets
        self.recurringRules = recurringRules
        self.rentalUnits = rentalUnits
        self.rentalLeases = rentalLeases
    }

    /// Fields added after v1 are optional on read: a v1 file lacks
    /// `loanRateChanges`, v1/v2 files lack `budgets`/`recurringRules`,
    /// pre-v5 files lack `rentalUnits`/`rentalLeases`.
    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        formatVersion = try container.decode(Int.self, forKey: .formatVersion)
        exportedAt = try container.decode(Date.self, forKey: .exportedAt)
        appVersion = try container.decode(String.self, forKey: .appVersion)
        accounts = try container.decode([BackupAccount].self, forKey: .accounts)
        categories = try container.decode([BackupCategory].self, forKey: .categories)
        businesses = try container.decode([BackupBusiness].self, forKey: .businesses)
        transactions = try container.decode([BackupTransaction].self, forKey: .transactions)
        loanRateChanges = try container.decodeIfPresent(
            [BackupLoanRateChange].self, forKey: .loanRateChanges
        ) ?? []
        budgets = try container.decodeIfPresent(
            [BackupBudget].self, forKey: .budgets
        ) ?? []
        recurringRules = try container.decodeIfPresent(
            [BackupRecurringRule].self, forKey: .recurringRules
        ) ?? []
        rentalUnits = try container.decodeIfPresent(
            [BackupRentalUnit].self, forKey: .rentalUnits
        ) ?? []
        rentalLeases = try container.decodeIfPresent(
            [BackupRentalLease].self, forKey: .rentalLeases
        ) ?? []
    }
}

/// Stored fields of `Account`. Transactions hold the account references, so
/// an account DTO has no relationship fields of its own.
struct BackupAccount: Codable, Equatable, Sendable {
    var id: UUID
    var name: String
    var kindRaw: String
    var openingBalance: Int64
    var icon: String
    var colorHex: String
    var note: String
    var sortOrder: Int
    var isArchived: Bool
    var createdAt: Date

    // Credit-card fields.
    var creditLimit: Int64?
    var statementDay: Int?
    var graceDays: Int?

    // Loan fields.
    var loanPrincipal: Int64?
    var loanAnnualRatePercent: Double?
    var loanTermMonths: Int?
    var loanStartDate: Date?
    var loanPaymentDay: Int?
    var loanMethodRaw: String?

    // External bank/linking fields.
    var externalSource: String?
    var externalAccountID: String?

    /// The business a receivable account belongs to (formatVersion 4) —
    /// re-linked on restore; nil everywhere else.
    var businessID: UUID?
}

extension BackupAccount {
    init(_ account: Account) {
        id = account.id
        name = account.name
        kindRaw = account.kindRaw
        openingBalance = account.openingBalance
        icon = account.icon
        colorHex = account.colorHex
        note = account.note
        sortOrder = account.sortOrder
        isArchived = account.isArchived
        createdAt = account.createdAt
        creditLimit = account.creditLimit
        statementDay = account.statementDay
        graceDays = account.graceDays
        loanPrincipal = account.loanPrincipal
        loanAnnualRatePercent = account.loanAnnualRatePercent
        loanTermMonths = account.loanTermMonths
        loanStartDate = account.loanStartDate
        loanPaymentDay = account.loanPaymentDay
        loanMethodRaw = account.loanMethodRaw
        externalSource = account.externalSource
        externalAccountID = account.externalAccountID
        businessID = account.business?.id
    }
}

/// Stored fields of `LedgerCategory`.
struct BackupCategory: Codable, Equatable, Sendable {
    var id: UUID
    var name: String
    var kindRaw: String
    var icon: String
    var colorHex: String
    var sortOrder: Int
    var isArchived: Bool
}

extension BackupCategory {
    init(_ category: LedgerCategory) {
        id = category.id
        name = category.name
        kindRaw = category.kindRaw
        icon = category.icon
        colorHex = category.colorHex
        sortOrder = category.sortOrder
        isArchived = category.isArchived
    }
}

/// Stored fields of `Business`.
struct BackupBusiness: Codable, Equatable, Sendable {
    var id: UUID
    var name: String
    var icon: String
    var colorHex: String
    var note: String
    var sortOrder: Int
    var isArchived: Bool
}

extension BackupBusiness {
    init(_ business: Business) {
        id = business.id
        name = business.name
        icon = business.icon
        colorHex = business.colorHex
        note = business.note
        sortOrder = business.sortOrder
        isArchived = business.isArchived
    }
}

/// Stored fields of `LoanRateChange` (added in formatVersion 2). The owning
/// loan account travels as `accountID` and is re-linked on restore.
struct BackupLoanRateChange: Codable, Equatable, Sendable {
    var id: UUID
    var fromInstallment: Int
    var annualRatePercent: Double
    var accountID: UUID?
}

extension BackupLoanRateChange {
    init(_ change: LoanRateChange) {
        id = change.id
        fromInstallment = change.fromInstallment
        annualRatePercent = change.annualRatePercent
        accountID = change.account?.id
    }
}

/// Stored fields of `Budget` (added in formatVersion 3). The watched
/// category travels as `categoryID` and is re-linked on restore; nil is the
/// overall monthly budget.
struct BackupBudget: Codable, Equatable, Sendable {
    var id: UUID
    var monthlyLimit: Int64
    var isActive: Bool
    var note: String
    var createdAt: Date
    var categoryID: UUID?
}

extension BackupBudget {
    init(_ budget: Budget) {
        id = budget.id
        monthlyLimit = budget.monthlyLimit
        isActive = budget.isActive
        note = budget.note
        createdAt = budget.createdAt
        categoryID = budget.category?.id
    }
}

/// Stored fields of `RecurringRule` (added in formatVersion 3).
/// Relationships travel as UUIDs and are re-linked on restore.
struct BackupRecurringRule: Codable, Equatable, Sendable {
    var id: UUID
    var title: String
    var kindRaw: String
    var amount: Int64
    var note: String
    var accountID: UUID?
    var toAccountID: UUID?
    var categoryID: UUID?
    var businessID: UUID?
    var frequencyRaw: String
    var interval: Int
    var startDate: Date
    var endDate: Date?
    var maximumOccurrences: Int?
    var lastGeneratedDate: Date?
    var autoCreate: Bool
    var isActive: Bool
    var createdAt: Date
}

extension BackupRecurringRule {
    init(_ rule: RecurringRule) {
        id = rule.id
        title = rule.title
        kindRaw = rule.kindRaw
        amount = rule.amount
        note = rule.note
        accountID = rule.account?.id
        toAccountID = rule.toAccount?.id
        categoryID = rule.category?.id
        businessID = rule.business?.id
        frequencyRaw = rule.frequencyRaw
        interval = rule.interval
        startDate = rule.startDate
        endDate = rule.endDate
        maximumOccurrences = rule.maximumOccurrences
        lastGeneratedDate = rule.lastGeneratedDate
        autoCreate = rule.autoCreate
        isActive = rule.isActive
        createdAt = rule.createdAt
    }
}

/// Stored fields of `RentalUnit` (added in formatVersion 5). The owning
/// business travels as `businessID` and is re-linked on restore.
struct BackupRentalUnit: Codable, Equatable, Sendable {
    var id: UUID
    var name: String
    var listPrice: Int64
    var note: String
    var sortOrder: Int
    var isArchived: Bool
    var createdAt: Date
    var businessID: UUID?
}

extension BackupRentalUnit {
    init(_ unit: RentalUnit) {
        id = unit.id
        name = unit.name
        listPrice = unit.listPrice
        note = unit.note
        sortOrder = unit.sortOrder
        isArchived = unit.isArchived
        createdAt = unit.createdAt
        businessID = unit.business?.id
    }
}

/// Stored fields of `RentalLease` (added in formatVersion 5). The room
/// travels as `unitID` and is re-linked on restore; rent collections are
/// re-linked through `BackupTransaction.rentalLeaseID`.
struct BackupRentalLease: Codable, Equatable, Sendable {
    var id: UUID
    var tenantName: String
    var tenantPhone: String
    var startDate: Date
    var endDate: Date?
    var monthlyRent: Int64
    var deposit: Int64
    var paymentDay: Int
    var isActive: Bool
    var note: String
    var createdAt: Date
    var unitID: UUID?
}

extension BackupRentalLease {
    init(_ lease: RentalLease) {
        id = lease.id
        tenantName = lease.tenantName
        tenantPhone = lease.tenantPhone
        startDate = lease.startDate
        endDate = lease.endDate
        monthlyRent = lease.monthlyRent
        deposit = lease.deposit
        paymentDay = lease.paymentDay
        isActive = lease.isActive
        note = lease.note
        createdAt = lease.createdAt
        unitID = lease.unit?.id
    }
}

/// Stored fields of `LedgerTransaction`. Relationships travel as the UUIDs
/// of the referenced rows and are re-linked to live objects on restore.
struct BackupTransaction: Codable, Equatable, Sendable {
    var id: UUID
    var kindRaw: String
    var amount: Int64
    var date: Date
    var note: String
    var accountID: UUID?
    var toAccountID: UUID?
    var categoryID: UUID?
    var businessID: UUID?
    var needsReview: Bool
    var externalSource: String?
    var externalID: String?
    var createdAt: Date
    var updatedAt: Date

    // Rent collection fields (formatVersion 5): the lease a rent payment
    // belongs to and the first day of the month it covers. Lease extras
    // carry `rentalLeaseID` with a nil `rentalPeriod`.
    var rentalLeaseID: UUID?
    var rentalPeriod: Date?
}

extension BackupTransaction {
    init(_ transaction: LedgerTransaction) {
        id = transaction.id
        kindRaw = transaction.kindRaw
        amount = transaction.amount
        date = transaction.date
        note = transaction.note
        accountID = transaction.account?.id
        toAccountID = transaction.toAccount?.id
        categoryID = transaction.category?.id
        businessID = transaction.business?.id
        needsReview = transaction.needsReview
        externalSource = transaction.externalSource
        externalID = transaction.externalID
        createdAt = transaction.createdAt
        updatedAt = transaction.updatedAt
        rentalLeaseID = transaction.rentalLease?.id
        rentalPeriod = transaction.rentalPeriod
    }
}
