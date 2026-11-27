#if DEBUG
import CryptoKit
import FinanceCore
import Foundation

/// In-app, in-memory finance-sync server for UI tests — reachable only
/// when the app launches with BOTH `-uiTestFakeSyncServer` and
/// `-uiTestInMemoryStore`, and compiled only in DEBUG builds, so it can
/// never serve a real user or a real store. It implements enough of the
/// sync contract to drive the whole flow offline: paged pull with seq
/// cursors and tombstones, idempotent push with per-change results,
/// deferred foreign-key validation, and the backup REPLACE import —
/// plus a fake signed-in token provider, so the Máy chủ page
/// (`ServerStatusView`) renders its signed-in state without a real
/// AMX login. "Tải lại dữ liệu" reloads through this server.
enum FinanceSyncUITestSupport {
    /// The launch argument that turns the fake server on.
    static let launchArgument = "-uiTestFakeSyncServer"
    /// The flag it is honoured beside — the throwaway in-memory UI-test
    /// store. `-uiTestFakeSyncServer` alone does nothing.
    static let inMemoryArgument = "-uiTestInMemoryStore"

    /// The pure gate — both arguments, or the fake never runs.
    static func enabled(arguments: [String]) -> Bool {
        arguments.contains(launchArgument)
            && arguments.contains(inMemoryArgument)
    }

    /// Whether this process should serve sync from `FinanceSyncUITestServer`.
    static var isEnabled: Bool {
        enabled(arguments: ProcessInfo.processInfo.arguments)
    }

    /// The fake signed-in token source — always returns the same token.
    struct TokenProvider: WalletLinkAccessTokenProviding {
        func accessToken() async throws -> String { "ui-test-token" }
        func forceRefreshedAccessToken() async throws -> String { "ui-test-token" }
    }

    /// The DEBUG `-uiTestOnline` flag: run the online launch pipeline
    /// (no seed, load through `GET /v1/backup/export`) against the
    /// in-app fake. Honoured only beside the two flags above.
    static let onlineArgument = "-uiTestOnline"

    static func onlineEnabled(arguments: [String]) -> Bool {
        enabled(arguments: arguments) && arguments.contains(onlineArgument)
    }
}

/// Builds a `GET /v1/backup/export` body from live wire rows — shared by
/// this in-app fake and the unit-test `FakeSyncServer`. The top-level
/// `syncSeq` rides next to the backup-v5 keys like the real server's.
enum FinanceSyncFakeExport {
    private struct Envelope: Encodable {
        var document: BackupDocument
        var syncSeq: Int64?

        struct Key: CodingKey {
            var stringValue: String
            var intValue: Int? { nil }
            init(stringValue: String) { self.stringValue = stringValue }
            init?(intValue: Int) { nil }
        }

        func encode(to encoder: Encoder) throws {
            try document.encode(to: encoder)
            if let syncSeq {
                var container = encoder.container(keyedBy: Key.self)
                try container.encode(syncSeq, forKey: Key(stringValue: "syncSeq"))
            }
        }
    }

    static func body(
        liveRows: [(entity: String, data: SyncJSONValue)],
        syncSeq: Int64?
    ) throws -> Data {
        var document = BackupDocument(
            formatVersion: BackupCodec.formatVersion,
            exportedAt: .now, appVersion: BackupCodec.appVersion,
            accounts: [], categories: [], businesses: [], transactions: [])
        for row in liveRows {
            guard let entity = SyncEntity(rawValue: row.entity) else { continue }
            switch try SyncRecordMapper.decode(entity: entity, from: row.data) {
            case .account(let dto): document.accounts.append(dto)
            case .category(let dto): document.categories.append(dto)
            case .business(let dto): document.businesses.append(dto)
            case .transaction(let dto): document.transactions.append(dto)
            case .loanRateChange(let dto): document.loanRateChanges.append(dto)
            case .budget(let dto): document.budgets.append(dto)
            case .recurringRule(let dto): document.recurringRules.append(dto)
            case .rentalUnit(let dto): document.rentalUnits.append(dto)
            case .rentalLease(let dto): document.rentalLeases.append(dto)
            }
        }
        return try BackupCodec.makeEncoder().encode(
            Envelope(document: document, syncSeq: syncSeq))
    }
}

