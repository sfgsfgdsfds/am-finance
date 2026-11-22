import Foundation

/// Shared JSON decoder for the AMX servers: snake_case keys and ISO-8601
/// dates with a numeric offset ("+07:00"), fractional seconds optional.
enum WalletLinkJSON {
    static func makeDecoder() -> JSONDecoder {
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        decoder.dateDecodingStrategy = .custom { decoder in
            let container = try decoder.singleValueContainer()
            let string = try container.decode(String.self)
            guard let date = WalletAPIDate.parse(string) else {
                throw DecodingError.dataCorruptedError(
                    in: container,
                    debugDescription: "Invalid ISO-8601 date: \(string)")
            }
            return date
        }
        return decoder
    }
}

/// ISO-8601 parsing for the wallet API's timestamp shape — `Date`'s
/// `ISO8601FormatStyle` is a value type, so parsing stays Sendable-safe.
enum WalletAPIDate {
    static func parse(_ string: String) -> Date? {
        if let date = try? Date.ISO8601FormatStyle().parse(string) {
            return date
        }
        return try? Date.ISO8601FormatStyle(includingFractionalSeconds: true)
            .parse(string)
    }
}

/// Vends Bearer tokens for API calls — `WalletLinkSession` in the app, a
/// stub in tests.
protocol WalletLinkAccessTokenProviding: Sendable {
    /// A currently-valid token (refreshed internally when near expiry).
    func accessToken() async throws -> String
    /// A freshly-rotated token — for the single retry after a 401.
    func forceRefreshedAccessToken() async throws -> String
}

extension WalletLinkSession: WalletLinkAccessTokenProviding {
    func accessToken() async throws -> String {
        try await validAccessToken()
    }
}

/// Failures of the wallet API. `errorDescription` is Vietnamese — the
/// settings screen shows it verbatim.
enum WalletAPIError: LocalizedError, Equatable {
    /// 401 that a refresh did not fix, or no usable session.
    case notSignedIn
    /// 403 — this AMX account may not use the wallet.
    case notAllowed
    /// 429 — too many requests.
    case rateLimited
    /// Any other non-2xx status (incl. 422), with the server's detail if any.
    case server(status: Int, detail: String?)
    /// Transport-level failure.
    case network(String)
    /// A 2xx body that did not decode into the expected shape.
    case decoding

    var errorDescription: String? {
        switch self {
        case .notSignedIn:
            return "Chưa đăng nhập AMX hoặc phiên đã hết hạn — hãy đăng nhập lại."
        case .notAllowed:
            return "Tài khoản AMX này không được phép truy cập ví."
        case .rateLimited:
            return "Máy chủ ví đang giới hạn lượt truy cập — thử lại sau ít phút."
        case .server(let status, let detail):
            if let detail, !detail.isEmpty {
                return "Máy chủ ví báo lỗi (\(status)): \(detail)"
            }
            return "Máy chủ ví báo lỗi (\(status))."
        case .network(let detail):
            return "Không kết nối được máy chủ ví. \(detail)"
        case .decoding:
            return "Dữ liệu máy chủ ví trả về không đúng định dạng."
        }
    }
}

/// GET /api/v1/admin/bank/accounts row. `id` is the session UUID string —
/// it becomes `Account.externalAccountID` when linked. `holderName` and
/// `accountNumberMasked` are null when the session has no name or the
/// account number has no digits to mask.
struct WalletAPIBankAccount: Decodable, Equatable, Sendable {
    var id: String
    var bank: String
    var accountNumberMasked: String?
    var holderName: String?
    var status: String
    var lastListenerActivityAt: Date?
    var lastTransactionAt: Date?
    var transactionsCount: Int
}

/// GET /api/v1/admin/bank/transactions row. `id` is a UUID string — it
/// becomes `LedgerTransaction.externalID` on import. `amount` is a signed
/// VND integer — negative means money out (the server's own convention).
/// `bankTransactionId` is the listener's md5 dedupe key, not a real bank
/// reference. Property names are camelCase so `convertFromSnakeCase` maps
/// every key.
struct WalletAPIBankTransaction: Decodable, Equatable, Sendable {
    var id: String
    var sessionId: String
    var bankTransactionId: String?
    var amount: Int64
    var currency: String
    var transactionDate: Date
    var note: String?
    var counterpartyAccountMasked: String?
    var createdAt: Date?
}

/// Paging cursor returned beside a transaction page. `nextAfterId` is an
/// opaque string — the `id` of the last row, or the `after_id` that was
/// sent when the page is empty ("0" for a first read).
struct WalletAPIPageMeta: Decodable, Equatable, Sendable {
    var nextAfterId: String
    var hasMore: Bool
    var serverTime: Date?
}

/// One page of bank transactions plus its cursor.
struct WalletAPITransactionPage: Equatable, Sendable {
    var items: [WalletAPIBankTransaction]
    var meta: WalletAPIPageMeta
}

/// Typed client for the read-only wallet API on wallet.amx.vn. Adds the
/// Bearer header, refreshes once and retries once on 401, and decodes the
/// `{ "data": …, "meta": … }` envelopes.
struct WalletAPIClient: Sendable {
    var baseURL: URL
    var tokenProvider: any WalletLinkAccessTokenProviding
    var urlSession: URLSession

