import CryptoKit
import FinanceCore
import Foundation
import SwiftData
@testable import AMFinance

/// Shared scaffolding for the FinanceSync tests: an in-memory fake server
/// implementing the sync contract, the per-test "device" (app container +
/// shadow store + engine + bootstrap) and a full-ledger seed covering all
/// nine entities with edge cases. Behaviour is identical to the private
/// copy that lived in `FinanceSyncEngineTests` — the fake only grew the
/// `POST /v1/backup/import` route the bootstrap exercises and a few test
/// seams (request counters, a pull gate, a one-shot import failure).

// MARK: - URL plumbing (same shape as FinanceSyncTests)

final class SyncStubProtocol: URLProtocol {
    /// host → server registry. Suites are `.serialized` only WITHIN
    /// themselves — different sync suites run in parallel, so each
    /// `FakeSyncServer` gets a unique base-URL host and requests route
    /// by it instead of a single shared static.
    nonisolated(unsafe) private static var servers: [String: FakeSyncServer] = [:]
    private static let lock = NSLock()

    static func register(_ server: FakeSyncServer, host: String) {
        lock.lock()
        servers[host] = server
        lock.unlock()
    }

    static func server(for host: String?) -> FakeSyncServer? {
        lock.lock()
        defer { lock.unlock() }
        return host.flatMap { servers[$0] }
    }

    override class func canInit(with request: URLRequest) -> Bool {
        server(for: request.url?.host) != nil
    }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        guard let server = Self.server(for: request.url?.host) else {
            client?.urlProtocol(self, didFailWithError: URLError(.unknown))
            return
        }
        // IMPORTANT: never block inside startLoading — the loader queue
        // is serial for the whole process, so a parked pull would stall
        // every other stubbed request until the 60s request timeout.
        // The hold seam parks the DELIVERY instead: the load stays open
        // asynchronously and the server replays `deliver` on release.
        let deliver = { [weak self] in
            guard let self else { return }
            self.deliver(server: server)
        }
        if server.holdIfArmed(request, deliver: deliver) { return }
        deliver()
    }

    private func deliver(server: FakeSyncServer) {
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

    override func stopLoading() {}
}

struct FixedTokenProvider: WalletLinkAccessTokenProviding {
    var token = "token"
    func accessToken() async throws -> String { token }
    func forceRefreshedAccessToken() async throws -> String { token }
}