/// URLProtocol stub routing the fake host's requests to
/// `FinanceSyncUITestServer.shared` — the same shape as
/// `SyncStubProtocol` in `FinanceSyncTestSupport.swift`.
final class FinanceSyncUITestStubProtocol: URLProtocol {
    nonisolated(unsafe) static var server: FinanceSyncUITestServer?

    override class func canInit(with request: URLRequest) -> Bool {
        request.url?.host == FinanceSyncUITestServer.host && server != nil
    }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    private var stopped = false

    override func startLoading() {
        guard let server = Self.server else {
            client?.urlProtocol(self, didFailWithError: URLError(.unknown))
            return
        }
        // Same rule as the unit-test stub: never block the loader queue.
        // A long-poll with nothing new parks `deliver` until a write or
        // the requested timeout.
        let deliver = { [weak self] in
            guard let self, !self.stopped else { return }
            self.deliver(server: server)
        }
        if server.parkWaitIfNeeded(
            request, token: ObjectIdentifier(self), deliver: deliver) {
            return
        }
        deliver()
    }

    private func deliver(server: FinanceSyncUITestServer) {
        do {
            let (response, data) = try server.handle(request)
            client?.urlProtocol(
                self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: data)
            client?.urlProtocolDidFinishLoading(self)
        } catch {
            client?.urlProtocol(self, didFailWithError: error)
        }
    }

    override func stopLoading() {
        stopped = true
        Self.server?.cancelWait(token: ObjectIdentifier(self))
    }
}

private struct UITestServerKey: Hashable {
    var entity: String
    var id: UUID
}

private struct UITestServerRow {
    var seq: Int64
    var deleted: Bool
    var data: SyncJSONValue?
}

/// The fake itself: the sync contract in memory — the same behaviour
/// `FakeSyncServer` implements for the unit tests, minus the test-only
/// seams (pull holds, interjected writes, counters). Push replays by
/// idempotency key + body hash, conflicts `409` when a touched row's seq
/// is newer than `base_seq`, validates deferred references per batch
/// (`422 index`), and marks unknown deletes `skipped`. Pull pages by
/// `cursor`/`limit` over the committed seq order. Import is a full
/// REPLACE: upsert the document's rows, tombstone the rest.
final class FinanceSyncUITestServer: @unchecked Sendable {
    static let host = "uitest.financesync.local"
    static let shared = FinanceSyncUITestServer()

    var baseURL: URL { URL(string: "https://\(Self.host)/api")! }

    var session: URLSession {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [FinanceSyncUITestStubProtocol.self]
        return URLSession(configuration: configuration)
    }

    private let lock = NSLock()
    private var rows: [UITestServerKey: UITestServerRow] = [:]
    private var nextSeq: Int64 = 0
    /// Idempotency key → (body sha-256, stored 200 body).
    private var committedPushes: [String: (String, Data)] = [:]

    /// The committed high-water seq. Read by the Máy chủ page under
    /// the UI-test fake (`server.highWater`) — never a write seam.
    var highWaterSeq: Int64 {
        lock.lock()
        defer { lock.unlock() }
        return nextSeq
    }

    private init() {
        if FinanceSyncUITestSupport.onlineEnabled(
            arguments: ProcessInfo.processInfo.arguments) {
            seedOnlineLaunchFixture()
        }
        FinanceSyncUITestStubProtocol.server = self
    }

