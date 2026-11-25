import FinanceCore
import Foundation
import SwiftData

/// A backup-v5 DTO for one ledger row, type-erased so the sync engine can
/// handle any entity through one type. This is exactly the `data` payload
/// a push change carries and a pull record returns.
enum SyncBackupDTO: Equatable, Sendable {
    case account(BackupAccount)
    case category(BackupCategory)
    case business(BackupBusiness)
    case transaction(BackupTransaction)
    case loanRateChange(BackupLoanRateChange)
    case budget(BackupBudget)
    case recurringRule(BackupRecurringRule)
    case rentalUnit(BackupRentalUnit)
    case rentalLease(BackupRentalLease)

    var entity: SyncEntity {
        switch self {
        case .account: return .account
        case .category: return .category
        case .business: return .business
        case .transaction: return .transaction
        case .loanRateChange: return .loanRateChange
        case .budget: return .budget
        case .recurringRule: return .recurringRule
        case .rentalUnit: return .rentalUnit
        case .rentalLease: return .rentalLease
        }
    }

    var id: UUID {
        switch self {
        case .account(let dto): return dto.id
        case .category(let dto): return dto.id
        case .business(let dto): return dto.id
        case .transaction(let dto): return dto.id
        case .loanRateChange(let dto): return dto.id
        case .budget(let dto): return dto.id
        case .recurringRule(let dto): return dto.id
        case .rentalUnit(let dto): return dto.id
        case .rentalLease(let dto): return dto.id
        }
    }

    var recordKey: SyncRecordKey { SyncRecordKey(entity: entity, id: id) }
}

/// One DTO field tagged by scalar kind — the single enumeration feeding
/// BOTH the canonical content hash (`SyncCanonicalScalar`) and the wire
/// `SyncJSONValue`, so the two encodings can never drift apart. Nil
/// optionals are simply absent from a DTO's field list, exactly like the
/// keys their JSON omits.
enum SyncDTOField: Sendable {
    case string(String)
    case int(Int64)
    case double(Double)
    case bool(Bool)
    case date(Date)
    case uuid(UUID)

    /// The canonical-hash rendering — lowercase UUIDs, `.sssZ` dates.
    var canonical: SyncCanonicalScalar {
        switch self {
        case .string(let value): return .string(value)
        case .int(let value): return .int(value)
        case .double(let value): return .double(value)
        case .bool(let value): return .bool(value)
        case .date(let value): return .date(value)
        case .uuid(let value): return .uuid(value)
        }
    }

    /// The wire rendering — the byte shape `BackupCodec.makeEncoder`
    /// writes: uppercase UUID strings, `BackupDateCodec` timestamps.
    var json: SyncJSONValue {
        switch self {
        case .string(let value): return .string(value)
        case .int(let value): return .int(value)
        case .double(let value): return .double(value)
        case .bool(let value): return .bool(value)
        case .date(let value): return .string(BackupDateCodec.string(from: value))
        case .uuid(let value): return .string(value.uuidString)
        }
    }
}

extension SyncBackupDTO {
    /// Every non-nil stored field — declared once per DTO so the
    /// canonical hash and the wire JSON always cover the same set.
    var syncFields: [(String, SyncDTOField)] {
        switch self {
        case .account(let dto): return Self.fields(dto)
        case .category(let dto): return Self.fields(dto)
        case .business(let dto): return Self.fields(dto)
        case .transaction(let dto): return Self.fields(dto)
        case .loanRateChange(let dto): return Self.fields(dto)
        case .budget(let dto): return Self.fields(dto)
        case .recurringRule(let dto): return Self.fields(dto)
        case .rentalUnit(let dto): return Self.fields(dto)
        case .rentalLease(let dto): return Self.fields(dto)
        }
    }

