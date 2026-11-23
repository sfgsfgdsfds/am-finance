import Foundation

/// What the on-device AI agent may do with the local ledger.
///
/// The default is `off`: nothing is readable or writable until the user
/// grants a level. Every tool entry point re-checks the level on every
/// call, so a revoked or weakened grant fails loudly instead of leaking
/// or mutating rows. There is no automatic write path at any level —
/// the highest level only lets the agent *propose* edits, which still
/// land solely through the user-confirmed `apply` batch.
enum AIAgentAccess: String, CaseIterable, Sendable {
    /// No ledger access at all — lookup and apply both refuse.
    case off
    /// Bounded, read-only lookup inside the granted date window.
    case scopedRead
    /// `scopedRead` plus proposing ledger actions: the confirmed apply
    /// may re-categorize, add, edit and delete rows the lookup
    /// surfaced (adds need no match). Still no model-initiated writes —
    /// the batch the user confirms is the batch that lands, or nothing
    /// does.
    case scopedReadAndProposeCategoryEdits

    /// Whether `lookup` may run at all.
    var canLookup: Bool { self != .off }

    /// Whether `applyCategoryEdits` may run.
    var canProposeCategoryEdits: Bool {
        self == .scopedReadAndProposeCategoryEdits
    }

    /// Whether `apply(_:permission:in:lookupWindow:)` may run — the
    /// mixed action batch. Same grant as `canProposeCategoryEdits`:
    /// the single write level covers every confirmed action kind.
    var canProposeActions: Bool {
        self == .scopedReadAndProposeCategoryEdits
    }
}

/// The grant a caller holds for one agent interaction — the access
/// level plus the local date window the user allowed the tools to
/// touch. `window` is enforced by both tools: lookup only scans inside
/// it (a query may narrow, never widen), and apply refuses a target row
/// whose date sits outside it even when the row's snapshot still
/// matches. Intervals are half-open — `start <= date < end` — so a
/// "this month" grant ends on the first of the next month.
struct AIAgentPermission: Equatable, Sendable {
    var access: AIAgentAccess
    /// The user-allowed window. Must not exceed
    /// `AIAgentLedgerTools.maxWindow` (366 days); wider grants are
    /// refused, not silently clipped. Ignored while `access == .off`.
    var window: DateInterval

    init(access: AIAgentAccess = .off, window: DateInterval) {
        self.access = access
        self.window = window
    }

    /// The default grant — nothing allowed and an empty window.
    static let off = AIAgentPermission(
        access: .off, window: DateInterval(start: .distantPast, duration: 0))
}
