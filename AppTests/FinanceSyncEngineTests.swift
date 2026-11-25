import CryptoKit
import FinanceCore
import Foundation
import SwiftData
import Testing
@testable import AMFinance

/// `FinanceSyncEngine` end-to-end against an in-memory fake server that
/// implements the sync contract faithfully: per-user monotonic seq, rows
/// with seq + tombstones, `409` when a touched row's seq > `base_seq`,
/// deferred per-batch FK validation → `422` `index`, idempotent replay
/// by key + body, pull paging with `limit`. Serialized — the URLProtocol
/// seam is one static and engine tests share the process.
@Suite(.serialized)
struct FinanceSyncEngineTests {

    // MARK: - URL plumbing (same shape as FinanceSyncTests)

    private final class SyncStubProtocol: URLProtocol {
        nonisolated(unsafe) static var server: FakeSyncServer?

        override class func canInit(with request: URLRequest) -> Bool { true }
        override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

        override func startLoading() {
            guard let server = Self.server else {
                client?.urlProtocol(self, didFailWithError: URLError(.unknown))
                return
            }
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

    private struct FixedTokenProvider: WalletLinkAccessTokenProviding {
        func accessToken() async throws -> String { "token" }
        func forceRefreshedAccessToken() async throws -> String { "token" }
    }

    private func bodyData(of request: URLRequest) -> Data? {
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

    private struct ServerKey: Hashable {
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
    /// records with seq > cursor, paged by `limit`.
    private final class FakeSyncServer: @unchecked Sendable {
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

        init() { SyncStubProtocol.server = self }

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
            lock.lock()
            defer { lock.unlock() }
            let url = request.url!
            if url.path.hasSuffix("/v1/sync/pull") {
                return try handlePull(request)
            }
            if url.path.hasSuffix("/v1/sync/push") {
                return try handlePush(request)
            }
            return (http(url, status: 404), Data(#"{"error":"not_found"}"#.utf8))
        }

        // MARK: Internals

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

        private func handlePush(_ request: URLRequest) throws -> (HTTPURLResponse, Data) {
            let body = bodyData(from: request) ?? Data()
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

        private func bodyData(from request: URLRequest) -> Data? {
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

        private static func sha256(_ data: Data) -> String {
            SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
        }
    }

    // MARK: - Device scaffolding

    /// One device: its own app container + shadow store + engine, plus a
    /// context for seeding and verification.
    private struct Device {
        let container: ModelContainer
        let shadow: SyncShadowStore
        let engine: FinanceSyncEngine
        let context: ModelContext
    }

    private func makeDevice(
        server: FakeSyncServer, pullLimit: Int = 500
    ) throws -> Device {
        let container = try AppModelContainer.make(inMemory: true)
        let shadow = SyncShadowStore(
            modelContainer: try FinanceSyncSchema.makeContainer(inMemory: true))
        let engine = FinanceSyncEngine(
            modelContainer: container,
            api: client(for: server), shadow: shadow, pullLimit: pullLimit)
        return Device(
            container: container, shadow: shadow,
            engine: engine, context: ModelContext(container))
    }

    private func client(for server: FakeSyncServer) -> FinanceSyncAPIClient {
        FinanceSyncAPIClient(
            baseURL: URL(string: "https://sync.test/api")!,
            tokenProvider: FixedTokenProvider(),
            urlSession: server.session)
    }

    private func transaction(
        _ context: ModelContext, id: UUID
    ) throws -> LedgerTransaction {
        try #require(try context.fetch(FetchDescriptor<LedgerTransaction>(
            predicate: #Predicate { $0.id == id })).first)
    }

    private func account(
        _ context: ModelContext, id: UUID
    ) throws -> Account {
        try #require(try context.fetch(FetchDescriptor<Account>(
            predicate: #Predicate { $0.id == id })).first)
    }

    /// A minimal ledger — account + category + expense tx — returning ids.
    @discardableResult
    private func seedLedger(
        in context: ModelContext, note: String = "cà phê"
    ) throws -> (accountID: UUID, txID: UUID, categoryID: UUID) {
        let account = Account(name: "Tiền mặt", kind: .cash, openingBalance: 100_000)
        let category = LedgerCategory(name: "Ăn uống", kind: .expense)
        let tx = LedgerTransaction(kind: .expense, amount: 45_000, note: note)
        tx.account = account
        tx.category = category
        context.insert(account)
        context.insert(category)
        context.insert(tx)
        try context.save()
        return (account.id, tx.id, category.id)
    }

    /// One string field out of a row's stored DTO on the fake server.
    private func serverField(
        _ server: FakeSyncServer, entity: String, id: UUID, field: String
    ) -> SyncJSONValue? {
        guard case .object(let fields)? = server.row(entity: entity, id: id)?.data
        else { return nil }
        return fields[field]
    }

    // MARK: - Push from empty

    @Test func emptyStorePushesAllRowsThenOwnWritesAreNoOps() async throws {
        let server = FakeSyncServer()
        let device = try makeDevice(server: server)
        let (accountID, txID, _) = try seedLedger(in: device.context)

        let first = try await device.engine.syncOnce()
        #expect(first.pulled == 0)
        #expect(first.pushedUpserts == 3)
        #expect(first.pushedDeletes == 0)
        #expect(first.conflictsKeptLocal == 0)
        #expect(server.liveRowCount == 3)
        #expect(server.row(entity: "account", id: accountID)?.deleted == false)
        #expect(server.row(entity: "transaction", id: txID)?.deleted == false)

        // The pull cursor never jumps on push — the next cycle pulls our
        // own writes back and they apply as no-ops (hash equal → only
        // serverSeq is refreshed).
        let second = try await device.engine.syncOnce()
        #expect(second.pulled == 3)
        #expect(second.applied == 0)
        #expect(second.deletedLocally == 0)
        #expect(second.pushedUpserts == 0)
        #expect(second.pushedDeletes == 0)
        #expect(server.committedPushCount == 1)
        let entries = try await device.shadow.allEntries()
        #expect(entries.count == 3)
        #expect(entries.allSatisfy { $0.serverSeq > 0 })
    }

    // MARK: - Two devices

    @Test func secondDevicePullsEverythingAndConverges() async throws {
        let server = FakeSyncServer()
        let a = try makeDevice(server: server)
        let business = Business(name: "Quán", icon: "cup", colorHex: "FF8800")
        let account = Account(name: "Khách nợ", kind: .receivable)
        account.business = business
        let category = LedgerCategory(name: "Ăn uống", kind: .expense)
        let tx = LedgerTransaction(kind: .expense, amount: 45_000, note: "cà phê")
        tx.account = account
        tx.category = category
        tx.business = business
        let unit = RentalUnit(name: "Phòng 1", listPrice: 3_500_000)
        let lease = RentalLease(
            tenantName: "Nguyễn A", monthlyRent: 3_500_000, paymentDay: 5)
        lease.unit = unit
        for row: any PersistentModel in
            [business, account, category, tx, unit, lease] {
            a.context.insert(row)
        }
        try a.context.save()
        _ = try await a.engine.syncOnce()

        let b = try makeDevice(server: server)
        let report = try await b.engine.syncOnce()
        #expect(report.applied == 6)
        #expect(report.pushedUpserts == 0)

        #expect(try await a.engine.localContentHashes()
                == b.engine.localContentHashes())
        let leases = try b.context.fetch(FetchDescriptor<RentalLease>())
        #expect(leases.first?.unit?.name == "Phòng 1")
        let txs = try b.context.fetch(FetchDescriptor<LedgerTransaction>())
        #expect(txs.first?.account?.name == "Khách nợ")
        #expect(txs.first?.business?.name == "Quán")
    }

    @Test func editOnOneDeviceDeleteOnAnotherConverge() async throws {
        let server = FakeSyncServer()
        let a = try makeDevice(server: server)
        let (accountID, txID, _) = try seedLedger(in: a.context)
        _ = try await a.engine.syncOnce()
        let b = try makeDevice(server: server)
        _ = try await b.engine.syncOnce()

        // A edits the account name.
        try account(a.context, id: accountID).name = "Ví mới"
        try a.context.save()
        _ = try await a.engine.syncOnce()

        // B deletes the transaction.
        b.context.delete(try transaction(b.context, id: txID))
        try b.context.save()
        let bReport = try await b.engine.syncOnce()
        // B pulled A's account edit, pushed its delete.
        #expect(bReport.applied == 1)
        #expect(bReport.pushedDeletes == 1)

        // A pulls the tombstone — the row goes away everywhere.
        _ = try await a.engine.syncOnce()
        #expect(try await a.engine.localContentHashes()
                == b.engine.localContentHashes())
        #expect(try a.context.fetch(FetchDescriptor<LedgerTransaction>()).isEmpty)
        #expect(try account(a.context, id: accountID).name == "Ví mới")
    }

    @Test func concurrentEditKeepsLocalPendingOnLaterDevice() async throws {
        let server = FakeSyncServer()
        let a = try makeDevice(server: server)
        let (_, txID, _) = try seedLedger(in: a.context)
        _ = try await a.engine.syncOnce()
        let b = try makeDevice(server: server)
        _ = try await b.engine.syncOnce()

        // Both edit the same transaction offline — A's stamp older, B's newer.
        let txA = try transaction(a.context, id: txID)
        txA.note = "bản A"
        txA.updatedAt = Date(timeIntervalSince1970: 1_800_000_000)
        try a.context.save()
        let txB = try transaction(b.context, id: txID)
        txB.note = "bản B"
        txB.updatedAt = Date(timeIntervalSince1970: 1_800_000_100)
        try b.context.save()

        // A syncs first — its version lands on the server.
        _ = try await a.engine.syncOnce()
        // B syncs later: the pulled A-version meets a pending local edit
        // → local wins, B's version pushes instead.
        let reportB = try await b.engine.syncOnce()
        #expect(reportB.conflictsKeptLocal == 1)
        #expect(reportB.pushedUpserts == 1)
        #expect(serverField(
            server, entity: "transaction", id: txID, field: "note")
            == .string("bản B"))

        // A pulls once more — B's version applies (the newer updatedAt
        // wins the merge rule) and nothing else moved.
        _ = try await a.engine.syncOnce()
        #expect(try transaction(a.context, id: txID).note == "bản B")
        #expect(try await a.engine.localContentHashes()
                == b.engine.localContentHashes())
    }

    // MARK: - 409

    @Test func pushConflictPullsAndRetries() async throws {
        let server = FakeSyncServer()
        let a = try makeDevice(server: server)
        let (_, txID, _) = try seedLedger(in: a.context)
        _ = try await a.engine.syncOnce()
        let b = try makeDevice(server: server)
        _ = try await b.engine.syncOnce()

        // B edits the transaction — a pending change.
        let txB = try transaction(b.context, id: txID)
        txB.note = "bản B"
        txB.updatedAt = Date(timeIntervalSince1970: 1_800_000_200)
        try b.context.save()

        // Between B's pull and B's push another device lands a newer
        // version of the SAME row → the batch's base_seq is stale → 409.
        guard case .transaction(var interjectedDTO)? =
                SyncRecordMapper.dto(of: txB)
        else { Issue.record("tx did not map"); return }
        interjectedDTO.note = "bản server"
        interjectedDTO.updatedAt = Date(timeIntervalSince1970: 1_800_000_100)
        server.interject(
            entity: "transaction", id: txID,
            data: try SyncRecordMapper.jsonValue(of: .transaction(interjectedDTO)))

        let report = try await b.engine.syncOnce()
        #expect(report.retries409 == 1)
        // The retried pull met B's pending edit → local kept, pushed.
        #expect(report.conflictsKeptLocal == 1)
        #expect(report.pushedUpserts == 1)
        #expect(serverField(
            server, entity: "transaction", id: txID, field: "note")
            == .string("bản B"))
    }

