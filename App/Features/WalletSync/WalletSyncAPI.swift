import Foundation

/// The slice of the wallet.amx.vn API that sync needs. Kept as a protocol
/// so tests and previews can fake it — `WalletAPIClient` conforms.
protocol WalletSyncAPI: Sendable {
    /// GET /api/v1/admin/bank/accounts — the bank accounts on the server.
    func accounts() async throws -> [WalletAPIBankAccount]
    /// One page of bank transactions, ascending by id, after `afterID`.
    func transactions(
        sessionID: Int, afterID: Int, limit: Int
    ) async throws -> WalletAPITransactionPage
}

extension WalletAPIClient: WalletSyncAPI {}

/// Sync-specific failures. API errors travel as `WalletAPIError` already.
enum WalletSyncError: LocalizedError, Equatable {
    /// `syncAll` found no account linked to the wallet.
    case noLinkedAccounts

    var errorDescription: String? {
        switch self {
        case .noLinkedAccounts:
            return "Chưa liên kết tài khoản ngân hàng nào."
        }
    }
}

#if DEBUG
/// Canned responses for `#Preview` screens — never used by the app itself.
final class WalletSyncPreviewAPI: WalletSyncAPI, @unchecked Sendable {
    var accountsResult: [WalletAPIBankAccount] = []
    var items: [Int: [WalletAPIBankTransaction]] = [:]
    var error: (any Error)?

    init() {}

    func accounts() async throws -> [WalletAPIBankAccount] {
        if let error { throw error }
        return accountsResult
    }

    func transactions(
        sessionID: Int, afterID: Int, limit: Int
    ) async throws -> WalletAPITransactionPage {
        if let error { throw error }
        let all = (items[sessionID] ?? [])
            .filter { $0.id > afterID }
            .sorted { $0.id < $1.id }
        let slice = Array(all.prefix(limit))
        return WalletAPITransactionPage(
            items: slice,
            meta: WalletAPIPageMeta(
                nextAfterId: slice.last?.id,
                hasMore: all.count > slice.count,
                serverTime: nil
            )
        )
    }
}
#endif