    /// Account + expense category + three transactions `testOnlineLaunch`
    /// expects on the server before the app loads. The coffee expense
    /// stays uncategorized in "Chưa phân loại"; the milk-tea expense is
    /// flagged `needsReview` so the test can categorize it and confirm it
    /// leaves "Chưa phân loại" immediately; "Ăn uống" exists so quick-add
    /// and editing can pick it.
    private func seedOnlineLaunchFixture() {
        let now = Date()
        let accountID = UUID(uuidString: "11111111-0000-4000-8000-000000000001")!
        let categoryID = UUID(uuidString: "11111111-0000-4000-8000-0000000000C1")!
        let coffeeID = UUID(uuidString: "11111111-0000-4000-8000-0000000000A1")!
        let lunchID = UUID(uuidString: "11111111-0000-4000-8000-0000000000A2")!
        let reviewID = UUID(uuidString: "11111111-0000-4000-8000-0000000000A3")!
        let account = BackupAccount(
            id: accountID,
            name: "Tiền mặt",
            kindRaw: AccountKind.cash.rawValue,
            openingBalance: 500_000,
            icon: "banknote.fill",
            colorHex: "34C759",
            note: "",
            sortOrder: 0,
            isArchived: false,
            createdAt: now,
            creditLimit: nil,
            statementDay: nil,
            graceDays: nil,
            loanPrincipal: nil,
            loanAnnualRatePercent: nil,
            loanTermMonths: nil,
            loanStartDate: nil,
            loanPaymentDay: nil,
            loanMethodRaw: nil,
            externalSource: nil,
            externalAccountID: nil,
            businessID: nil)
        let category = BackupCategory(
            id: categoryID,
            name: "Ăn uống",
            kindRaw: CategoryKind.expense.rawValue,
            icon: "fork.knife",
            colorHex: "FF9500",
            sortOrder: 0,
            isArchived: false)
        func transaction(
            _ id: UUID, amount: Int64, note: String, category: UUID?,
            needsReview: Bool = false
        ) -> BackupTransaction {
            BackupTransaction(
                id: id,
                kindRaw: TransactionKind.expense.rawValue,
                amount: amount,
                date: now,
                note: note,
                accountID: accountID,
                toAccountID: nil,
                categoryID: category,
                businessID: nil,
                needsReview: needsReview,
                externalSource: nil,
                externalID: nil,
                createdAt: now,
                updatedAt: now,
                rentalLeaseID: nil,
                rentalPeriod: nil)
        }
        let fixtures: [(String, UUID, SyncBackupDTO)] = [
            ("account", accountID, .account(account)),
            ("category", categoryID, .category(category)),
            ("transaction", coffeeID, .transaction(transaction(
                coffeeID, amount: 35_000, note: "Cà phê online", category: nil))),
            ("transaction", lunchID, .transaction(transaction(
                lunchID, amount: 45_000, note: "Cơm trưa online",
                category: categoryID))),
            ("transaction", reviewID, .transaction(transaction(
                reviewID, amount: 40_000, note: "Trà sữa chờ duyệt",
                category: nil, needsReview: true))),
        ]
        for (entity, id, dto) in fixtures {
            let data = try! SyncRecordMapper.jsonValue(of: dto)
            nextSeq += 1
            rows[UITestServerKey(entity: entity, id: id)] = UITestServerRow(
                seq: nextSeq, deleted: false, data: data)
        }
    }

    // MARK: - Long-poll

    private final class Waiter {
        let token: ObjectIdentifier
        let cursor: Int64
        let deliver: () -> Void
        var fired = false
        var timer: DispatchSourceTimer?
        init(
            token: ObjectIdentifier, cursor: Int64,
            deliver: @escaping () -> Void
        ) {
            self.token = token
            self.cursor = cursor
            self.deliver = deliver
        }
    }

    private var waiters: [Waiter] = []