/// `URLRequest.httpBody` is often nil inside a `URLProtocol` — the body
/// only arrives on `httpBodyStream`.
func syncTestBodyData(of request: URLRequest) -> Data? {
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

// MARK: - The fake sync server

struct ServerKey: Hashable {
    var entity: String
    var id: UUID
}

private struct ServerRow {
    var seq: Int64
    var deleted: Bool
    var data: SyncJSONValue?
}

/// The contract, in memory. Push: idempotent replay by key + body
/// (a replayed committed key returns the stored 200 without applying
/// again), `409` when a touched row's seq > `base_seq`, deferred
/// per-batch FK validation (upsert refs must exist live; a delete's
/// dependents must be gone) → `422 index`, skipped deletes. Pull:
/// records with seq > cursor, paged by `limit`. Backup import:
/// REPLACE — upsert every record the document carries, tombstone
/// every live row it does not, and write dangling `*ID` references
/// as NULL exactly like the real server.
final class FakeSyncServer: @unchecked Sendable {
    private let lock = NSLock()
    private var rows: [ServerKey: ServerRow] = [:]
    private var nextSeq: Int64 = 0
    /// Idempotency key → (body sha-256, stored 200 body).
    private var committedPushes: [String: (String, Data)] = [:]
    /// Server-side writes committed just before the next push's
    /// checks — another device landing a write mid-cycle.
    private var interjectedWrites: [(ServerKey, Bool, SyncJSONValue?)] = []
    /// Extra per-change validation hook → (field, constraint, message).
    var validator: ((SyncChange) -> (String, String, String)?)?
    /// Committed pushes whose HTTP response is dropped — a dead
    /// network right after the server applied the batch.
    var dropResponsesAfterCommit = 0
    /// Batches that actually applied — replays don't count.
    private(set) var committedPushCount = 0
    /// Every push body that reached the server, replays included.
    private(set) var pushBodies: [Data] = []
    /// Pull requests answered — tests rendezvous on "a pull is in
    /// flight" before exercising a second caller.
    private(set) var pullCount = 0
    /// Every raw body POSTed to `/v1/backup/import`, in order.
    private(set) var importBodies: [Data] = []
    /// Throwing seam: the next import request fails with this error once.
    var failNextImport: Error?

    /// Hold seam for rendezvous tests: while armed, each pull request's
    /// delivery is parked (the URLProtocol load stays open) until
    /// `releaseHeldPulls()` replays it. `holdIfArmed` runs on the loader
    /// thread — it only ever queues a closure, never blocks.
    private var heldDeliveries: [() -> Void] = []
    private var _holdPulls = false
    /// Lock-protected — tests flip it while requests are in flight.
    var holdPulls: Bool {
        get { lock.lock(); defer { lock.unlock() }; return _holdPulls }
        set { lock.lock(); _holdPulls = newValue; lock.unlock() }
    }

    var heldPullCount: Int {
        lock.lock()
        defer { lock.unlock() }
        return heldDeliveries.count
    }

    /// Park `deliver` instead of running it — only for pull requests and
    /// only while `holdPulls` is armed. Returns true when parked.
    func holdIfArmed(
        _ request: URLRequest, deliver: @escaping () -> Void
    ) -> Bool {
        guard request.url?.path.hasSuffix("/v1/sync/pull") == true
        else { return false }
        lock.lock()
        defer { lock.unlock() }
        guard _holdPulls else { return false }
        heldDeliveries.append(deliver)
        return true
    }

    /// Replays every parked pull delivery and disarms the hold — parked
    /// in-flight engine cycles then complete like a late network answer.
    func releaseHeldPulls() {
        lock.lock()
        let deliveries = heldDeliveries
        heldDeliveries.removeAll()
        _holdPulls = false
        lock.unlock()
        for deliver in deliveries { deliver() }
    }

    /// Unique host so parallel test suites cannot clobber each other's
    /// fake — `syncTestClient(for:)` addresses `baseURL`.
    let host: String
    var baseURL: URL { URL(string: "https://\(host)/api")! }

    init() {
        host = "sync-\(UUID().uuidString.lowercased()).test"
        SyncStubProtocol.register(self, host: host)
    }

    var session: URLSession {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [SyncStubProtocol.self]
        return URLSession(configuration: configuration)
    }

    /// A row as (seq, deleted, data) — nil when never written.
    func row(entity: String, id: UUID)
        -> (seq: Int64, deleted: Bool, data: SyncJSONValue?)?
    {
        lock.lock()
        defer { lock.unlock() }
        guard let row = rows[ServerKey(entity: entity, id: id)] else { return nil }
        return (row.seq, row.deleted, row.data)
    }

    var liveRowCount: Int {
        lock.lock()
        defer { lock.unlock() }
        return rows.values.count(where: { !$0.deleted })
    }

    /// Direct server-side insert — seeds state no client pushed, in
    /// the seq order given.
    @discardableResult
    func putRecord(
        entity: String, id: UUID, deleted: Bool = false,
        data: SyncJSONValue?
    ) -> Int64 {
        lock.lock()
        defer { lock.unlock() }
        nextSeq += 1
        rows[ServerKey(entity: entity, id: id)] =
            ServerRow(seq: nextSeq, deleted: deleted, data: data)
        return nextSeq
    }

    /// Queues a server-side write committed just before the next
    /// push's checks (consumed once).
    func interject(
        entity: String, id: UUID, deleted: Bool = false,
        data: SyncJSONValue?
    ) {
        lock.lock()
        interjectedWrites.append(
            (ServerKey(entity: entity, id: id), deleted, data))
        lock.unlock()
    }

    func handle(_ request: URLRequest) throws -> (HTTPURLResponse, Data) {
        let url = request.url!
        lock.lock()
        defer { lock.unlock() }
        if url.path.hasSuffix("/v1/sync/pull") {
            return try handlePull(request)
        }
        if url.path.hasSuffix("/v1/sync/push") {
            return try handlePush(request)
        }
        if url.path.hasSuffix("/v1/backup/import") {
            return try handleImport(request)
        }
        return (http(url, status: 404), Data(#"{"error":"not_found"}"#.utf8))
    }

    // MARK: Internals

    private func handlePull(_ request: URLRequest) throws -> (HTTPURLResponse, Data) {
        pullCount += 1
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

    private func handleImport(_ request: URLRequest) throws -> (HTTPURLResponse, Data) {
        let body = syncTestBodyData(of: request) ?? Data()
        importBodies.append(body)
        if let error = failNextImport {
            failNextImport = nil
            throw error
        }
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
        // it does not mention — all with fresh seqs so pull clients see
        // the replacement in seq order.
        let liveKeys = Set(incoming.map { ServerKey(entity: $0.entity, id: $0.id) })
        var upserted: [String: Int] = [:]
        var refsNulled: [String: Int] = [:]
        for (entity, id, data) in incoming {
            let (normalized, nulled) = Self.nullDanglingReferences(
                data, liveKeys: liveKeys)
            nextSeq += 1
            rows[ServerKey(entity: entity, id: id)] =
                ServerRow(seq: nextSeq, deleted: false, data: normalized)
            upserted[entity, default: 0] += 1
            refsNulled[entity, default: 0] += nulled
        }
        var tombstoned: [String: Int] = [:]
        let staleKeys = rows
            .filter { !$0.value.deleted && !liveKeys.contains($0.key) }
            .map(\.key)
        for key in staleKeys {
            nextSeq += 1
            rows[key] = ServerRow(seq: nextSeq, deleted: true, data: nil)
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

    private func handlePush(_ request: URLRequest) throws -> (HTTPURLResponse, Data) {
        let body = syncTestBodyData(of: request) ?? Data()
        pushBodies.append(body)
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

        // Another device's writes land before this batch is judged.
        for (interKey, deleted, data) in interjectedWrites {
            nextSeq += 1
            rows[interKey] = ServerRow(seq: nextSeq, deleted: deleted, data: data)
        }
        interjectedWrites.removeAll()

        // 409 — any touched row already newer than base_seq.
        let conflicts = push.changes.compactMap { change -> SyncConflict? in
            guard let row = rows[ServerKey(
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
            projected[ServerKey(entity: change.entity.rawValue, id: change.id)] =
                ServerRow(
                    seq: .max, deleted: change.op == .delete,
                    data: change.data)
        }
        for (index, change) in push.changes.enumerated() {
            if change.op == .upsert {
                if let violation = validator?(change) {
                    return try validation(
                        request.url!, index: index, field: violation.0,
                        constraint: violation.1, message: violation.2)
                }
                for (field, refKey) in Self.references(in: change.data) {
                    guard let target = projected[refKey], !target.deleted else {
                        return try validation(
                            request.url!, index: index, field: field,
                            constraint: "foreign_key",
                            message: "\(field) references missing \(refKey.entity) \(refKey.id)")
                    }
                }
            } else {
                let deletedKey = ServerKey(
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
            let changeKey = ServerKey(entity: change.entity.rawValue, id: change.id)
            switch change.op {
            case .upsert:
                nextSeq += 1
                rows[changeKey] = ServerRow(
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
        committedPushCount += 1
        if dropResponsesAfterCommit > 0 {
            dropResponsesAfterCommit -= 1
            throw URLError(.networkConnectionLost)
        }
        return (http(request.url!), responseBody)
    }

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
        -> [(field: String, key: ServerKey)]
    {
        guard case .object(let fields)? = data else { return [] }
        var refs: [(String, ServerKey)] = []
        for (field, entity) in referenceFields {
            if case .string(let raw)? = fields[field],
               let id = UUID(uuidString: raw) {
                refs.append((field, ServerKey(entity: entity, id: id)))
            }
        }
        return refs
    }

    /// The import's re-link rule: a `*ID` pointing at a row the
    /// replacement does not carry is dropped, like the real server
    /// writing it NULL — returns the cleaned data plus how many
    /// references were nulled.
    private static func nullDanglingReferences(
        _ data: SyncJSONValue, liveKeys: Set<ServerKey>
    ) -> (SyncJSONValue, Int) {
        guard case .object(var fields) = data else { return (data, 0) }
        var nulled = 0
        for (field, entity) in referenceFields {
            guard case .string(let raw)? = fields[field],
                  let id = UUID(uuidString: raw) else { continue }
            if !liveKeys.contains(ServerKey(entity: entity, id: id)) {
                fields.removeValue(forKey: field)
                nulled += 1
            }
        }
        return (.object(fields), nulled)
    }

    private static func sha256(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }
}

// MARK: - Test rendezvous helper

/// Polls `condition` until true or `timeout` — the async-safe
/// counterpart of a semaphore wait (which the compiler bans in async
/// contexts). Used to rendezvous on a pull held by
/// `FakeSyncServer.holdPulls`.
@discardableResult
func waitForTrue(
    timeout: Duration = .seconds(30),
    _ condition: @escaping @Sendable () -> Bool
) async -> Bool {
    let deadline = ContinuousClock.now + timeout
    while true {
        if condition() { return true }
        if ContinuousClock.now >= deadline { return false }
        try? await Task.sleep(for: .milliseconds(2))
    }
}

// MARK: - Device scaffolding

/// One device: its own app container + shadow store + engine +
/// bootstrap, plus a context for seeding and verification.
struct SyncTestDevice {
    let container: ModelContainer
    let shadow: SyncShadowStore
    let engine: FinanceSyncEngine
    let bootstrap: FinanceSyncBootstrap
    let context: ModelContext
}

func makeSyncDevice(
    api: FinanceSyncAPIClient, pullLimit: Int = 500
) throws -> SyncTestDevice {
    let container = try AppModelContainer.make(inMemory: true)
    let shadow = SyncShadowStore(
        modelContainer: try FinanceSyncSchema.makeContainer(inMemory: true))
    let engine = FinanceSyncEngine(
        modelContainer: container,
        api: api, shadow: shadow, pullLimit: pullLimit)
    let bootstrap = FinanceSyncBootstrap(
        modelContainer: container,
        api: api, engine: engine, shadow: shadow, pullLimit: pullLimit)
    return SyncTestDevice(
        container: container, shadow: shadow,
        engine: engine, bootstrap: bootstrap, context: ModelContext(container))
}

func makeSyncDevice(
    server: FakeSyncServer, pullLimit: Int = 500
) throws -> SyncTestDevice {
    try makeSyncDevice(api: syncTestClient(for: server), pullLimit: pullLimit)
}

func syncTestClient(for server: FakeSyncServer) -> FinanceSyncAPIClient {
    FinanceSyncAPIClient(
        baseURL: server.baseURL,
        tokenProvider: FixedTokenProvider(),
        urlSession: server.session)
}

// MARK: - Full-ledger seed

/// The ids of the seeded rows, for tests that edit/delete specific ones.
struct FullLedgerIDs {
    var business: UUID
    var cashAccount: UUID
    var bankAccount: UUID
    var creditCardAccount: UUID
    var loanAccount: UUID
    var receivableAccount: UUID
    var expenseCategory: UUID
    var incomeCategory: UUID
    var archivedCategory: UUID
    var expenseTx: UUID
    var bigIncomeTx: UUID
    var transferTx: UUID
    var unlinkedTx: UUID
    var rentTx: UUID
    var leaseExtraTx: UUID
    var rateChange: UUID
    var overallBudget: UUID
    var categoryBudget: UUID
    var monthlyRule: UUID
    var transferRule: UUID
    var rentalUnit: UUID
    var rentalLease: UUID
}

/// Rows covering ALL nine synced entities with the edge cases the sync
/// contract must carry: nil optionals, unicode/emoji notes, Int64-large
/// amounts, a transfer with `toAccount`, loan fields + a rate change,
/// both budget shapes, both recurring-rule shapes, and a rental
/// unit + lease + rent transaction with `rentalPeriod` (plus a lease
/// extra that links without a period).
@discardableResult
func seedFullLedger(in context: ModelContext) throws -> FullLedgerIDs {
    let business = Business(
        name: "Quán Cà Phê ☕️", icon: "cup.and.saucer.fill",
        colorHex: "FF8800", note: "chi nhánh Q1 🏪", sortOrder: 1)
    let cash = Account(
        name: "Tiền mặt", kind: .cash, openingBalance: 1_234_567,
        icon: "banknote.fill", colorHex: "00AA00", note: "ví chính")
    let bank = Account(
        name: "Ngân hàng ACB", kind: .bank, openingBalance: -50_000,
        sortOrder: 2)
    bank.externalSource = "wallet.amx.vn"
    bank.externalAccountID = "ext-9901"
    let card = Account(name: "Thẻ tín dụng", kind: .creditCard, sortOrder: 3)
    card.creditLimit = 50_000_000
    card.statementDay = 15
    card.graceDays = 45
    let loan = Account(name: "Khoản vay mua nhà", kind: .loan, sortOrder: 4)
    loan.loanPrincipal = 500_000_000
    loan.loanAnnualRatePercent = 8.55
    loan.loanTermMonths = 240
    loan.loanStartDate = Date(timeIntervalSince1970: 1_700_000_000.456)
    loan.loanPaymentDay = 10
    loan.loanMethodRaw = LoanMethod.annuity.rawValue
    let receivable = Account(
        name: "Khách nợ", kind: .receivable, sortOrder: 5)
    receivable.business = business

    let food = LedgerCategory(
        name: "Ăn uống 🍜", kind: .expense, icon: "fork.knife",
        colorHex: "FF3333", sortOrder: 1)
    let salary = LedgerCategory(name: "Lương", kind: .income)
    let archived = LedgerCategory(
        name: "Cũ", kind: .expense, isArchived: true)

    let expense = LedgerTransaction(
        kind: .expense, amount: 45_000,
        date: Date(timeIntervalSince1970: 1_763_000_000.789),
        note: "cà phê sáng ☕️🥐 đặc biệt",
        account: cash, category: food, business: business,
        needsReview: true)
    expense.externalSource = "wallet.amx.vn"
    expense.externalID = "wtx-12345"
    let bigIncome = LedgerTransaction(
        kind: .income, amount: 9_999_999_999_999_999,
        date: Date(timeIntervalSince1970: 1_763_100_000),
        note: "thu khủng 😄",
        account: bank, category: salary)
    let transfer = LedgerTransaction(
        kind: .transfer, amount: 2_000_000,
        date: Date(timeIntervalSince1970: 1_763_200_000),
        note: "nạp thẻ",
        account: cash, toAccount: card)
    let unlinked = LedgerTransaction(
        kind: .expense, amount: 1,
        date: Date(timeIntervalSince1970: 1_763_300_000))

    let unit = RentalUnit(
        name: "Phòng 101 🏠", listPrice: 3_500_000, sortOrder: 1,
        business: business)
    let lease = RentalLease(
        tenantName: "Nguyễn Văn A — khách lâu năm 👋",
        tenantPhone: "0901234567",
        startDate: Date(timeIntervalSince1970: 1_700_000_000),
        monthlyRent: 3_500_000, deposit: 7_000_000, paymentDay: 5,
        isActive: true, note: "hợp đồng 12 tháng",
        unit: unit)
    let rent = LedgerTransaction(
        kind: .income, amount: 3_500_000,
        date: Date(timeIntervalSince1970: 1_763_400_000),
        note: "tiền phòng T11",
        account: bank, business: business,
        rentalLease: lease,
        rentalPeriod: Date(timeIntervalSince1970: 1_762_848_000))
    let leaseExtra = LedgerTransaction(
        kind: .income, amount: 150_000,
        date: Date(timeIntervalSince1970: 1_763_500_000),
        note: "tiền điện",
        account: cash, rentalLease: lease)

    let rateChange = LoanRateChange(
        fromInstallment: 13, annualRatePercent: 9.75, account: loan)
    let overallBudget = Budget(monthlyLimit: 10_000_000, note: "tổng")
    let categoryBudget = Budget(
        monthlyLimit: 3_000_000, isActive: true,
        note: "ăn uống 🍚", category: food)
    let monthlyRule = RecurringRule(
        title: "Tiền thuê trọ 🏘️", kind: .expense, amount: 8_000_000,
        note: "mỗi tháng ngày 5",
        account: cash, category: food,
        frequency: .monthly, interval: 1,
        startDate: Date(timeIntervalSince1970: 1_700_000_000),
        endDate: Date(timeIntervalSince1970: 1_800_000_000),
        maximumOccurrences: 12,
        lastGeneratedDate: Date(timeIntervalSince1970: 1_763_000_000),
        autoCreate: true)
    let transferRule = RecurringRule(
        title: "Trả thẻ", kind: .transfer, amount: 1_000_000,
        account: bank, toAccount: card,
        frequency: .weekly, interval: 2,
        startDate: Date(timeIntervalSince1970: 1_760_000_000),
        autoCreate: false, isActive: false)

    for row: any PersistentModel in [
        business, cash, bank, card, loan, receivable,
        food, salary, archived,
        expense, bigIncome, transfer, unlinked, rent, leaseExtra,
        rateChange, overallBudget, categoryBudget,
        monthlyRule, transferRule, unit, lease,
    ] {
        context.insert(row)
    }
    try context.save()
    return FullLedgerIDs(
        business: business.id,
        cashAccount: cash.id, bankAccount: bank.id,
        creditCardAccount: card.id, loanAccount: loan.id,
        receivableAccount: receivable.id,
        expenseCategory: food.id, incomeCategory: salary.id,
        archivedCategory: archived.id,
        expenseTx: expense.id, bigIncomeTx: bigIncome.id,
        transferTx: transfer.id, unlinkedTx: unlinked.id,
        rentTx: rent.id, leaseExtraTx: leaseExtra.id,
        rateChange: rateChange.id,
        overallBudget: overallBudget.id, categoryBudget: categoryBudget.id,
        monthlyRule: monthlyRule.id, transferRule: transferRule.id,
        rentalUnit: unit.id, rentalLease: lease.id)
}