    // MARK: - Deferred parent resolution

    @Test func childBeforeParentAcrossPageBoundaryResolves() async throws {
        let server = FakeSyncServer()
        let accountID = UUID()
        let txID = UUID()
        // The child record precedes its parent in seq order.
        server.putRecord(
            entity: "transaction", id: txID,
            data: try SyncRecordMapper.jsonValue(of: .transaction(BackupTransaction(
                id: txID, kindRaw: "expense", amount: 45_000,
                date: .now, note: "con trước",
                accountID: accountID, toAccountID: nil,
                categoryID: nil, businessID: nil, needsReview: false,
                externalSource: nil, externalID: nil,
                createdAt: .now, updatedAt: .now,
                rentalLeaseID: nil, rentalPeriod: nil))))
        server.putRecord(
            entity: "account", id: accountID,
            data: try SyncRecordMapper.jsonValue(of: .account(BackupAccount(
                id: accountID, name: "Tiền mặt", kindRaw: "cash",
                openingBalance: 100_000, icon: "banknote", colorHex: "",
                note: "", sortOrder: 0, isArchived: false, createdAt: .now,
                businessID: nil))))

        // One record per page — the parent lands strictly after the child.
        let device = try makeDevice(server: server, pullLimit: 1)
        let report = try await device.engine.syncOnce()
        #expect(report.pulled == 2)
        #expect(report.applied == 2)
        let tx = try transaction(device.context, id: txID)
        #expect(tx.account?.id == accountID)
    }