    /// Parks `GET /v1/sync/wait` until a later write moves the high-water
    /// past `cursor`, or `timeout` elapses (the delivery then answers
    /// 204). Returns false when the request can be answered now.
    func parkWaitIfNeeded(
        _ request: URLRequest,
        token: ObjectIdentifier,
        deliver: @escaping () -> Void
    ) -> Bool {
        guard request.url?.path.hasSuffix("/v1/sync/wait") == true,
              let url = request.url
        else { return false }
        let query = URLComponents(
            url: url, resolvingAgainstBaseURL: false)?.queryItems ?? []
        let cursor = Int64(query.first { $0.name == "cursor" }?.value ?? "") ?? 0
        let timeout = Double(query.first { $0.name == "timeout" }?.value ?? "") ?? 25
        lock.lock()
        let ready = nextSeq > cursor
        if ready {
            lock.unlock()
            return false
        }
        let waiter = Waiter(token: token, cursor: cursor, deliver: deliver)
        waiters.append(waiter)
        lock.unlock()
        let timer = DispatchSource.makeTimerSource(queue: .global(qos: .userInitiated))
        timer.schedule(deadline: .now() + max(timeout, 0))
        timer.setEventHandler { [weak self, weak waiter] in
            guard let self, let waiter else { return }
            self.fire(waiter)
        }
        waiter.timer = timer
        timer.resume()
        return true
    }

    func cancelWait(token: ObjectIdentifier) {
        lock.lock()
        let matches = waiters.filter { $0.token == token && !$0.fired }
        for waiter in matches { waiter.fired = true }
        waiters.removeAll { $0.fired }
        lock.unlock()
        for waiter in matches { waiter.timer?.cancel() }
    }

    private func fire(_ waiter: Waiter) {
        lock.lock()
        guard !waiter.fired else { lock.unlock(); return }
        waiter.fired = true
        waiters.removeAll { $0 === waiter }
        lock.unlock()
        waiter.timer?.cancel()
        waiter.deliver()
    }

    private func wakeWaits() {
        lock.lock()
        let ready = waiters.filter { !$0.fired && nextSeq > $0.cursor }
        for waiter in ready { waiter.fired = true }
        waiters.removeAll { $0.fired }
        lock.unlock()
        for waiter in ready {
            waiter.timer?.cancel()
            waiter.deliver()
        }
    }

    private func handleWait(
        _ request: URLRequest
    ) throws -> (HTTPURLResponse, Data) {
        let url = request.url!
        let query = URLComponents(
            url: url, resolvingAgainstBaseURL: false)?.queryItems ?? []
        let cursor = Int64(query.first { $0.name == "cursor" }?.value ?? "") ?? 0
        if nextSeq > cursor {
            let payload: [String: Int64] = ["high_water_seq": nextSeq]
            return (http(url), try JSONEncoder().encode(payload))
        }
        return (http(url, status: 204), Data())
    }