    private static func fields(_ dto: BackupAccount) -> [(String, SyncDTOField)] {
        var fields: [(String, SyncDTOField)] = [
            ("id", .uuid(dto.id)),
            ("name", .string(dto.name)),
            ("kindRaw", .string(dto.kindRaw)),
            ("openingBalance", .int(dto.openingBalance)),
            ("icon", .string(dto.icon)),
            ("colorHex", .string(dto.colorHex)),
            ("note", .string(dto.note)),
            ("sortOrder", .int(Int64(dto.sortOrder))),
            ("isArchived", .bool(dto.isArchived)),
            ("createdAt", .date(dto.createdAt)),
        ]
        if let v = dto.creditLimit { fields.append(("creditLimit", .int(v))) }
        if let v = dto.statementDay { fields.append(("statementDay", .int(Int64(v)))) }
        if let v = dto.graceDays { fields.append(("graceDays", .int(Int64(v)))) }
        if let v = dto.loanPrincipal { fields.append(("loanPrincipal", .int(v))) }
        if let v = dto.loanAnnualRatePercent { fields.append(("loanAnnualRatePercent", .double(v))) }
        if let v = dto.loanTermMonths { fields.append(("loanTermMonths", .int(Int64(v)))) }
        if let v = dto.loanStartDate { fields.append(("loanStartDate", .date(v))) }
        if let v = dto.loanPaymentDay { fields.append(("loanPaymentDay", .int(Int64(v)))) }
        if let v = dto.loanMethodRaw { fields.append(("loanMethodRaw", .string(v))) }
        if let v = dto.externalSource { fields.append(("externalSource", .string(v))) }
        if let v = dto.externalAccountID { fields.append(("externalAccountID", .string(v))) }
        if let v = dto.businessID { fields.append(("businessID", .uuid(v))) }
        return fields
    }

    private static func fields(_ dto: BackupCategory) -> [(String, SyncDTOField)] {
        [
            ("id", .uuid(dto.id)),
            ("name", .string(dto.name)),
            ("kindRaw", .string(dto.kindRaw)),
            ("icon", .string(dto.icon)),
            ("colorHex", .string(dto.colorHex)),
            ("sortOrder", .int(Int64(dto.sortOrder))),
            ("isArchived", .bool(dto.isArchived)),
        ]
    }

    private static func fields(_ dto: BackupBusiness) -> [(String, SyncDTOField)] {
        [
            ("id", .uuid(dto.id)),
            ("name", .string(dto.name)),
            ("icon", .string(dto.icon)),
            ("colorHex", .string(dto.colorHex)),
            ("note", .string(dto.note)),
            ("sortOrder", .int(Int64(dto.sortOrder))),
            ("isArchived", .bool(dto.isArchived)),
        ]
    }

    private static func fields(_ dto: BackupTransaction) -> [(String, SyncDTOField)] {
        var fields: [(String, SyncDTOField)] = [
            ("id", .uuid(dto.id)),
            ("kindRaw", .string(dto.kindRaw)),
            ("amount", .int(dto.amount)),
            ("date", .date(dto.date)),
            ("note", .string(dto.note)),
            ("needsReview", .bool(dto.needsReview)),
            ("createdAt", .date(dto.createdAt)),
            ("updatedAt", .date(dto.updatedAt)),
        ]
        if let v = dto.accountID { fields.append(("accountID", .uuid(v))) }
        if let v = dto.toAccountID { fields.append(("toAccountID", .uuid(v))) }
        if let v = dto.categoryID { fields.append(("categoryID", .uuid(v))) }
        if let v = dto.businessID { fields.append(("businessID", .uuid(v))) }
        if let v = dto.externalSource { fields.append(("externalSource", .string(v))) }
        if let v = dto.externalID { fields.append(("externalID", .string(v))) }
        if let v = dto.rentalLeaseID { fields.append(("rentalLeaseID", .uuid(v))) }
        if let v = dto.rentalPeriod { fields.append(("rentalPeriod", .date(v))) }
        return fields
    }

    private static func fields(_ dto: BackupLoanRateChange) -> [(String, SyncDTOField)] {
        var fields: [(String, SyncDTOField)] = [
            ("id", .uuid(dto.id)),
            ("fromInstallment", .int(Int64(dto.fromInstallment))),
            ("annualRatePercent", .double(dto.annualRatePercent)),
        ]
        if let v = dto.accountID { fields.append(("accountID", .uuid(v))) }
        return fields
    }

