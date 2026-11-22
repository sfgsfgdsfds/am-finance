import Foundation
import SwiftData

/// Store-level row actions for the transactions list.
enum TransactionListDuplicate {

    /// "Nhân bản": inserts a copy of `transaction` dated `now`. The copy is
    /// a fresh row — new id, and no external bank link fields (it is not the
    /// same imported movement, just the same details).
    @discardableResult
    static func insert(
        of transaction: LedgerTransaction,
        into context: ModelContext,
        now: Date = .now
    ) -> LedgerTransaction {
        let copy = LedgerTransaction(
            kind: transaction.kind,
            amount: transaction.amount,
            date: now,
            note: transaction.note,
            account: transaction.account,
            toAccount: transaction.toAccount,
            category: transaction.category,
            business: transaction.business,
            needsReview: transaction.needsReview
        )
        context.insert(copy)
        return copy
    }
}