    func handle(_ request: URLRequest) throws -> (HTTPURLResponse, Data) {
        let url = request.url!
        lock.lock()
        let seqBefore = nextSeq
        defer {
            let changed = nextSeq != seqBefore
            lock.unlock()
            if changed { wakeWaits() }
        }
        if url.path.hasSuffix("/v1/sync/wait") {
            return try handleWait(request)
        }
        if url.path.hasSuffix("/v1/sync/pull") {
            return try handlePull(request)
        }
        if url.path.hasSuffix("/v1/sync/push") {
            return try handlePush(request)
        }
        if url.path.hasSuffix("/v1/backup/import") {
            return try handleImport(request)
        }
        if url.path.hasSuffix("/v1/backup/export") {
            return try handleExport(request)
        }
        if url.path.hasSuffix("/v1/sync/head") {
            return (http(url), try JSONEncoder().encode(
                ["high_water_seq": nextSeq]))
        }
        return (http(url, status: 404), Data(#"{"error":"not_found"}"#.utf8))
    }

    // MARK: - Export

    private func handleExport(_ request: URLRequest) throws -> (HTTPURLResponse, Data) {
        let live = rows.filter { !$0.value.deleted }
            .sorted { $0.value.seq < $1.value.seq }
            .compactMap { key, row in
                row.data.map { (entity: key.entity, data: $0) }
            }
        let body = try FinanceSyncFakeExport.body(
            liveRows: live, syncSeq: nextSeq)
        let response = HTTPURLResponse(
            url: request.url!, statusCode: 200, httpVersion: nil,
            headerFields: [
                "Content-Type": "application/json",
                "X-Sync-Seq": String(nextSeq),
            ])!
        return (response, body)
    }

    // MARK: - Pull

    private func handlePull(_ request: URLRequest) throws -> (HTTPURLResponse, Data) {
        let query = URLComponents(
            url: request.url!, resolvingAgainstBaseURL: false)?.queryItems ?? []
        let cursor = Int64(query.first { $0.name == "cursor" }?.value ?? "") ?? 0
        let limit = Int(query.first { $0.name == "limit" }?.value ?? "") ?? 500
        let after = rows.filter { $0.value.seq > cursor }
            .sorted { $0.value.seq < $1.value.seq }
        let pageRows = Array(after.prefix(max(limit, 1)))
        let records = pageRows.map { key, row in
            SyncPullRecord(
                entity: key.entity, id: key.id, seq: row.seq,
                deleted: row.deleted,
                data: row.deleted ? nil : row.data)
        }
        let body = try JSONEncoder().encode(SyncPullResponse(
            records: records,
            nextCursor: pageRows.last?.value.seq ?? cursor,
            hasMore: after.count > pageRows.count))
        return (http(request.url!), body)
    }

    // MARK: - Push

    private func handlePush(_ request: URLRequest) throws -> (HTTPURLResponse, Data) {
        let body = Self.bodyData(of: request) ?? Data()
        let key = request.value(forHTTPHeaderField: "Idempotency-Key") ?? ""
        let bodyHash = Self.sha256(body)
        if let committed = committedPushes[key] {
            if committed.0 == bodyHash {
                return (http(request.url!), committed.1)
            }
            return (http(request.url!, status: 422),
                    Data(#"{"error":"idempotency_key_reused"}"#.utf8))
        }
        guard let push = try? JSONDecoder().decode(
            SyncPushRequest.self, from: body)
        else {
            return (http(request.url!, status: 400),
                    Data(#"{"error":"bad_request"}"#.utf8))
        }

        // 409 — any touched row already newer than base_seq.
        let conflicts = push.changes.compactMap { change -> SyncConflict? in
            guard let row = rows[UITestServerKey(
                entity: change.entity.rawValue, id: change.id)],
                row.seq > push.baseSeq
            else { return nil }
            return SyncConflict(
                entity: change.entity.rawValue, id: change.id, seq: row.seq)
        }
        guard conflicts.isEmpty else {
            let arrayJSON = String(
                decoding: try JSONEncoder().encode(conflicts), as: UTF8.self)
            return (http(request.url!, status: 409),
                    Data(#"{"error":"conflict","conflicts":\#(arrayJSON)}"#.utf8))
        }

        // Deferred per-batch validation on the post-batch projection.
        var projected = rows
        for change in push.changes {
            projected[UITestServerKey(
                entity: change.entity.rawValue, id: change.id)] =
                UITestServerRow(
                    seq: .max, deleted: change.op == .delete,
                    data: change.data)
        }
        for (index, change) in push.changes.enumerated() {
            if change.op == .upsert {
                for (field, refKey) in Self.references(in: change.data) {
                    guard let target = projected[refKey], !target.deleted else {
                        return try validation(
                            request.url!, index: index, field: field,
                            constraint: "foreign_key",
                            message: "\(field) references missing \(refKey.entity) \(refKey.id)")
                    }
                }
            } else {
                let deletedKey = UITestServerKey(
                    entity: change.entity.rawValue, id: change.id)
                for (prowKey, prow) in projected where !prow.deleted {
                    if Self.references(in: prow.data).contains(
                        where: { $0.1 == deletedKey }) {
                        return try validation(
                            request.url!, index: index, field: "",
                            constraint: "foreign_key_dependents",
                            message: "\(prowKey.entity) \(prowKey.id) still references it")
                    }
                }
            }
        }

        // Commit.
        var results: [SyncPushResult] = []
        for change in push.changes {
            let changeKey = UITestServerKey(
                entity: change.entity.rawValue, id: change.id)
            switch change.op {
            case .upsert:
                nextSeq += 1
                rows[changeKey] = UITestServerRow(
                    seq: nextSeq, deleted: false, data: change.data)
                results.append(.seq(nextSeq))
            case .delete:
                if var row = rows[changeKey], !row.deleted {
                    nextSeq += 1
                    row.seq = nextSeq
                    row.deleted = true
                    row.data = nil
                    rows[changeKey] = row
                    results.append(.seq(nextSeq))
                } else {
                    results.append(.skipped)
                }
            }
        }
        let responseBody = try JSONEncoder().encode(
            SyncPushResponse(highWaterSeq: nextSeq, results: results))
        committedPushes[key] = (bodyHash, responseBody)
        return (http(request.url!), responseBody)
    }

    // MARK: - Backup import (REPLACE)

    private func handleImport(_ request: URLRequest) throws -> (HTTPURLResponse, Data) {
        let body = Self.bodyData(of: request) ?? Data()
        guard let document = try? BackupCodec.makeDecoder()
                .decode(BackupDocument.self, from: body)
        else {
            return (http(request.url!, status: 400),
                    Data(#"{"error":"bad_request","message":"malformed backup"}"#.utf8))
        }

        // Every record the document carries, as wire data.
        var incoming: [(entity: String, id: UUID, data: SyncJSONValue)] = []
        func collect<T>(
            _ entity: String, _ dtos: [T],
            id: (T) -> UUID, dto: (T) throws -> SyncBackupDTO
        ) throws {
            for value in dtos {
                incoming.append((entity, id(value),
                                 try SyncRecordMapper.jsonValue(of: dto(value))))
            }
        }
        try collect("category", document.categories, id: \.id) { .category($0) }
        try collect("business", document.businesses, id: \.id) { .business($0) }
        try collect("account", document.accounts, id: \.id) { .account($0) }
        try collect("rentalUnit", document.rentalUnits, id: \.id) { .rentalUnit($0) }
        try collect("rentalLease", document.rentalLeases, id: \.id) { .rentalLease($0) }
        try collect("loanRateChange", document.loanRateChanges, id: \.id) { .loanRateChange($0) }
        try collect("budget", document.budgets, id: \.id) { .budget($0) }
        try collect("recurringRule", document.recurringRules, id: \.id) { .recurringRule($0) }
        try collect("transaction", document.transactions, id: \.id) { .transaction($0) }

        // REPLACE: upsert the document's rows, tombstone every live row
        // it does not mention — fresh seqs, so pull clients see the
        // replacement in seq order.
        let liveKeys = Set(incoming.map {
            UITestServerKey(entity: $0.entity, id: $0.id) })
        var upserted: [String: Int] = [:]
        var refsNulled: [String: Int] = [:]
        for (entity, id, data) in incoming {
            let (normalized, nulled) = Self.nullDanglingReferences(
                data, liveKeys: liveKeys)
            nextSeq += 1
            rows[UITestServerKey(entity: entity, id: id)] =
                UITestServerRow(seq: nextSeq, deleted: false, data: normalized)
            upserted[entity, default: 0] += 1
            refsNulled[entity, default: 0] += nulled
        }
        var tombstoned: [String: Int] = [:]
        let staleKeys = rows
            .filter { !$0.value.deleted && !liveKeys.contains($0.key) }
            .map(\.key)
        for key in staleKeys {
            nextSeq += 1
            rows[key] = UITestServerRow(seq: nextSeq, deleted: true, data: nil)
            tombstoned[key.entity, default: 0] += 1
        }

        var summary: [String: SyncImportEntitySummary] = [:]
        for entity in Set(upserted.keys)
            .union(tombstoned.keys).union(refsNulled.keys) {
            summary[entity] = SyncImportEntitySummary(
                upserted: upserted[entity] ?? 0,
                tombstoned: tombstoned[entity] ?? 0,
                refsNulled: refsNulled[entity] ?? 0)
        }
        return (http(request.url!), try JSONEncoder().encode(
            SyncImportSummary(entities: summary, ignored: [])))
    }

    // MARK: - Internals

    private func validation(
        _ url: URL, index: Int, field: String,
        constraint: String, message: String
    ) throws -> (HTTPURLResponse, Data) {
        var detail = try JSONSerialization.jsonObject(
            with: JSONEncoder().encode(SyncValidationDetail(
                index: index, field: field,
                constraint: constraint, message: message))
        ) as! [String: Any]
        detail["error"] = "validation"
        return (http(url, status: 422),
                try JSONSerialization.data(withJSONObject: detail))
    }

    private func http(_ url: URL, status: Int = 200) -> HTTPURLResponse {
        HTTPURLResponse(
            url: url, statusCode: status, httpVersion: nil,
            headerFields: ["Content-Type": "application/json"])!
    }

    /// `*ID` reference fields inside a DTO `data` payload — the same
    /// map `SyncRecordMapper.references` walks, on the raw JSON.
    private static let referenceFields: [String: String] = [
        "accountID": "account", "toAccountID": "account",
        "categoryID": "category", "businessID": "business",
        "rentalLeaseID": "rentalLease", "unitID": "rentalUnit",
    ]

    private static func references(in data: SyncJSONValue?)
        -> [(field: String, key: UITestServerKey)]
    {
        guard case .object(let fields)? = data else { return [] }
        var refs: [(String, UITestServerKey)] = []
        for (field, entity) in referenceFields {
            if case .string(let raw)? = fields[field],
               let id = UUID(uuidString: raw) {
                refs.append((field, UITestServerKey(entity: entity, id: id)))
            }
        }
        return refs
    }

    /// The import's re-link rule: a `*ID` pointing at a row the
    /// replacement does not carry is dropped, like the real server
    /// writing it NULL — returns the cleaned data plus how many
    /// references were nulled.
    private static func nullDanglingReferences(
        _ data: SyncJSONValue, liveKeys: Set<UITestServerKey>
    ) -> (SyncJSONValue, Int) {
        guard case .object(var fields) = data else { return (data, 0) }
        var nulled = 0
        for (field, entity) in referenceFields {
            guard case .string(let raw)? = fields[field],
                  let id = UUID(uuidString: raw) else { continue }
            if !liveKeys.contains(UITestServerKey(entity: entity, id: id)) {
                fields.removeValue(forKey: field)
                nulled += 1
            }
        }
        return (.object(fields), nulled)
    }

    private static func sha256(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    /// `URLRequest.httpBody` is often nil inside a `URLProtocol` — the
    /// body only arrives on `httpBodyStream`.
    private static func bodyData(of request: URLRequest) -> Data? {
        if let body = request.httpBody { return body }
        guard let stream = request.httpBodyStream else { return nil }
        stream.open()
        defer { stream.close() }
        var data = Data()
        let buffer = UnsafeMutablePointer<UInt8>.allocate(capacity: 4096)
        defer { buffer.deallocate() }
        while stream.hasBytesAvailable {
            let read = stream.read(buffer, maxLength: 4096)
            if read <= 0 { break }
            data.append(buffer, count: read)
        }
        return data
    }
}
#endif
