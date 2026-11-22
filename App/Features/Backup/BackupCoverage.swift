import Foundation
import SwiftData

/// Every SwiftData model the JSON backup reads and writes — the DTO set in
/// `BackupDocument`, the fetches in `BackupCodec.encode` and the restore
/// passes in `BackupRestorer` all cover exactly these types.
///
/// A test in `BackupTests` compares this list with `AppSchema.allModels` so
/// a newly added model can never be silently left out of the backup.
enum BackupCoverage {
    static let coveredModels: [any PersistentModel.Type] = [
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
