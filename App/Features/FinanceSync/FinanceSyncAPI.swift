import FinanceCore
import Foundation

/// Failures of the finance sync API. `errorDescription` is Vietnamese —
/// a settings screen will show it verbatim once the feature ships.
enum FinanceSyncError: LocalizedError, Equatable {
    /// 401 that a token refresh did not fix, or no usable session.
    case unauthorized
    /// 409 — a pushed row has a server seq newer than `base_seq`; the
    /// engine must pull, merge and retry.
    case conflict([SyncConflict])
    /// 422 `{"error":"validation",…}` — a DTO/constraint failure.
    case validation(SyncValidationDetail)
    /// 422 `{"error":"idempotency_key_reused"}` — the key already
    /// committed with a different request body.
    case idempotencyKeyReused
    /// 413 — the push body exceeded the server's 10 MiB cap.
    case tooLarge
    /// Any other non-2xx status, with the response body for context.
    case http(status: Int, body: String)
    /// Transport-level failure (no connection, timeout…).
    case transport(String)
    /// A 2xx body that did not decode into the expected shape.
    case decoding

    var errorDescription: String? {
        switch self {
        case .unauthorized:
            return "Chưa đăng nhập AMX hoặc phiên đã hết hạn — hãy đăng nhập lại."
        case .conflict:
            return "Dữ liệu trên máy chủ đã thay đổi — cần đồng bộ lại trước khi đẩy."
        case .validation(let detail):
            return "Máy chủ từ chối bản ghi (\(detail.field)): \(detail.message)"
        case .idempotencyKeyReused:
            return "Khoá idempotency đã được dùng với một nội dung khác."
        case .tooLarge:
            return "Gói đồng bộ quá lớn — hãy thử lại với ít thay đổi hơn."
        case .http(let status, let body):
            if !body.isEmpty {
                return "Máy chủ đồng bộ báo lỗi (\(status)): \(body)"
            }
            return "Máy chủ đồng bộ báo lỗi (\(status))."
        case .transport(let detail):
            return "Không kết nối được máy chủ đồng bộ. \(detail)"
        case .decoding:
            return "Dữ liệu máy chủ đồng bộ trả về không đúng định dạng."
        }
    }
}

/// `GET /v1/backup/export` decoded: the live ledger plus the change
/// stream position it was read at.
struct FinanceSyncSnapshot: Sendable {
    var document: BackupDocument
    var syncSeq: Int64
}

/// Just the top-level `syncSeq` of an export body (the iPhone's
/// `BackupDocument` decoder ignores the key).
private struct FinanceSyncSeqEnvelope: Decodable {
    var syncSeq: Int64?
}

/// `GET /v1/sync/head` body.
private struct SyncHeadResponse: Decodable {
    var highWaterSeq: Int64

    private enum CodingKeys: String, CodingKey {
        case highWaterSeq = "high_water_seq"
    }
}

/// Typed client for the finance sync API on `<baseURL>/v1`. Mirrors
/// `WalletAPIClient`: Bearer header from the shared WalletLink session,
/// one refresh-and-retry on 401, errors mapped to `FinanceSyncError`.
/// `data` payloads stay raw JSON (`SyncJSONValue`) — the DTO types live
/// in the backup feature.
struct FinanceSyncAPIClient: Sendable {
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

    /// POST /v1/sync/push — applies `changes` on top of server state at
    /// `baseSeq`. `idempotencyKey` must match `[A-Za-z0-9._:-]{1,128}`
    /// (the server rejects anything else); retrying a dropped request
    /// resends the SAME key and body, and the stored 200 replays.
    func push(
        baseSeq: Int64,
        changes: [SyncChange],
        idempotencyKey: String
    ) async throws -> SyncPushResponse {
        let body = try JSONEncoder().encode(
            SyncPushRequest(baseSeq: baseSeq, changes: changes))
        return try await pushEncoded(body: body, idempotencyKey: idempotencyKey)
    }

    /// POST /v1/sync/push with an already-encoded request body. The
    /// engine persists these exact bytes before sending so a retry after
    /// a dropped response replays byte-identically under the same
    /// idempotency key — which is the only form the server de-dupes.
    func pushEncoded(
        body: Data,
        idempotencyKey: String
    ) async throws -> SyncPushResponse {
        let data = try await perform(
            method: "POST", path: "v1/sync/push",
            body: body, idempotencyKey: idempotencyKey)
        return try decode(SyncPushResponse.self, from: data)
    }

