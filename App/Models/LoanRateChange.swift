import Foundation
import SwiftData

/// A bank rate adjustment inside a loan's term: installment 1 always uses
/// `Account.loanAnnualRatePercent`; each `LoanRateChange` replaces it from
/// `fromInstallment` on — e.g. a promotional rate ending and the floating
/// rate starting. Owned by one `Account` through `Account.loanRateChanges`.
@Model
final class LoanRateChange {
    var id: UUID = UUID()
    /// First installment (1-based) the new rate applies to.
    var fromInstallment: Int = 0
    /// Nominal annual rate in percent — `12.0` means 12%/year.
    var annualRatePercent: Double = 0

    var account: Account?

    init(
        id: UUID = UUID(),
        fromInstallment: Int,
        annualRatePercent: Double,
        account: Account? = nil
    ) {
        self.id = id
        self.fromInstallment = fromInstallment
        self.annualRatePercent = annualRatePercent
        self.account = account
    }
}
