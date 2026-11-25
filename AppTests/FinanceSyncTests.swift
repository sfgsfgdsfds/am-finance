import FinanceCore
import Foundation
import SwiftData
import Testing
@testable import AMFinance

/// Tests for the finance-sync foundations: the typed API client, the
/// shadow store, and the per-row model↔DTO mapper. Serialized because
/// every client test shares the one static `URLProtocol` hook.
@Suite(.serialized)
struct FinanceSyncTests {

    // MARK: - Test scaffolding (same shape as WalletLinkTests)

    private final class StubProtocol: URLProtocol {
        nonisolated(unsafe) static var current: StubServer?

        override class func canInit(with request: URLRequest) -> Bool { true }
        override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

        override func startLoading() {
            guard let server = Self.current else {
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

    private final class StubServer: @unchecked Sendable {
        private let lock = NSLock()
        private let handler: (URLRequest) throws -> (HTTPURLResponse, Data)
        private var requests: [URLRequest] = []

        init(handler: @escaping (URLRequest) throws -> (HTTPURLResponse, Data)) {
            self.handler = handler
            StubProtocol.current = self
        }

        var session: URLSession {
            let configuration = URLSessionConfiguration.ephemeral
            configuration.protocolClasses = [StubProtocol.self]
            return URLSession(configuration: configuration)
        }

        var requestCount: Int {
            lock.lock()
            defer { lock.unlock() }
            return requests.count
        }

        var capturedRequests: [URLRequest] {
            lock.lock()
            defer { lock.unlock() }
            return requests
        }

        fileprivate func handle(_ request: URLRequest) throws -> (HTTPURLResponse, Data) {
            lock.lock()
            requests.append(request)
            lock.unlock()
            return try handler(request)
        }
    }

    private actor StubTokenProvider: WalletLinkAccessTokenProviding {
        var regularToken: String
        var refreshedToken: String
        private(set) var forceCallCount = 0

        init(regular: String = "sync-token", refreshed: String = "sync-token") {
            self.regularToken = regular
            self.refreshedToken = refreshed
        }

        func accessToken() throws -> String { regularToken }

        func forceRefreshedAccessToken() throws -> String {
            forceCallCount += 1
            return refreshedToken
        }
    }

    private func makeClient(
        server: StubServer,
        provider: WalletLinkAccessTokenProviding = StubTokenProvider(),
        baseURL: String = "https://finance.ledinhdai.com/api"
    ) -> FinanceSyncAPIClient {
        FinanceSyncAPIClient(
            baseURL: URL(string: baseURL)!,
            tokenProvider: provider,
            urlSession: server.session)
    }

    private func jsonResponse(
        url: URL, status: Int = 200, json: String
    ) -> (HTTPURLResponse, Data) {
        let response = HTTPURLResponse(
            url: url, statusCode: status, httpVersion: nil,
            headerFields: ["Content-Type": "application/json"])!
        return (response, Data(json.utf8))
    }

    /// `URLRequest.httpBody` is often nil inside a `URLProtocol`.
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

    private func queryParam(_ request: URLRequest, _ name: String) -> String? {
        URLComponents(url: request.url!, resolvingAgainstBaseURL: false)?
            .queryItems?.first { $0.name == name }?.value
    }

    // MARK: - Push request shape

    @Test func pushSendsExactRequest() async throws {
        let id = UUID(uuidString: "11111111-2222-4333-8444-555555555555")!
        let server = StubServer { request in
            self.jsonResponse(url: request.url!, json: """
            {"high_water_seq":42,"results":[{"seq":42}]}
            """)
        }
        let change = SyncChange(
            entity: .transaction, id: id, op: .upsert,
            data: .object(["amount": .int(12_000)]))
        let response = try await makeClient(server: server).push(
            baseSeq: 7, changes: [change], idempotencyKey: "key-1.x:y")

        let request = try #require(server.capturedRequests.first)
        #expect(request.httpMethod == "POST")
        #expect(
            request.url?.absoluteString
            == "https://finance.ledinhdai.com/api/v1/sync/push")
        #expect(request.value(forHTTPHeaderField: "Authorization") == "Bearer sync-token")
        #expect(request.value(forHTTPHeaderField: "Content-Type") == "application/json")
        #expect(request.value(forHTTPHeaderField: "Idempotency-Key") == "key-1.x:y")

        let sent = try SyncJSONValue(jsonData: try #require(bodyData(of: request)))
        guard case .object(let root) = sent,
              case .array(let changes)? = root["changes"]
        else { Issue.record("body is not the push shape"); return }
        #expect(root["base_seq"] == .int(7))
        #expect(changes.count == 1)
        guard case .object(let first) = changes[0] else {
            Issue.record("change is not an object"); return
        }
        #expect(first["entity"] == .string("transaction"))
        #expect(first["op"] == .string("upsert"))
        #expect(first["id"] == .string("11111111-2222-4333-8444-555555555555"))

        #expect(response.highWaterSeq == 42)
        #expect(response.results == [.seq(42)])
    }

    // MARK: - Pull request shape

    @Test func pullSendsCursorAndLimit() async throws {
        let server = StubServer { request in
            self.jsonResponse(url: request.url!, json: """
            {"records":[
              {"entity":"account","id":"AAAAAAAA-1111-4111-8111-111111111111",
               "seq":11,"data":{"name":"Tiền mặt"}},
              {"entity":"budget","id":"BBBBBBBB-2222-4222-8222-222222222222",
               "seq":12,"deleted":true}],
             "next_cursor":12,"has_more":false}
            """)
        }
        let page = try await makeClient(server: server).pull(cursor: 10, limit: 200)

        let request = try #require(server.capturedRequests.first)
        #expect(request.httpMethod == "GET")
        #expect(
            request.url?.path == "/api/v1/sync/pull")
        #expect(queryParam(request, "cursor") == "10")
        #expect(queryParam(request, "limit") == "200")
        #expect(request.value(forHTTPHeaderField: "Authorization") == "Bearer sync-token")

        #expect(page.nextCursor == 12)
        #expect(page.records.count == 2)
        #expect(page.records[0].syncEntity == .account)
        #expect(page.records[1].deleted == true)
    }

    @Test func pullClampsLimitToServerRange() async throws {
        let server = StubServer { request in
            self.jsonResponse(
                url: request.url!,
                json: #"{"records":[],"next_cursor":0,"has_more":false}"#)
        }
        _ = try await makeClient(server: server).pull(cursor: -5, limit: 9_999)
        let request = try #require(server.capturedRequests.first)
        #expect(queryParam(request, "cursor") == "0")
        #expect(queryParam(request, "limit") == "1000")
    }

    // MARK: - highWater

    @Test func highWaterPushesAnEmptyChangeList() async throws {
        let server = StubServer { request in
            self.jsonResponse(
                url: request.url!, json: #"{"high_water_seq":99,"results":[]}"#)
        }
        let seq = try await makeClient(server: server).highWater()

        #expect(seq == 99)
        let request = try #require(server.capturedRequests.first)
        let sent = try SyncJSONValue(jsonData: try #require(bodyData(of: request)))
        guard case .object(let root) = sent,
              case .array(let changes)? = root["changes"]
        else { Issue.record("body is not the push shape"); return }
        #expect(changes.isEmpty)
        // A fresh idempotency key was minted for it.
        let key = try #require(
            request.value(forHTTPHeaderField: "Idempotency-Key"))
        #expect(UUID(uuidString: key) != nil)
    }

    // MARK: - Backup import

    @Test func importBackupPostsRawDocument() async throws {
        let server = StubServer { request in
            self.jsonResponse(url: request.url!, json: """
            {"entities":{"accounts":{"upserted":2,"tombstoned":0,"refs_nulled":1}},
             "ignored":[]}
            """)
        }
        let document = Data(#"{"formatVersion":5,"accounts":[]}"#.utf8)
        let summary = try await makeClient(server: server).importBackup(document)

        let request = try #require(server.capturedRequests.first)
        #expect(request.httpMethod == "POST")
        #expect(request.url?.path == "/api/v1/backup/import")
        #expect(request.value(forHTTPHeaderField: "Content-Type") == "application/json")
        // The body went out byte-identical — no re-encoding.
        #expect(bodyData(of: request) == document)
        // No idempotency key on imports.
        #expect(request.value(forHTTPHeaderField: "Idempotency-Key") == nil)

        #expect(summary.entities["accounts"]
                == SyncImportEntitySummary(upserted: 2, tombstoned: 0, refsNulled: 1))
    }

    // MARK: - Error mapping + 401 retry

    @Test func unauthorizedRefreshesAndRetriesOnce() async throws {
        let provider = StubTokenProvider(regular: "stale", refreshed: "fresh")
        let server = StubServer { request in
            if request.value(forHTTPHeaderField: "Authorization") == "Bearer stale" {
                return self.jsonResponse(
                    url: request.url!, status: 401, json: #"{"error":"unauthorized"}"#)
            }
            return self.jsonResponse(
                url: request.url!,
                json: #"{"records":[],"next_cursor":0,"has_more":false}"#)
        }
        let page = try await makeClient(server: server, provider: provider).pull()

        #expect(page.records.isEmpty)
        #expect(server.requestCount == 2)
        let forceCalls = await provider.forceCallCount
        #expect(forceCalls == 1)
        #expect(
            server.capturedRequests[1].value(forHTTPHeaderField: "Authorization")
            == "Bearer fresh")
    }

    @Test func unauthorizedTwiceMapsToUnauthorized() async throws {
        let provider = StubTokenProvider(regular: "stale", refreshed: "still-stale")
        let server = StubServer { request in
            self.jsonResponse(url: request.url!, status: 401, json: #"{"error":"x"}"#)
        }
        do {
            _ = try await makeClient(server: server, provider: provider).pull()
            Issue.record("expected unauthorized")
        } catch let error as FinanceSyncError {
            #expect(error == .unauthorized)
        }
        #expect(server.requestCount == 2)
    }

    @Test func conflictDecodesToTypedError() async throws {
        let server = StubServer { request in
            self.jsonResponse(url: request.url!, status: 409, json: """
            {"error":"conflict","conflicts":[
              {"entity":"transaction","id":"DDDDDDDD-4444-4444-8444-444444444444","seq":77}]}
            """)
        }
        do {
            _ = try await makeClient(server: server).push(
                baseSeq: 3,
                changes: [SyncChange(entity: .transaction, id: UUID(), op: .delete)],
                idempotencyKey: "k")
            Issue.record("expected conflict")
        } catch let error as FinanceSyncError {
            guard case .conflict(let conflicts) = error else {
                Issue.record("expected .conflict, got \(error)"); return
            }
            #expect(conflicts == [
                SyncConflict(
                    entity: "transaction",
                    id: UUID(uuidString: "DDDDDDDD-4444-4444-8444-444444444444")!,
                    seq: 77),
            ])
        }
    }

    @Test func validationDecodesToTypedError() async throws {
        let server = StubServer { request in
            self.jsonResponse(url: request.url!, status: 422, json: """
            {"error":"validation","index":0,"field":"amount",
             "constraint":"chk","message":"change 0: amount invalid"}
            """)
        }
        do {
            _ = try await makeClient(server: server).push(
                baseSeq: 0, changes: [], idempotencyKey: "k")
            Issue.record("expected validation")
        } catch let error as FinanceSyncError {
            #expect(error == .validation(SyncValidationDetail(
                index: 0, field: "amount", constraint: "chk",
                message: "change 0: amount invalid")))
        }
    }