    private static func fields(_ dto: BackupBudget) -> [(String, SyncDTOField)] {
        var fields: [(String, SyncDTOField)] = [
            ("id", .uuid(dto.id)),
            ("monthlyLimit", .int(dto.monthlyLimit)),
            ("isActive", .bool(dto.isActive)),
            ("note", .string(dto.note)),
            ("createdAt", .date(dto.createdAt)),
        ]
        if let v = dto.categoryID { fields.append(("categoryID", .uuid(v))) }
        return fields
    }

    private static func fields(_ dto: BackupRecurringRule) -> [(String, SyncDTOField)] {
        var fields: [(String, SyncDTOField)] = [
            ("id", .uuid(dto.id)),
            ("title", .string(dto.title)),
            ("kindRaw", .string(dto.kindRaw)),
            ("amount", .int(dto.amount)),
            ("note", .string(dto.note)),
            ("frequencyRaw", .string(dto.frequencyRaw)),
            ("interval", .int(Int64(dto.interval))),
            ("startDate", .date(dto.startDate)),
            ("autoCreate", .bool(dto.autoCreate)),
            ("isActive", .bool(dto.isActive)),
            ("createdAt", .date(dto.createdAt)),
        ]
        if let v = dto.accountID { fields.append(("accountID", .uuid(v))) }
        if let v = dto.toAccountID { fields.append(("toAccountID", .uuid(v))) }
        if let v = dto.categoryID { fields.append(("categoryID", .uuid(v))) }
        if let v = dto.businessID { fields.append(("businessID", .uuid(v))) }
        if let v = dto.endDate { fields.append(("endDate", .date(v))) }
        if let v = dto.maximumOccurrences { fields.append(("maximumOccurrences", .int(Int64(v)))) }
        if let v = dto.lastGeneratedDate { fields.append(("lastGeneratedDate", .date(v))) }
        return fields
    }

    private static func fields(_ dto: BackupRentalUnit) -> [(String, SyncDTOField)] {
        var fields: [(String, SyncDTOField)] = [
            ("id", .uuid(dto.id)),
            ("name", .string(dto.name)),
            ("listPrice", .int(dto.listPrice)),
            ("note", .string(dto.note)),
            ("sortOrder", .int(Int64(dto.sortOrder))),
            ("isArchived", .bool(dto.isArchived)),
            ("createdAt", .date(dto.createdAt)),
        ]
        if let v = dto.businessID { fields.append(("businessID", .uuid(v))) }
        return fields
    }

    private static func fields(_ dto: BackupRentalLease) -> [(String, SyncDTOField)] {
        var fields: [(String, SyncDTOField)] = [
            ("id", .uuid(dto.id)),
            ("tenantName", .string(dto.tenantName)),
            ("tenantPhone", .string(dto.tenantPhone)),
            ("startDate", .date(dto.startDate)),
            ("monthlyRent", .int(dto.monthlyRent)),
            ("deposit", .int(dto.deposit)),
            ("paymentDay", .int(Int64(dto.paymentDay))),
            ("isActive", .bool(dto.isActive)),
            ("note", .string(dto.note)),
            ("createdAt", .date(dto.createdAt)),
        ]
        if let v = dto.endDate { fields.append(("endDate", .date(v))) }
        if let v = dto.unitID { fields.append(("unitID", .uuid(v))) }
        return fields
    }
}

/// Per-row mapping between the SwiftData models and their backup-v5
/// DTOs — the sync engine's read/write seam. Everything is a thin
/// dispatch over `BackupDocument`'s per-row initializers and
/// `BackupRestorer`'s per-row `upsertRow`, so backup and sync can never
/// drift apart.
enum SyncRecordMapper {

    // MARK: - Model → DTO (export side)

    /// The sync entity a SwiftData model type maps to, or nil for models
    /// outside the synced set.
    static func entity(of row: any PersistentModel) -> SyncEntity? {
        switch row {
        case is Account: return .account
        case is LedgerCategory: return .category
        case is Business: return .business
        case is LedgerTransaction: return .transaction
        case is LoanRateChange: return .loanRateChange
        case is Budget: return .budget
        case is RecurringRule: return .recurringRule
        case is RentalUnit: return .rentalUnit
        case is RentalLease: return .rentalLease
        default: return nil
        }
    }

