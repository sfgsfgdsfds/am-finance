import Foundation
import FinanceCore

/// The parsed `add`/`edit` field set a chat `actions` reply may carry.
/// Day and wall-clock stay apart so the session can merge them with
/// "now" for an add, or with the live row's date for an edit.
struct AIAgentProposedFields: Equatable, Sendable {
    var amount: Int64?
    /// A `yyyy-MM-dd` day in the Vietnam calendar.
    var day: Date?
    /// A `HH:mm` wall-clock in the Vietnam calendar.
    var time: AIAgentDayTime?
    var note: String?
    /// An `A…` account handle from the catalog.
    var account: String?
    /// An `A…` handle — `add` transfers only.
    var toAccount: String?
    /// A `C…` category handle from the catalog.
    var category: String?
}

/// Wall-clock time inside a Vietnam-local day — the "HH:mm" the
/// contract carries.
struct AIAgentDayTime: Equatable, Sendable {
    var hour: Int
    var minute: Int
}

/// One raw item inside an `actions` reply — the handles still
/// unresolved (`R…` rows the session minted, `A…`/`C…` catalog
/// handles). The session resolves these into `AIAgentLedgerAction`s.
enum AIAgentProposedAction: Equatable, Sendable {
    /// `{"action":"setCategory","row":"R3","category":"C5"}`
    case setCategory(row: String, category: String)
    /// `{"action":"add","kind":"expense","amount":50000,…}` — `kind`
    /// and `amount` are the only fields the contract requires.
    case add(kind: TransactionKind, fields: AIAgentProposedFields)
    /// `{"action":"edit","row":"R3", …only fields to change…}`
    case edit(row: String, fields: AIAgentProposedFields)
    /// `{"action":"delete","row":"R3"}`
    case delete(row: String)
}

/// The account/category catalog the system prompt advertises when the
/// access level allows proposals — `A…`/`C…` handles the model may
/// reference, minted once per session by `AIAgentChatSession`.
struct AIAgentActionCatalog: Equatable, Sendable {
    /// One advertised account.
    struct Account: Equatable, Sendable {
        /// "A1", "A2", …
        var handle: String
        var name: String
        var kind: AccountKind
        /// The fallback an `add` without "account" resolves to — the
        /// last-used account the capture flow records, else the first
        /// listed.
        var isDefault: Bool
    }

    /// One advertised category.
    struct Category: Equatable, Sendable {
        /// "C1", "C2", …
        var handle: String
        var name: String
        var kind: CategoryKind
    }

    var accounts: [Account]
    var categories: [Category]
}

/// The action kind one proposal item previews.
enum AIAgentProposalItemKind: String, Equatable, Sendable {
    case setCategory
    case add
    case edit
    case delete

    /// Short Vietnamese label for the confirm UI.
    var title: String {
        switch self {
        case .setCategory: return "Phân loại"
        case .add: return "Thêm"
        case .edit: return "Sửa"
        case .delete: return "Xoá"
        }
    }
}

/// One entry of a pending proposal — a single action rendered as
/// display-ready field lines. `changes` holds `old → new` transitions
/// for `edit`/`setCategory`, new values only for `add`, the row's
/// current values only for `delete`. Plain strings only — no SwiftData
/// objects — ready for a SwiftUI list.
struct AIAgentProposalItem: Equatable, Sendable, Identifiable {
    /// One display line: a field's current value, its proposed value,
    /// or both when they differ.
    struct FieldChange: Equatable, Sendable, Identifiable {
        /// Vietnamese field label — "Loại", "Số tiền", "Ngày",
        /// "Ghi chú", "Tài khoản", "Tài khoản đích", "Danh mục".
        var field: String
        /// The current value — nil on `add` lines.
        var old: String?
        /// The proposed value — nil on `delete` lines.
        var new: String?
        var id: String { field }
    }

    var id: UUID = UUID()
    var kind: AIAgentProposalItemKind
    /// The `R…` handle the action targets — nil for `add`.
    var row: String?
    var changes: [FieldChange]

    init(
        id: UUID = UUID(),
        kind: AIAgentProposalItemKind,
        row: String? = nil,
        changes: [FieldChange]
    ) {
        self.id = id
        self.kind = kind
        self.row = row
        self.changes = changes
    }
}

/// The validated batch parked on the session between the model's
/// `actions` reply and the user's decision: the model's own short
/// Vietnamese explanation plus one display item per action. Nothing is
/// written until `confirmProposal()` — the only path that writes —
/// and `discardProposal()` drops it untouched.
struct AIAgentActionProposal: Equatable, Sendable {
    /// The model's short Vietnamese explanation for the batch.
    var text: String
    /// One display item per proposed action, in batch order.
    var items: [AIAgentProposalItem]
}