    // MARK: - 422 quarantine

    @Test func validationQuarantinesOneRecordUntilEdited() async throws {
        let server = FakeSyncServer()
        server.validator = { change in
            guard change.entity == .transaction,
                  case .object(let fields)? = change.data,
                  case .string(let note)? = fields["note"],
                  note == "INVALID"
            else { return nil }
            return ("note", "chk_note", "note is invalid")
        }
        let device = try makeDevice(server: server)
        let account = Account(name: "Tiền mặt", kind: .cash)
        let good = LedgerTransaction(kind: .expense, amount: 20_000, note: "ok")
        let bad = LedgerTransaction(kind: .expense, amount: 13_000, note: "INVALID")
        good.account = account
        bad.account = account
        device.context.insert(account)
        device.context.insert(good)
        device.context.insert(bad)
        try device.context.save()

        // The batch's bad record is quarantined; the rest still lands.
        let first = try await device.engine.syncOnce()
        #expect(first.quarantined == 1)
        #expect(first.pushedUpserts == 2)
        #expect(server.liveRowCount == 2)

        // Same content → the quarantined row is not retried.
        let second = try await device.engine.syncOnce()
        #expect(second.pushedUpserts == 0)
        let quarantines = try await device.shadow.quarantines()
        #expect(quarantines.count == 1)
        #expect(quarantines.first?.constraint == "chk_note")

        // Editing the row moves its hash → it retries and lands; the
        // quarantine releases on the ack.
        bad.note = "đã sửa"
        bad.updatedAt = .now
        try device.context.save()
        let third = try await device.engine.syncOnce()
        #expect(third.pushedUpserts == 1)
        #expect(try await device.shadow.quarantines().isEmpty)
        #expect(server.liveRowCount == 3)
        #expect(serverField(
            server, entity: "transaction", id: bad.id, field: "note")
            == .string("đã sửa"))
    }

    // MARK: - Crash / idempotent replay

    @Test func crashedPushReplaysSameKeyAndBody() async throws {
        let server = FakeSyncServer()
        let device = try makeDevice(server: server)
        let accountID = UUID()
        device.context.insert(Account(
            id: accountID, name: "Tiền mặt", kind: .cash, openingBalance: 7))
        try device.context.save()
        server.dropResponsesAfterCommit = 1

        // The batch commits server-side but the response never arrives.
        do {
            _ = try await device.engine.syncOnce()
            Issue.record("expected a transport error")
        } catch let error as FinanceSyncError {
            guard case .transport = error else {
                Issue.record("expected .transport, got \(error)")
                return
            }
        }
        #expect(server.row(entity: "account", id: accountID)?.deleted == false)
        let pending = try #require(try await device.shadow.pendingPush())
        #expect(pending.body != nil)

        // "Relaunch": a new engine over the same stores replays the stored
        // bytes — the server de-dupes by key+body and returns the same 200.
        let engine2 = FinanceSyncEngine(
            modelContainer: device.container,
            api: client(for: server), shadow: device.shadow)
        let report = try await engine2.syncOnce()
        #expect(report.pushedUpserts == 1)
        #expect(server.committedPushCount == 1)
        #expect(server.pushBodies.count == 2)
        #expect(server.pushBodies[0] == server.pushBodies[1])
        #expect(try await device.shadow.pendingPush() == nil)
        #expect(try await device.shadow.serverSeq(
            entity: .account, recordID: accountID) != nil)
    }

    // MARK: - FK-ordered deletes

    @Test func deletingParentPushesNullifiedChildFirst() async throws {
        let server = FakeSyncServer()
        let device = try makeDevice(server: server)
        let (accountID, txID, _) = try seedLedger(in: device.context)
        _ = try await device.engine.syncOnce()

        // Delete only the account — the child's reference nullifies, so
        // the batch is [upsert tx, delete account] and the server's FK
        // check stays satisfied.
        device.context.delete(try account(device.context, id: accountID))
        try device.context.save()
        let report = try await device.engine.syncOnce()
        #expect(report.pushedUpserts == 1)
        #expect(report.pushedDeletes == 1)

        let sent = try JSONDecoder().decode(
            SyncPushRequest.self, from: try #require(server.pushBodies.last))
        #expect(sent.changes.map(\.entity) == [.transaction, .account])
        #expect(sent.changes.map(\.op) == [.upsert, .delete])
        #expect(server.row(entity: "account", id: accountID)?.deleted == true)
        #expect(server.row(entity: "transaction", id: txID)?.deleted == false)
        #expect(serverField(
            server, entity: "transaction", id: txID, field: "accountID") == nil)
    }

    @Test func deletingParentAndChildOrdersDeletes() async throws {
        let server = FakeSyncServer()
        let device = try makeDevice(server: server)
        let (accountID, txID, _) = try seedLedger(in: device.context)
        _ = try await device.engine.syncOnce()

        // Delete both — the child delete travels first or the parent's
        // would violate the server's FK check.
        device.context.delete(try transaction(device.context, id: txID))
        device.context.delete(try account(device.context, id: accountID))
        try device.context.save()
        let report = try await device.engine.syncOnce()
        #expect(report.pushedDeletes == 2)

        let sent = try JSONDecoder().decode(
            SyncPushRequest.self, from: try #require(server.pushBodies.last))
        #expect(sent.changes.map(\.entity) == [.transaction, .account])
        #expect(sent.changes.map(\.op) == [.delete, .delete])
        #expect(server.row(entity: "transaction", id: txID)?.deleted == true)
        #expect(server.row(entity: "account", id: accountID)?.deleted == true)

        // Next pull returns our own tombstones as no-ops.
        let second = try await device.engine.syncOnce()
        #expect(second.pulled == 2)
        #expect(second.deletedLocally == 0)
        #expect(second.conflictsKeptLocal == 0)
    }

    // MARK: - Change hook

    @Test func localStoreChangeHookFiresOnPulledWrites() async throws {
        final class Counter: @unchecked Sendable {
            private var count = 0
            private let lock = NSLock()
            func bump() {
                lock.lock()
                count += 1
                lock.unlock()
            }
            var value: Int {
                lock.lock()
                defer { lock.unlock() }
                return count
            }
        }
        let server = FakeSyncServer()
        let a = try makeDevice(server: server)
        _ = try seedLedger(in: a.context)
        _ = try await a.engine.syncOnce()

        let b = try makeDevice(server: server)
        let counter = Counter()
        await b.engine.addLocalStoreChangeHook { counter.bump() }
        _ = try await b.engine.syncOnce()
        #expect(counter.value > 0)
    }

    // MARK: - Scan modes (quick/full)

    /// The first cycle of every engine is FULL; once markers persist the
    /// routine cycle is QUICK and only re-hashes what `updatedAt` flags.
    @Test func quickScanPicksUpEditedNewAndDeletedTransactions() async throws {
        let server = FakeSyncServer()
        let device = try makeDevice(server: server)
        let (_, txID, _) = try seedLedger(in: device.context)
        // Age the seeded row so it always sits outside the safety
        // margin — only the rows under test should ever be hashed.
        try transaction(device.context, id: txID).updatedAt =
            Date(timeIntervalSince1970: 1_700_000_000)
        try device.context.save()

        let first = try await device.engine.syncOnce()
        #expect(first.scanMode == .full)
        #expect(first.pushedUpserts == 3)
        // Cycle 2 absorbs the own-write echoes and moves the cursor.
        _ = try await device.engine.syncOnce()

        // A row pushed then deleted before its echo returns — its shadow
        // entry must make the QUICK id-set diff push the tombstone.
        let doomed = LedgerTransaction(kind: .expense, amount: 1, note: "x")
        device.context.insert(doomed)
        try device.context.save()
        let insertCycle = try await device.engine.syncOnce()
        #expect(insertCycle.scanMode == .quick)
        #expect(insertCycle.hashedTransactions == 1)
        #expect(insertCycle.pushedUpserts == 1)

        // Now a stamped edit, a brand-new row and the delete — one cycle.
        let edited = try transaction(device.context, id: txID)
        edited.note = "đã sửa"
        edited.updatedAt = .now
        let fresh = LedgerTransaction(kind: .income, amount: 99_000, note: "mới")
        device.context.insert(fresh)
        device.context.delete(doomed)
        try device.context.save()

        let report = try await device.engine.syncOnce()
        #expect(report.scanMode == .quick)
        // The pulled echo of the doomed upsert meets a local delete —
        // local wins and the tombstone pushes back out.
        #expect(report.pulled == 1)
        #expect(report.conflictsKeptLocal == 1)
        // Only the stamped row + the never-shadowed insert were hashed.
        #expect(report.hashedTransactions == 2)
        #expect(report.pushedUpserts == 2)
        #expect(report.pushedDeletes == 1)
        #expect(serverField(
            server, entity: "transaction", id: txID, field: "note")
            == .string("đã sửa"))
        #expect(server.row(entity: "transaction", id: fresh.id)?.deleted == false)
        #expect(server.row(entity: "transaction", id: doomed.id)?.deleted == true)
    }

    @Test func quickScanWithNoChangesHashesNoTransactions() async throws {
        let server = FakeSyncServer()
        let device = try makeDevice(server: server)
        let (_, txID, _) = try seedLedger(in: device.context)
        // Age the stamp so it sits outside the safety margin — QUICK
        // must then skip the row without hashing it.
        try transaction(device.context, id: txID).updatedAt =
            Date(timeIntervalSince1970: 1_700_000_000)
        try device.context.save()

        _ = try await device.engine.syncOnce()   // FULL — pushes the aged stamp
        let report = try await device.engine.syncOnce()
        #expect(report.scanMode == .quick)
        #expect(report.hashedTransactions == 0)
        #expect(report.pushedUpserts == 0)
        #expect(report.pushedDeletes == 0)
    }

    /// An edit that does NOT move `updatedAt` is invisible to QUICK —
    /// the documented trade-off — but the FULL backstop must catch it.
    @Test func fullScanCatchesEditThatDidNotBumpUpdatedAt() async throws {
        let server = FakeSyncServer()
        let device = try makeDevice(server: server)
        let (_, txID, _) = try seedLedger(in: device.context)
        _ = try await device.engine.syncOnce()
        _ = try await device.engine.syncOnce()

        // Stealth edit: new content, artificially old stamp.
        let tx = try transaction(device.context, id: txID)
        tx.note = "lén lút"
        tx.updatedAt = Date(timeIntervalSince1970: 1_700_000_000)
        try device.context.save()

        let quick = try await device.engine.syncOnce()
        #expect(quick.scanMode == .quick)
        #expect(quick.hashedTransactions == 0)
        #expect(quick.pushedUpserts == 0)
        #expect(serverField(
            server, entity: "transaction", id: txID, field: "note")
            == .string("cà phê"))

        let full = try await device.engine.syncOnce(fullScan: true)
        #expect(full.scanMode == .full)
        #expect(full.hashedTransactions == 1)
        #expect(full.pushedUpserts == 1)
        #expect(serverField(
            server, entity: "transaction", id: txID, field: "note")
            == .string("lén lút"))
    }

    /// A persisted `lastFullScanAt` older than the 6-hour interval makes
    /// the next routine cycle FULL again.
    @Test func staleLastFullScanForcesFullScan() async throws {
        let server = FakeSyncServer()
        let device = try makeDevice(server: server)
        _ = try seedLedger(in: device.context)
        _ = try await device.engine.syncOnce()
        let quick = try await device.engine.syncOnce()
        #expect(quick.scanMode == .quick)

        try await device.shadow.updateScanMarkers(
            lastScanStart: .now,
            lastFullScanAt: Date(timeIntervalSince1970: 1))
        let report = try await device.engine.syncOnce()
        #expect(report.scanMode == .full)
    }

    // MARK: - Perf smoke

    @Test func perfSmokeFiveThousandTransactionsPushAndPull() async throws {
        let server = FakeSyncServer()
        let a = try makeDevice(server: server)
        let account = Account(name: "Tiền mặt", kind: .cash)
        a.context.insert(account)
        for index in 0..<5_000 {
            let tx = LedgerTransaction(
                kind: .expense, amount: Int64(index + 1) * 1_000,
                note: "giao dịch \(index)")
            tx.account = account
            // Stamped long ago — the routine QUICK cycles below skip all
            // 5k without hashing, like a real store between syncs.
            tx.updatedAt = Date(timeIntervalSince1970: 1_700_000_000)
            a.context.insert(tx)
        }
        try a.context.save()

        var pushReport = FinanceSyncReport()
        let pushMs = await PerfClock.msAsync("sync5k.push") {
            pushReport = try await a.engine.syncOnce()
        }
        #expect(pushReport.scanMode == .full)
        #expect(pushReport.pushedUpserts == 5_001)

        let b = try makeDevice(server: server)
        var pullReport = FinanceSyncReport()
        let pullMs = await PerfClock.msAsync("sync5k.pull") {
            pullReport = try await b.engine.syncOnce()
        }
        #expect(pullReport.applied == 5_001)
        #expect(try await a.engine.localContentHashes()
                == b.engine.localContentHashes())
        // Generous bound: seconds, not minutes — a correctness gate, not
        // a benchmark. Debug-build SwiftData + contract JSON runs ~10x
        // slower than release; even so this must stay well under a
        // minute on a loaded machine (was ~77s before the hashing and
        // batched-fetch work landed).
        #expect(pushMs + pullMs < 60_000)

        // The steady-state numbers the task wants measured: a QUICK
        // cycle with nothing to do (absorbs the own-write echo first)
        // and a forced FULL re-hash.
        _ = try await a.engine.syncOnce()   // echo-absorb
        var quick = FinanceSyncReport()
        await PerfClock.msAsync("sync5k.quickNoChange") {
            quick = try await a.engine.syncOnce()
        }
        #expect(quick.scanMode == .quick)
        #expect(quick.hashedTransactions == 0)
        var full = FinanceSyncReport()
        await PerfClock.msAsync("sync5k.fullScan") {
            full = try await a.engine.syncOnce(fullScan: true)
        }
        #expect(full.scanMode == .full)
        #expect(full.hashedTransactions == 5_000)
    }

    // MARK: - 30k benchmark (gated)

    /// The 30k-transaction sync benchmark — same opt-in mechanism as
    /// `PerformanceBenchmark` (`amfinance-perf-big` marker in the test
    /// host's tmp, see its doc comment). Reports `PERF | sync30k.*`
    /// lines for: the first FULL push, the own-write echo pull, a
    /// routine QUICK cycle with nothing to do (the number a once-a-
    /// minute sync must keep small), a forced FULL scan, and the pull
    /// side applying all 30k records on a second device.
    @Test(
        .enabled(
            if: PerformanceBenchmarkGate.isEnabled,
            "30k sync benchmark: marker file in the test host's tmp"))
    func benchmarkThirtyThousandTransactions() async throws {
        let server = FakeSyncServer()
        let a = try makeDevice(server: server)
        let account = Account(name: "Tiền mặt", kind: .cash)
        a.context.insert(account)
        for index in 0..<30_000 {
            let tx = LedgerTransaction(
                kind: .expense, amount: Int64(index + 1) * 1_000,
                note: "giao dịch \(index)")
            tx.account = account
            // Stamped long ago — after the first FULL scan every QUICK
            // cycle skips all 30k without hashing.
            tx.updatedAt = Date(timeIntervalSince1970: 1_700_000_000)
            a.context.insert(tx)
        }
        try a.context.save()

        await PerfClock.msAsync("sync30k.push") {
            let report = try await a.engine.syncOnce()
            #expect(report.scanMode == .full)
            #expect(report.hashedTransactions == 30_000)
            #expect(report.pushedUpserts == 30_001)
        }
        await PerfClock.msAsync("sync30k.pullEcho") {
            _ = try await a.engine.syncOnce()
        }
        var quick = FinanceSyncReport()
        await PerfClock.msAsync("sync30k.quickNoChange") {
            quick = try await a.engine.syncOnce()
        }
        #expect(quick.scanMode == .quick)
        #expect(quick.hashedTransactions == 0)
        #expect(quick.pushedUpserts == 0)

        var full = FinanceSyncReport()
        await PerfClock.msAsync("sync30k.fullScan") {
            full = try await a.engine.syncOnce(fullScan: true)
        }
        #expect(full.scanMode == .full)
        #expect(full.hashedTransactions == 30_000)

        let b = try makeDevice(server: server)
        await PerfClock.msAsync("sync30k.pullApply") {
            let report = try await b.engine.syncOnce()
            #expect(report.applied == 30_001)
        }
        #expect(try await a.engine.localContentHashes()
                == b.engine.localContentHashes())
    }
}