    /// The row's backup-v5 DTO — what gets hashed and pushed. nil for
    /// models outside the synced set.
    static func dto(of row: any PersistentModel) -> SyncBackupDTO? {
        switch row {
        case let account as Account: return .account(BackupAccount(account))
        case let category as LedgerCategory: return .category(BackupCategory(category))
        case let business as Business: return .business(BackupBusiness(business))
        case let transaction as LedgerTransaction:
            return .transaction(BackupTransaction(transaction))
        case let change as LoanRateChange:
            return .loanRateChange(BackupLoanRateChange(change))
        case let budget as Budget: return .budget(BackupBudget(budget))
        case let rule as RecurringRule:
            return .recurringRule(BackupRecurringRule(rule))
        case let unit as RentalUnit: return .rentalUnit(BackupRentalUnit(unit))
        case let lease as RentalLease: return .rentalLease(BackupRentalLease(lease))
        default: return nil
        }
    }

    // MARK: - DTO ↔ wire JSON

    /// The DTO encoded exactly like a backup export — sorted keys,
    /// `BackupDateCodec` dates — the byte shape the server stores.
    static func encode(_ dto: SyncBackupDTO) throws -> Data {
        let encoder = BackupCodec.makeEncoder()
        switch dto {
        case .account(let value): return try encoder.encode(value)
        case .category(let value): return try encoder.encode(value)
        case .business(let value): return try encoder.encode(value)
        case .transaction(let value): return try encoder.encode(value)
        case .loanRateChange(let value): return try encoder.encode(value)
        case .budget(let value): return try encoder.encode(value)
        case .recurringRule(let value): return try encoder.encode(value)
        case .rentalUnit(let value): return try encoder.encode(value)
        case .rentalLease(let value): return try encoder.encode(value)
        }
    }

    /// Wire `data` decoded into the concrete DTO for `entity`, using the
    /// backup decoder (the same ISO-8601 date rules).
    static func decode(entity: SyncEntity, from data: Data) throws -> SyncBackupDTO {
        let decoder = BackupCodec.makeDecoder()
        switch entity {
        case .account: return .account(try decoder.decode(BackupAccount.self, from: data))
        case .category: return .category(try decoder.decode(BackupCategory.self, from: data))
        case .business: return .business(try decoder.decode(BackupBusiness.self, from: data))
        case .transaction:
            return .transaction(try decoder.decode(BackupTransaction.self, from: data))
        case .loanRateChange:
            return .loanRateChange(try decoder.decode(BackupLoanRateChange.self, from: data))
        case .budget: return .budget(try decoder.decode(BackupBudget.self, from: data))
        case .recurringRule:
            return .recurringRule(try decoder.decode(BackupRecurringRule.self, from: data))
        case .rentalUnit:
            return .rentalUnit(try decoder.decode(BackupRentalUnit.self, from: data))
        case .rentalLease:
            return .rentalLease(try decoder.decode(BackupRentalLease.self, from: data))
        }
    }

    /// Wire `data` decoded from an already-parsed `SyncJSONValue` — the
    /// shape a pull record carries.
    static func decode(entity: SyncEntity, from value: SyncJSONValue) throws -> SyncBackupDTO {
        try decode(entity: entity, from: JSONEncoder().encode(value))
    }

    /// The DTO as the `SyncJSONValue` a `SyncChange.data` carries — built
    /// field-by-field in the wire's byte shape, no encode → parse round
    /// trip.
    static func jsonValue(of dto: SyncBackupDTO) throws -> SyncJSONValue {
        .object(Dictionary(
            uniqueKeysWithValues: dto.syncFields.map { ($0.0, $0.1.json) }))
    }

    /// The DTO's canonical field list — `SyncContentHasher.hash(fields:)`
    /// input; produces byte-identical canonical bytes to the
    /// encode → parse → canonicalize pipeline it replaced.
    static func canonicalFields(
        of dto: SyncBackupDTO
    ) -> [(String, SyncCanonicalScalar)] {
        dto.syncFields.map { ($0.0, $0.1.canonical) }
    }