    @Test func idempotencyKeyReusedDecodesToTypedError() async throws {
        let server = StubServer { request in
            self.jsonResponse(
                url: request.url!, status: 422,
                json: #"{"error":"idempotency_key_reused"}"#)
        }
        do {
            _ = try await makeClient(server: server).push(
                baseSeq: 0, changes: [], idempotencyKey: "k")
            Issue.record("expected idempotencyKeyReused")
        } catch let error as FinanceSyncError {
            #expect(error == .idempotencyKeyReused)
        }
    }

    @Test func tooLargeAndOtherStatusesMap() async throws {
        for (status, body, expected) in [
            (413, #"{"error":"request_too_large"}"#, FinanceSyncError.tooLarge),
            (400, #"{"error":"bad_request","message":"missing base_seq"}"#,
             FinanceSyncError.http(
                status: 400,
                body: #"{"error":"bad_request","message":"missing base_seq"}"#)),
            (415, #"{"error":"unsupported_media_type"}"#,
             FinanceSyncError.http(
                status: 415, body: #"{"error":"unsupported_media_type"}"#)),
            (500, "oops", FinanceSyncError.http(status: 500, body: "oops")),
        ] {
            let server = StubServer { request in
                self.jsonResponse(url: request.url!, status: status, json: body)
            }
            do {
                _ = try await makeClient(server: server).push(
                    baseSeq: 0, changes: [], idempotencyKey: "k")
                Issue.record("expected \(expected)")
            } catch let error as FinanceSyncError {
                #expect(error == expected)
            }
        }
    }

    @Test func transportErrorMaps() async throws {
        struct Offline: Error {}
        let server = StubServer { _ in throw URLError(.notConnectedToInternet) }
        do {
            _ = try await makeClient(server: server).pull()
            Issue.record("expected transport")
        } catch let error as FinanceSyncError {
            guard case .transport = error else {
                Issue.record("expected .transport, got \(error)"); return
            }
        }
    }

    // MARK: - Config

    @Test func configResolvesAndPersists() throws {
        let suiteName = "FinanceSyncTests.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let store = FinanceSyncConfigStore(defaults: defaults)
        #expect(store.load() == .default)
        #expect(
            try store.load().resolved().absoluteString
            == "https://finance.ledinhdai.com/api")

        store.save(FinanceSyncConfig(baseURL: "http://127.0.0.1:8080/api"))
        #expect(store.load().baseURL == "http://127.0.0.1:8080/api")
        #expect(try store.load().resolved().absoluteString == "http://127.0.0.1:8080/api")

        store.save(FinanceSyncConfig(baseURL: "not a url"))
        #expect(throws: FinanceSyncConfigError.invalidBaseURL) {
            try store.load().resolved()
        }
    }
}

/// The shadow store: CRUD on entries, the singleton state, the pending
/// push marker — all over an in-memory container.
@Suite(.serialized)
struct SyncShadowStoreTests {

    private func makeStore() throws -> SyncShadowStore {
        SyncShadowStore(
            modelContainer: try FinanceSyncSchema.makeContainer(inMemory: true))
    }

    private static let idA = UUID(uuidString: "00000000-0000-4000-8000-00000000000A")!
    private static let idB = UUID(uuidString: "00000000-0000-4000-8000-00000000000B")!

    @Test func entriesUpsertReadRemove() async throws {
        let store = try makeStore()
        let idA = Self.idA

        #expect(try await store.contentHash(entity: .account, recordID: idA) == nil)

        try await store.upsertEntry(
            entity: .account, recordID: idA, contentHash: "h1", serverSeq: 5)
        try await store.upsertEntry(
            entity: .transaction, recordID: Self.idB, contentHash: "h2", serverSeq: 6)

        #expect(try await store.contentHash(entity: .account, recordID: idA) == "h1")
        #expect(try await store.serverSeq(entity: .account, recordID: idA) == 5)

        // Same key rewrites in place — no duplicate rows.
        try await store.upsertEntry(
            entity: .account, recordID: idA, contentHash: "h1b", serverSeq: 9)
        #expect(try await store.contentHash(entity: .account, recordID: idA) == "h1b")
        #expect(try await store.serverSeq(entity: .account, recordID: idA) == 9)
        #expect(try await store.allEntries().count == 2)

        let snapshot = try await store.snapshot()
        #expect(snapshot == [
            SyncRecordKey(entity: .account, id: idA): "h1b",
            SyncRecordKey(entity: .transaction, id: Self.idB): "h2",
        ])

        try await store.removeEntry(entity: .account, recordID: idA)
        #expect(try await store.contentHash(entity: .account, recordID: idA) == nil)
        #expect(try await store.allEntries().count == 1)

        try await store.removeAllEntries()
        #expect(try await store.allEntries().isEmpty)
    }

    @Test func stateRoundTrips() async throws {
        let store = try makeStore()

        let initial = try await store.state()
        #expect(initial.pullCursor == 0)
        #expect(initial.isEnabled == false)
        #expect(initial.lastSyncAt == nil)
        #expect(initial.lastError == nil)

        try await store.setPullCursor(123)
        try await store.setEnabled(true)
        #expect(try await store.pullCursor() == 123)
        #expect(try await store.isEnabled() == true)

        let now = Date(timeIntervalSince1970: 1_800_000_000)
        try await store.recordSyncResult(finishedAt: now, error: "máy chủ lỗi")
        let state = try await store.state()
        #expect(state.lastSyncAt == now)
        #expect(state.lastError == "máy chủ lỗi")

        try await store.recordSyncResult(finishedAt: now, error: nil)
        #expect(try await store.state().lastError == nil)
    }

    @Test func pendingPushPersistsKeyBodyAndHash() async throws {
        let store = try makeStore()
        #expect(try await store.pendingPush() == nil)

        let body = Data(#"{"base_seq":4,"changes":[]}"#.utf8)
        try await store.setPendingPush(key: "push-1", body: body, bodyHash: "abc123")

        let pendingPushValue = try await store.pendingPush()
        let pending = try #require(pendingPushValue)
        #expect(pending.key == "push-1")
        #expect(pending.body == body)
        #expect(pending.bodyHash == "abc123")

        try await store.clearPendingPush()
        #expect(try await store.pendingPush() == nil)
    }

    @Test func wipeAllClearsEntriesAndState() async throws {
        let store = try makeStore()
        try await store.upsertEntry(
            entity: .account, recordID: Self.idA, contentHash: "h", serverSeq: 1)
        try await store.setPullCursor(55)
        try await store.setEnabled(true)
        try await store.setPendingPush(key: "k", body: nil, bodyHash: "x")

        try await store.wipeAll()

        #expect(try await store.allEntries().isEmpty)
        let state = try await store.state()
        #expect(state.pullCursor == 0)
        #expect(state.isEnabled == false)
        #expect(state.pendingPushKey == nil)
        #expect(state.pendingPushBodyHash == nil)
        #expect(state.pendingPushBody == nil)
    }

    @Test func shadowFileDoesNotJoinTheAppSchema() {
        // The shadow store must stay OUT of AppSchema.allModels — it is a
        // separate container, never backed up.
        #expect(!AppSchema.allModels.contains { $0 == SyncShadowEntry.self })
        #expect(!AppSchema.allModels.contains { $0 == SyncShadowState.self })
        #expect(FinanceSyncSchema.models.count == 2)
    }
}

/// The per-row model↔DTO mapper — the engine's read/write seam.
struct SyncRecordMapperTests {

    private func makeContext() throws -> ModelContext {
        ModelContext(try AppModelContainer.make(inMemory: true))
    }

    @Test func everyModelMapsToItsEntity() {
        #expect(SyncRecordMapper.entity(of: Account(name: "a", kind: .cash)) == .account)
        #expect(SyncRecordMapper.entity(
            of: LedgerCategory(name: "c", kind: .expense)) == .category)
        #expect(SyncRecordMapper.entity(of: Business(name: "b")) == .business)
        #expect(SyncRecordMapper.entity(
            of: LedgerTransaction(kind: .expense, amount: 1)) == .transaction)
        #expect(SyncRecordMapper.entity(
            of: LoanRateChange(fromInstallment: 1, annualRatePercent: 12)) == .loanRateChange)
        #expect(SyncRecordMapper.entity(of: Budget(monthlyLimit: 1)) == .budget)
        #expect(SyncRecordMapper.entity(
            of: RecurringRule(title: "r", kind: .expense, amount: 1,
                              frequency: .monthly, startDate: .now)) == .recurringRule)
        #expect(SyncRecordMapper.entity(of: RentalUnit(name: "u")) == .rentalUnit)
        #expect(SyncRecordMapper.entity(of: RentalLease(tenantName: "t")) == .rentalLease)
    }

    @Test func dtoCarriesEveryStoredFieldAndReference() throws {
        let context = try makeContext()
        let business = Business(name: "Quán", icon: "cup", colorHex: "FF0000")
        let account = Account(name: "Thu", kind: .receivable, openingBalance: 500)
        account.business = business
        let category = LedgerCategory(name: "Ăn uống", kind: .expense)
        let transaction = LedgerTransaction(kind: .expense, amount: 45_000)
        transaction.account = account
        transaction.category = category
        transaction.business = business
        context.insert(business)
        context.insert(account)
        context.insert(category)
        context.insert(transaction)

        guard case .account(let accountDTO)? = SyncRecordMapper.dto(of: account) else {
            Issue.record("account did not map"); return
        }
        #expect(accountDTO.businessID == business.id)
        #expect(accountDTO.openingBalance == 500)

        guard case .transaction(let transactionDTO)? =
                SyncRecordMapper.dto(of: transaction) else {
            Issue.record("transaction did not map"); return
        }
        #expect(transactionDTO.amount == 45_000)
        #expect(transactionDTO.accountID == account.id)
        #expect(transactionDTO.categoryID == category.id)
        #expect(transactionDTO.businessID == business.id)

        // The wire `data` is the backup-v5 encoding: camelCase keys,
        // .sssZ dates, references as ids.
        let json = try SyncRecordMapper.jsonValue(of: .transaction(transactionDTO))
        guard case .object(let fields) = json else {
            Issue.record("dto did not encode to an object"); return
        }
        #expect(fields["kindRaw"] == .string("expense"))
        #expect(fields["accountID"] == .string(account.id.uuidString.lowercased())
                || fields["accountID"] == .string(account.id.uuidString))
        #expect(fields["toAccountID"] == nil)   // nil fields are omitted
    }

    @Test func encodeDecodeRoundTripsEveryEntity() throws {
        let rows: [any PersistentModel] = [
            Business(name: "B", icon: "star", colorHex: "00FF00", note: "n"),
            LedgerCategory(name: "C", kind: .income, icon: "bag", sortOrder: 3),
            Account(name: "A", kind: .creditCard, openingBalance: -1_000,
                    note: "cc", sortOrder: 2, isArchived: true),
            LedgerTransaction(kind: .transfer, amount: 7_500),
            LoanRateChange(fromInstallment: 4, annualRatePercent: 9.5),
            Budget(monthlyLimit: 2_000_000, isActive: true, note: "x"),
            RecurringRule(title: "Thuê", kind: .expense, amount: 8_000_000,
                          frequency: .monthly, interval: 1, startDate: .now,
                          autoCreate: true),
            RentalUnit(name: "Phòng 1", listPrice: 3_500_000, sortOrder: 1),
            RentalLease(tenantName: "Nguyễn A", tenantPhone: "090",
                        monthlyRent: 3_500_000, deposit: 7_000_000,
                        paymentDay: 5, isActive: true),
        ]
        for row in rows {
            let dto = try #require(SyncRecordMapper.dto(of: row))
            let data = try SyncRecordMapper.encode(dto)
            let decoded = try SyncRecordMapper.decode(entity: dto.entity, from: data)
            // The wire only ever carries the encoded bytes (the encoder
            // truncates dates to ms), so the invariant is that decoding
            // and re-encoding reproduces the same document exactly.
            #expect(try SyncRecordMapper.encode(decoded) == data,
                    "\(dto.entity) round-trip mismatch")
        }
    }

    @Test func applyDecodesAndLinksIntoContext() throws {
        let context = try makeContext()
        var maps = BackupRowMaps()

        let businessID = UUID()
        let accountID = UUID()
        let transactionID = UUID()

        // A child may arrive before its parent — maps resolve what exists.
        SyncRecordMapper.apply(
            .business(BackupBusiness(
                id: businessID, name: "Quán", icon: "cup",
                colorHex: "FF8800", note: "", sortOrder: 1,
                isArchived: false)),
            into: context, maps: &maps)
        SyncRecordMapper.apply(
            .account(BackupAccount(
                id: accountID, name: "Tiền mặt", kindRaw: "cash",
                openingBalance: 100_000, icon: "banknote",
                colorHex: "00AA00", note: "", sortOrder: 0,
                isArchived: false, createdAt: .now,
                businessID: businessID)),
            into: context, maps: &maps)
        let outcome = SyncRecordMapper.apply(
            .transaction(BackupTransaction(
                id: transactionID, kindRaw: "expense", amount: 45_000,
                date: .now, note: "cà phê",
                accountID: accountID, toAccountID: nil,
                categoryID: nil, businessID: businessID,
                needsReview: false,
                externalSource: nil, externalID: nil,
                createdAt: .now, updatedAt: .now,
                rentalLeaseID: nil, rentalPeriod: nil)),
            into: context, maps: &maps)
        #expect(outcome == .inserted)

        let transaction = try #require(maps.transactions[transactionID])
        #expect(transaction.account?.id == accountID)
        #expect(transaction.business?.id == businessID)
        #expect(transaction.note == "cà phê")

        // Re-applying the same (or older-stamped) transaction skips —
        // the merge rule the restorer already uses.
        let stale = BackupTransaction(
            id: transactionID, kindRaw: "expense", amount: 1,
            date: .now, note: "stale",
            accountID: accountID, toAccountID: nil,
            categoryID: nil, businessID: nil, needsReview: false,
            externalSource: nil, externalID: nil,
            createdAt: .now,
            updatedAt: Date(timeIntervalSince1970: 1),
            rentalLeaseID: nil, rentalPeriod: nil)
        #expect(SyncRecordMapper.apply(
                    .transaction(stale), into: context, maps: &maps)
                == .skipped)
    }

    @Test func contentHashFeedsTheDiff() throws {
        // The pipeline the engine runs: model → dto → JSON → hash, and
        // the same record pulled back from the server hashes identically.
        let account = Account(name: "Tiền mặt", kind: .cash,
                              openingBalance: 50_000)
        let hashValue = try SyncRecordMapper.contentHash(of: account)
        let hash = try #require(hashValue)

        let dto = try #require(SyncRecordMapper.dto(of: account))
        let wireData = try SyncRecordMapper.encode(dto)
        #expect(try SyncContentHasher.hash(jsonData: wireData) == hash)

        // A server-rendered variant — arbitrary key order, lowercased id
        // — still hashes identically.
        guard case .object(var fields) = try SyncJSONValue(jsonData: wireData),
              case .string(let idString)? = fields["id"]
        else { Issue.record("expected an object carrying id"); return }
        fields["id"] = .string(idString.lowercased())
        let serverData = try JSONEncoder().encode(SyncJSONValue.object(fields))
        #expect(try SyncContentHasher.hash(jsonData: serverData) == hash)
    }
}
