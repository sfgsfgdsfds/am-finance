import Foundation

/// Form state behind `ReceivableClientEditView`: name, optional business
/// and note — plain values so validation and the model mapping are
/// unit-testable without SwiftUI.
struct ReceivableClientDraft {
    var name = ""
    /// The business this client belongs to; nil is a personal client.
    var business: Business?
    var note = ""

    init(business: Business? = nil) {
        self.business = business
    }

    /// The trimmed name as it will be stored.
    var trimmedName: String {
        name.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// First problem found, or nil when the draft can be saved.
    func validate() -> ReceivableClientDraftError? {
        trimmedName.isEmpty ? .missingName : nil
    }

    /// Builds the receivable account for this client.
    func makeAccount(sortOrder: Int) -> Account {
        let account = Account(
            name: trimmedName,
            kind: .receivable,
            note: note,
            sortOrder: sortOrder
        )
        account.business = business
        return account
    }
}

/// Why a client draft cannot be saved; each case carries a Vietnamese message.
enum ReceivableClientDraftError: Error, Equatable {
    case missingName
}

extension ReceivableClientDraftError: LocalizedError {
    var errorDescription: String? {
        switch self {
        case .missingName: return "Vui lòng nhập tên khách hàng."
        }
    }
}
