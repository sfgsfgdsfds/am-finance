import Foundation
import FinanceCore

/// Where a ledger row came from, at the granularity an agent proposal
/// cares about. Driven by `externalSource`, the import marker —
/// `nil`/empty means the user typed the row in.
enum AIAgentSource: String, CaseIterable, Sendable {
    /// Entered by hand in the app — no import marker.
    case manual
    /// Synced from the linked wallet (`WalletSyncEngine.externalSource`).
    case wallet
    /// Imported from a CSV bank statement
    /// (`CSVImportDeduper.externalSource`).
    case csv
    /// Any other non-empty marker (e.g. rows written by a restore).
    case otherImported
}

/// The typed query the local lookup tool runs. Every axis is optional —
/// nil/empty means "not filtering on it". `interval` may only *narrow*
/// the granted permission window, never widen it; anything escaping the
/// grant is refused.
struct AIAgentLookupQuery: Equatable, Sendable {
    /// A narrower slice inside the granted window — must be contained
    /// by it. Nil scans the whole grant.
    var interval: DateInterval?
    var kind: TransactionKind?
    var source: AIAgentSource?
    /// Reuses the transactions list's "Chưa phân loại" semantics:
    /// non-transfer rows with no category OR still flagged
    /// `needsReview` (the import review queue).
    var unclassifiedOnly = false
    /// Free text — folded exactly like `TransactionListSearch`
    /// (case/diacritic-insensitive, "đ"→"d", whitespace collapsed) and
    /// matched over note, category, account and business names. A
    /// digits-only query substring-matches the amount instead, the
    /// same UX the list search has.
    var text = ""
    /// Amount magnitude bounds in đồng — `amount` is always positive,
    /// so the bounds are sign-free.
    var minAmount: Int64?
    var maxAmount: Int64?

    init(
        interval: DateInterval? = nil,
        kind: TransactionKind? = nil,
        source: AIAgentSource? = nil,
        unclassifiedOnly: Bool = false,
        text: String = "",
        minAmount: Int64? = nil,
        maxAmount: Int64? = nil
    ) {
        self.interval = interval
        self.kind = kind
        self.source = source
        self.unclassifiedOnly = unclassifiedOnly
        self.text = text
        self.minAmount = minAmount
        self.maxAmount = maxAmount
    }
}

/// Displayable preview of one matched row — plain value data for the
/// in-app review UI: no model object, no raw account/category/external
/// identifiers, nothing serialized or sent anywhere in this PR.
struct AIAgentTransactionPreview: Equatable, Sendable {
    var kind: TransactionKind
    /// Positive đồng magnitude — apply `kind` for the sign, as always.
    var amount: Int64
    var date: Date
    var note: String
    var source: AIAgentSource
    var needsReview: Bool
    /// `TransactionListScope.unclassified` semantics, computed even when
    /// the query did not filter on it.
    var unclassified: Bool
    var accountName: String?
    var accountKind: AccountKind?
    var toAccountName: String?
    var categoryName: String?
    var businessName: String?
}

/// One lookup hit: the local `preview` plus `original`, the opaque
/// full-state token `applyCategoryEdits` requires as proof the user
/// confirmed this exact row state. `original` is the same fingerprint
/// shape `BillSplitOriginal` uses for its confirm sheets — it holds the
/// row's real identity and is strictly local: never serialized, never
/// sent. Only `lookup` mints matches, so apply cannot be pointed at a
/// row the tools never surfaced.
struct AIAgentLookupMatch: Equatable, Sendable {
    var preview: AIAgentTransactionPreview
    var original: BillSplitOriginal
}

/// What one `lookup` returned — newest-first matches inside the window
/// actually scanned, plus the honesty flags a bounded scan owes its
/// caller.
struct AIAgentLookupResult: Equatable, Sendable {
    /// The window actually scanned — the granted window, or the query's
    /// narrower interval inside it.
    var window: DateInterval
    /// Newest-first matches, at most `AIAgentLedgerTools.resultLimit`.
    var matches: [AIAgentLookupMatch]
    /// Rows inside `window` the scan loaded — at most
    /// `AIAgentLedgerTools.scanLimit`, newest first.
    var scanned: Int
    /// True when the scan bound or the result cap may have hidden
    /// further matches — narrow the query instead of assuming this
    /// list is exhaustive.
    var truncated: Bool
}
