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

    /// The DTO as the `SyncJSONValue` a `SyncChange.data` carries —
    /// encoded with the backup encoder, then re-parsed.
    static func jsonValue(of dto: SyncBackupDTO) throws -> SyncJSONValue {
        try SyncJSONValue(jsonData: encode(dto))
    }

    /// Content hash of the row's DTO — `SyncDiff`'s local input.
    static func contentHash(of row: any PersistentModel) throws -> String? {
        guard let dto = dto(of: row) else { return nil }
        return try SyncContentHasher.hash(jsonData: encode(dto))
    }

    // MARK: - DTO → model (apply side)

    /// Find-or-create the row for `dto` and copy its fields in, re-linking
    /// every reference through `maps` — `BackupRestorer.upsertRow`, the
    /// same rules a merge restore uses. The caller `save()`s.
    @discardableResult
    static func apply(
        _ dto: SyncBackupDTO,
        into context: ModelContext,
        maps: inout BackupRowMaps
    ) -> BackupRowOutcome {
        switch dto {
        case .account(let value):
            return BackupRestorer.upsertRow(value, into: context, maps: &maps)
        case .category(let value):
            return BackupRestorer.upsertRow(value, into: context, maps: &maps)
        case .business(let value):
            return BackupRestorer.upsertRow(value, into: context, maps: &maps)
        case .transaction(let value):
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