    /// Content hash of a DTO — `SyncDiff`'s local input and the hash a
    /// pulled record's decoded DTO takes. One function, both directions.
    static func contentHash(of dto: SyncBackupDTO) -> String {
        SyncContentHasher.hash(fields: canonicalFields(of: dto))
    }

    /// Content hash of the row's DTO — `SyncDiff`'s local input.
    static func contentHash(of row: any PersistentModel) throws -> String? {
        guard let dto = dto(of: row) else { return nil }
        return contentHash(of: dto)
    }

    /// The parent references a pulled DTO carries — every non-nil `…ID`
    /// field as the `(entity, id)` pair it must resolve against the local
    /// store. The engine parks children whose references don't resolve
    /// yet and re-applies them once every parent exists.
    static func references(of dto: SyncBackupDTO) -> [SyncRecordKey] {
        var refs: [SyncRecordKey] = []
        func ref(_ entity: SyncEntity, _ id: UUID?) {
            if let id { refs.append(SyncRecordKey(entity: entity, id: id)) }
        }
        switch dto {
        case .account(let value):
            ref(.business, value.businessID)
        case .rentalUnit(let value):
            ref(.business, value.businessID)
        case .rentalLease(let value):
            ref(.rentalUnit, value.unitID)
        case .loanRateChange(let value):
            ref(.account, value.accountID)
        case .budget(let value):
            ref(.category, value.categoryID)
        case .recurringRule(let value):
            ref(.account, value.accountID)
            ref(.account, value.toAccountID)
            ref(.category, value.categoryID)
            ref(.business, value.businessID)
        case .transaction(let value):
            ref(.account, value.accountID)
            ref(.account, value.toAccountID)
            ref(.category, value.categoryID)
            ref(.business, value.businessID)
            ref(.rentalLease, value.rentalLeaseID)
        case .business, .category:
            break
        }
        return refs
    }

    // MARK: - DTO → model (apply side)

    /// Find-or-create the row for `dto` and copy its fields in, re-linking
    /// every reference through `maps` — `BackupRestorer.upsertRow`, the
    /// same rules a merge restore uses. The caller `save()`s. `force`
    /// bypasses the transaction `updatedAt` guard — the engine uses it to
    /// re-link a row whose parents only arrived after the row itself; the
    /// DTO content is the same pulled version, nothing else is written.
    @discardableResult
    static func apply(
        _ dto: SyncBackupDTO,
        into context: ModelContext,
        maps: inout BackupRowMaps,
        force: Bool = false
    ) -> BackupRowOutcome {
        switch dto {
        case .account(let value):
            return BackupRestorer.upsertRow(value, into: context, maps: &maps)
        case .category(let value):
            return BackupRestorer.upsertRow(value, into: context, maps: &maps)
        case .business(let value):
            return BackupRestorer.upsertRow(value, into: context, maps: &maps)
        case .transaction(let value):
            // Server seq order is the authority: the engine only calls
            // `apply` for rows without an unpushed local change, so an
            // existing transaction is ALWAYS overwritten — never gated by
            // `BackupRestorer`'s merge-restore `updatedAt` rule (a web edit
            // may carry the same or an older stamp).
            if let existing = maps.transactions[value.id] {
                BackupRestorer.apply(
                    value, to: existing, accounts: maps.accounts,
                    categories: maps.categories, businesses: maps.businesses,
                    leases: maps.rentalLeases)
                return .updated
            }
            return BackupRestorer.upsertRow(value, into: context, maps: &maps)
        case .loanRateChange(let value):
            return BackupRestorer.upsertRow(value, into: context, maps: &maps)
        case .budget(let value):
            return BackupRestorer.upsertRow(value, into: context, maps: &maps)
        case .recurringRule(let value):
            return BackupRestorer.upsertRow(value, into: context, maps: &maps)
        case .rentalUnit(let value):
            return BackupRestorer.upsertRow(value, into: context, maps: &maps)
        case .rentalLease(let value):
            return BackupRestorer.upsertRow(value, into: context, maps: &maps)
        }
    }
}