    init(
        baseURL: URL,
        tokenProvider: any WalletLinkAccessTokenProviding,
        urlSession: URLSession = .shared
    ) {
        self.baseURL = baseURL
        self.tokenProvider = tokenProvider
        self.urlSession = urlSession
    }

    /// GET /api/v1/admin/bank/accounts
    func accounts() async throws -> [WalletAPIBankAccount] {
        let data = try await get(path: "api/v1/admin/bank/accounts")
        return try decode(Envelope<[WalletAPIBankAccount]>.self, from: data).data
    }

    /// GET /api/v1/admin/bank/transactions — one page, ascending by id
    /// string. `afterID` is the opaque cursor — "0" reads from the start.
    /// `limit` is clamped to the server's 500 maximum.
    func transactions(
        sessionID: String, afterID: String = "0", limit: Int = 500
    ) async throws -> WalletAPITransactionPage {
        let data = try await get(path: "api/v1/admin/bank/transactions", query: [
            URLQueryItem(name: "session_id", value: sessionID),
            URLQueryItem(name: "after_id", value: afterID),
            URLQueryItem(name: "limit", value: String(min(max(limit, 1), 500))),
        ])
        let page = try decode(PagedEnvelope<[WalletAPIBankTransaction]>.self, from: data)
        return WalletAPITransactionPage(items: page.data, meta: page.meta)
    }

    /// Every transaction after `afterID`, following `next_after_id` until
    /// `has_more` is false. A non-advancing cursor would page forever, so the
    /// loop also stops when the next cursor does not move forward.
    func allTransactions(
        sessionID: String, afterID: String = "0"
    ) async throws -> [WalletAPIBankTransaction] {
        var collected: [WalletAPIBankTransaction] = []
        var cursor = afterID
        while true {
            let page = try await transactions(
                sessionID: sessionID, afterID: cursor, limit: 500)
            collected.append(contentsOf: page.items)
            guard page.meta.hasMore else { return collected }
            let next = page.meta.nextAfterId
            guard next > cursor else { return collected }
            cursor = next
        }
    }

    // MARK: - Internals

    private struct Envelope<T: Decodable>: Decodable {
        var data: T
    }

    private struct PagedEnvelope<T: Decodable>: Decodable {
        var data: T
        var meta: WalletAPIPageMeta
    }

    /// Error bodies the server may attach — OAuth shape, FastAPI-style
    /// `detail`, or a plain `message`.
    private struct ErrorBody: Decodable {
        var error: String?
        var errorDescription: String?
        var detail: String?
        var message: String?
    }

    /// Performs the GET with the Bearer header; on a 401 refreshes the token
    /// once and retries exactly once, then maps the status to a typed error.
    private func get(path: String, query: [URLQueryItem] = []) async throws -> Data {
        var token = try await accessToken()
        for attempt in 0...1 {
            var components = URLComponents(
                url: baseURL.appendingPathComponent(path),
                resolvingAgainstBaseURL: false)
            if !query.isEmpty { components?.queryItems = query }
            guard let url = components?.url else { throw WalletAPIError.decoding }

            var request = URLRequest(url: url)
            request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
            let (data, http) = try await send(request)

            if http.statusCode == 401, attempt == 0 {
                token = try await forceRefreshedToken()
                continue
            }
            try throwIfFailed(http, data: data)
            return data
        }
        preconditionFailure("unreachable")
    }

    private func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        do {
            let (data, response) = try await urlSession.data(for: request)
            guard let http = response as? HTTPURLResponse else {
                throw WalletAPIError.network("Phản hồi không hợp lệ.")
            }
            return (data, http)
        } catch let error as WalletAPIError {
            throw error
        } catch {
            throw WalletAPIError.network(error.localizedDescription)
        }
    }

    private func throwIfFailed(_ http: HTTPURLResponse, data: Data) throws {
        switch http.statusCode {
        case 200..<300:
            return
        case 401:
            throw WalletAPIError.notSignedIn
        case 403:
            throw WalletAPIError.notAllowed
        case 429:
            throw WalletAPIError.rateLimited
        default:
            throw WalletAPIError.server(
                status: http.statusCode, detail: errorDetail(from: data))
        }
    }

    private func errorDetail(from data: Data) -> String? {
        let body = try? WalletLinkJSON.makeDecoder().decode(ErrorBody.self, from: data)
        return body?.errorDescription ?? body?.detail ?? body?.message ?? body?.error
    }

    private func accessToken() async throws -> String {
        do {
            return try await tokenProvider.accessToken()
        } catch {
            throw mapTokenError(error)
        }
    }

    private func forceRefreshedToken() async throws -> String {
        do {
            return try await tokenProvider.forceRefreshedAccessToken()
        } catch {
            throw mapTokenError(error)
        }
    }

    private func mapTokenError(_ error: Error) -> WalletAPIError {
        if let linkError = error as? WalletLinkError {
            switch linkError {
            case .notSignedIn, .refreshDenied:
                return .notSignedIn
            default:
                return .network(linkError.localizedDescription)
            }
        }
        return (error as? WalletAPIError) ?? .network(error.localizedDescription)
    }

    private func decode<T: Decodable>(_ type: T.Type, from data: Data) throws -> T {
        guard let decoded = try? WalletLinkJSON.makeDecoder().decode(T.self, from: data) else {
            throw WalletAPIError.decoding
        }
        return decoded
    }
}