    /// The server's high-water seq without pulling anything — an empty
    /// push can never conflict (no rows are touched), so `baseSeq` is
    /// only a formality.
    func highWater(baseSeq: Int64 = 0) async throws -> Int64 {
        try await push(
            baseSeq: baseSeq, changes: [],
            idempotencyKey: UUID().uuidString
        ).highWaterSeq
    }

    /// GET /v1/sync/pull?cursor=&limit= — one page of the committed
    /// change stream after `cursor` (`0` reads from the start). `limit`
    /// is clamped to the server's 1…1000 range (default 500).
    func pull(cursor: Int64 = 0, limit: Int = 500) async throws -> SyncPullResponse {
        let data = try await perform(method: "GET", path: "v1/sync/pull", query: [
            URLQueryItem(name: "cursor", value: String(max(cursor, 0))),
            URLQueryItem(name: "limit", value: String(min(max(limit, 1), 1_000))),
        ])
        return try decode(SyncPullResponse.self, from: data)
    }

    /// POST /v1/backup/import — REPLACES all server data with `body`, a
    /// backup-v5 document encoded by `BackupCodec`. No idempotency key:
    /// a replace is naturally idempotent. ≤ 100 MiB.
    func importBackup(_ body: Data) async throws -> SyncImportSummary {
        let data = try await perform(
            method: "POST", path: "v1/backup/import", body: body)
        return try decode(SyncImportSummary.self, from: data)
    }

    /// GET /v1/sync/head — the server's high-water seq (`0` for an
    /// account that was never written).
    func head() async throws -> Int64 {
        let data = try await perform(method: "GET", path: "v1/sync/head")
        return try decode(SyncHeadResponse.self, from: data).highWaterSeq
    }

    /// GET /v1/sync/wait?cursor=&timeout= — long-poll. Returns the
    /// server's high-water seq when it has moved past `cursor` (HTTP
    /// 200); `nil` when the server held the request for `timeout` seconds
    /// and nothing new arrived (HTTP 204). The request timeout is longer
    /// than the server hold so a quiet 204 is not a client-side timeout.
    /// 400 and 401 surface as `FinanceSyncError` like every other call.
    func wait(cursor: Int64, timeout: TimeInterval = 25) async throws -> Int64? {
        let seconds = max(0, timeout)
        let (data, http) = try await performRaw(
            method: "GET", path: "v1/sync/wait",
            query: [
                URLQueryItem(name: "cursor", value: String(max(cursor, 0))),
                URLQueryItem(name: "timeout", value: Self.timeoutQuery(seconds)),
            ],
            timeoutInterval: seconds + 10)
        if http.statusCode == 204 { return nil }
        return try decode(SyncHeadResponse.self, from: data).highWaterSeq
    }

    /// `25` for whole seconds, a short decimal for tests that hold the
    /// fake server for a fraction of a second.
    private static func timeoutQuery(_ seconds: TimeInterval) -> String {
        if seconds < 10_000, seconds == seconds.rounded() {
            return String(Int(seconds))
        }
        return String(seconds)
    }

    /// GET /v1/backup/export — every live row of the user as one
    /// backup-v5 document read in a single snapshot, plus the change
    /// stream position of that snapshot: pulling from `cursor == syncSeq`
    /// afterwards misses nothing and repeats nothing. The body's
    /// top-level `syncSeq` wins; the `X-Sync-Seq` header is the fallback.
    func exportSnapshot() async throws -> FinanceSyncSnapshot {
        let (data, http) = try await performRaw(
            method: "GET", path: "v1/backup/export")
        let document: BackupDocument
        do {
            document = try BackupCodec.decode(data)
        } catch {
            throw FinanceSyncError.decoding
        }
        let bodySeq = (try? JSONDecoder().decode(
            FinanceSyncSeqEnvelope.self, from: data))?.syncSeq
        let headerSeq = http.value(forHTTPHeaderField: "X-Sync-Seq")
            .flatMap { Int64($0.trimmingCharacters(in: .whitespaces)) }
        guard let seq = bodySeq ?? headerSeq, seq >= 0 else {
            throw FinanceSyncError.decoding
        }
        return FinanceSyncSnapshot(document: document, syncSeq: seq)
    }

    // MARK: - Internals

