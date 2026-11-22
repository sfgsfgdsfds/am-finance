import Foundation
import SwiftData
import FinanceCore

/// A recurring transaction template — "mỗi tháng trả tiền thuê", "hằng tuần
/// nạp ví" and so on. The schedule part (frequency, interval, startDate,
/// endDate, maximumOccurrences) mirrors `RecurrenceRule` in FinanceCore;
/// `lastGeneratedDate` marks how far `RecurringGenerator` has produced
/// real transactions. `autoCreate == false` means the rule only reminds —
/// no transaction is inserted when an occurrence comes due.
@Model
final class RecurringRule {
    var id: UUID = UUID()
    var title: String = ""
    var kindRaw: String = TransactionKind.expense.rawValue
    var amount: Int64 = 0
    var note: String = ""

    var account: Account?
    /// Destination account — transfers only.
    var toAccount: Account?
    var category: LedgerCategory?
    var business: Business?

    var frequencyRaw: String = RecurrenceFrequency.monthly.rawValue
    /// Every N units of `frequency`; must be ≥ 1.
    var interval: Int = 1
    var startDate: Date = Date.now
    /// Last calendar day an occurrence may fall on, inclusive.
    var endDate: Date?
    /// Total occurrences ever produced; nil for unbounded.
    var maximumOccurrences: Int?
    /// Day the generator has produced transactions through; nil = never ran.
    var lastGeneratedDate: Date?

    /// true: the app inserts the transaction when due; false: only reminds.
    var autoCreate: Bool = true
    var isActive: Bool = true
    var createdAt: Date = Date.now

    init(
        id: UUID = UUID(),
        title: String,
        kind: TransactionKind,
        amount: Int64,
        note: String = "",
        account: Account? = nil,
        toAccount: Account? = nil,
        category: LedgerCategory? = nil,
        business: Business? = nil,
        frequency: RecurrenceFrequency,
        interval: Int = 1,
        startDate: Date,
        endDate: Date? = nil,
        maximumOccurrences: Int? = nil,
        lastGeneratedDate: Date? = nil,
        autoCreate: Bool = true,
        isActive: Bool = true
    ) {
        self.id = id
        self.title = title
        self.kindRaw = kind.rawValue
        self.amount = amount
        self.note = note
        self.account = account
        self.toAccount = toAccount
        self.category = category
        self.business = business
        self.frequencyRaw = frequency.rawValue
        self.interval = interval
        self.startDate = startDate
        self.endDate = endDate
        self.maximumOccurrences = maximumOccurrences
        self.lastGeneratedDate = lastGeneratedDate
        self.autoCreate = autoCreate
        self.isActive = isActive
    }

    var kind: TransactionKind {
        get { TransactionKind(rawValue: kindRaw) ?? .expense }
        set { kindRaw = newValue.rawValue }
    }

    var frequency: RecurrenceFrequency {
        get { RecurrenceFrequency(rawValue: frequencyRaw) ?? .monthly }
        set { frequencyRaw = newValue.rawValue }
    }

    /// The FinanceCore schedule this rule describes — nil when the stored
    /// fields are inconsistent (interval < 1, end before start, or an
    /// invalid maximum), so callers can skip a rule instead of crashing.
    func recurrenceRule(calendar: Calendar) -> RecurrenceRule? {
        try? RecurrenceRule(
            frequency: frequency,
            interval: interval,
            startDate: startDate,
            endDate: endDate,
            maximumOccurrences: maximumOccurrences,
            calendar: calendar
        )
    }
}