    private func perform(
        method: String,
        path: String,
        query: [URLQueryItem] = [],
        body: Data? = nil,
        idempotencyKey: String? = nil,
        timeoutInterval: TimeInterval? = nil
    ) async throws -> Data {
        try await performRaw(
            method: method, path: path, query: query,
            body: body, idempotencyKey: idempotencyKey,
            timeoutInterval: timeoutInterval).0
    }

    /// Performs the request with the Bearer header; on a 401 refreshes
    /// the token once and retries exactly once, then maps the status to
    /// a typed error.
    private func performRaw(
        method: String,
        path: String,
        query: [URLQueryItem] = [],
        body: Data? = nil,
        idempotencyKey: String? = nil,
        timeoutInterval: TimeInterval? = nil
    ) async throws -> (Data, HTTPURLResponse) {
        var token = try await accessToken()
        for attempt in 0...1 {
            var components = URLComponents(
                url: baseURL.appendingPathComponent(path),
                resolvingAgainstBaseURL: false)
            if !query.isEmpty { components?.queryItems = query }
            guard let url = components?.url else { throw FinanceSyncError.decoding }

            var request = URLRequest(url: url)
            request.httpMethod = method
            if let timeoutInterval { request.timeoutInterval = timeoutInterval }
            request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
            if let body {
                request.httpBody = body
                request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            }
            if let idempotencyKey {
                request.setValue(idempotencyKey, forHTTPHeaderField: "Idempotency-Key")
            }
            let (data, http) = try await send(request)

            if http.statusCode == 401, attempt == 0 {
                token = try await forceRefreshedToken()
                continue
            }
            guard (200..<300).contains(http.statusCode) else {
                throw mapError(http: http, data: data)
            }
            return (data, http)
        }
        preconditionFailure("unreachable")
    }

    private func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        do {
            let (data, response) = try await urlSession.data(for: request)
            guard let http = response as? HTTPURLResponse else {
                throw FinanceSyncError.transport("Phản hồi không hợp lệ.")
            }
            return (data, http)
        } catch is CancellationError {
            throw CancellationError()
        } catch let error as URLError where error.code == .cancelled {
            throw CancellationError()
        } catch let error as FinanceSyncError {
            throw error
        } catch {
            throw FinanceSyncError.transport(error.localizedDescription)
        }
    }

    /// Maps a failure status per the sync contract: typed bodies first,
    /// the rest as `(status, body)`.
    private func mapError(http: HTTPURLResponse, data: Data) -> FinanceSyncError {
        switch http.statusCode {
        case 401:
            return .unauthorized
        case 409:
            if let envelope = try? JSONDecoder().decode(
                SyncConflictEnvelope.self, from: data) {
                return .conflict(envelope.conflicts)
            }
            return .http(status: 409, body: bodyText(data))
        case 413:
            return .tooLarge
        case 422:
            if let envelope = try? JSONDecoder().decode(
                SyncErrorEnvelope.self, from: data) {
                switch envelope.error {
                case "idempotency_key_reused":
                    return .idempotencyKeyReused
                case "validation":
                    if let detail = try? JSONDecoder().decode(
                        SyncValidationDetail.self, from: data) {
                        return .validation(detail)
                    }
                    return .validation(SyncValidationDetail(
                        index: -1, field: "", constraint: "",
                        message: envelope.message ?? ""))
                default:
                    break
                }
            }
            return .http(status: 422, body: bodyText(data))
        default:
            return .http(status: http.statusCode, body: bodyText(data))
        }
    }

    /// The response body as text, capped — it travels inside the error
    /// for logging, never to the user verbatim.
    private func bodyText(_ data: Data) -> String {
        String(decoding: data.prefix(4_096), as: UTF8.self)
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

    private func mapTokenError(_ error: Error) -> FinanceSyncError {
        if let linkError = error as? WalletLinkError {
            switch linkError {
            case .notSignedIn, .refreshDenied:
                return .unauthorized
            default:
                return .transport(linkError.localizedDescription)
            }
        }
        return (error as? FinanceSyncError) ?? .transport(error.localizedDescription)
    }

    private func decode<T: Decodable>(_ type: T.Type, from data: Data) throws -> T {
        guard let decoded = try? JSONDecoder().decode(T.self, from: data) else {
            throw FinanceSyncError.decoding
        }
        return decoded
    }
}
