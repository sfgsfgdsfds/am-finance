import Testing
import Foundation
@testable import AMFinance

/// Tests for the AMX wallet connection: PKCE, authorize/callback handling,
/// token exchange/refresh serialization, and the typed wallet API client.
/// Serialized because every test shares the one static `URLProtocol` hook.
@Suite(.serialized)
struct WalletLinkTests {

    // MARK: - Test scaffolding

    /// `URLProtocol` that forwards every request to the test-installed
    /// `WalletLinkStubServer`.
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

    /// Records requests and answers them through a test handler.
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

    /// Token provider returning a fixed token, or a different one on the
    /// forced refresh used by the 401 retry.
    private actor StubTokenProvider: WalletLinkAccessTokenProviding {
        var regularToken: String
        var refreshedToken: String
        private(set) var forceCallCount = 0

        init(regular: String = "test-token", refreshed: String = "test-token") {
            self.regularToken = regular
            self.refreshedToken = refreshed
        }

        func accessToken() throws -> String { regularToken }

        func forceRefreshedAccessToken() throws -> String {
            forceCallCount += 1
            return refreshedToken
        }
    }

    private static let testConfig = WalletLinkConfig(
        authBaseURL: "https://auth.amx.vn",
        walletBaseURL: "https://wallet.amx.vn",
        clientID: "cli_test123"
    )

    private func resolvedConfig() throws -> WalletLinkConfig.Resolved {
        try Self.testConfig.resolved()
    }

    private func makeSession(
        store: WalletLinkTokenStoring, server: StubServer
    ) -> WalletLinkSession {
        WalletLinkSession(
            configProvider: { Self.testConfig },
            tokenStore: store,
            urlSession: server.session
        )
    }

    private func makeClient(
        server: StubServer,
        provider: WalletLinkAccessTokenProviding = StubTokenProvider()
    ) -> WalletAPIClient {
        WalletAPIClient(
            baseURL: URL(string: "https://wallet.amx.vn")!,
            tokenProvider: provider,
            urlSession: server.session
        )
    }

    private func jsonResponse(
        url: URL, status: Int = 200, json: String
    ) -> (HTTPURLResponse, Data) {
        let response = HTTPURLResponse(
            url: url, statusCode: status, httpVersion: nil,
            headerFields: ["Content-Type": "application/json"])!
        return (response, Data(json.utf8))
    }

    /// A structurally valid unsigned JWT for decode-only tests.
    private func makeAccessToken(
        sub: String = "user-1",
        email: String? = "cu@amx.vn",
        exp: TimeInterval = 1_800_000_000
    ) -> String {
        var payload: [String: Any] = ["sub": sub, "exp": exp]
        if let email { payload["email"] = email }
        let data = try! JSONSerialization.data(withJSONObject: payload)
        return "eyJhbGciOiJSUzI1NiJ9.\(WalletLinkBase64.encode(data)).c2ln"
    }

    private func tokenResponseJSON(
        accessToken: String, refreshToken: String?, expiresIn: Int = 900
    ) -> String {
        let refresh = refreshToken.map { "\"\($0)\"" } ?? "null"
        return """
        {"access_token":"\(accessToken)","id_token":"id.tok.en",\
        "refresh_token":\(refresh),"token_type":"Bearer",\
        "expires_in":\(expiresIn),"scope":"openid profile email offline_access"}
        """
    }

    private func expiredTokens(
        refreshToken: String?, email: String = "cu@amx.vn"
    ) -> WalletLinkTokens {
        WalletLinkTokens(
            accessToken: makeAccessToken(email: email),
            refreshToken: refreshToken,
            accessTokenExpiry: .now.addingTimeInterval(-60),
            email: email,
            subject: "user-1"
        )
    }

    /// `URLRequest.httpBody` is often nil inside a `URLProtocol` — the body
    /// can arrive as a stream instead.
    private func bodyString(of request: URLRequest) -> String? {
        if let body = request.httpBody {
            return String(data: body, encoding: .utf8)
        }
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
        return String(data: data, encoding: .utf8)
    }

    private func queryParam(_ request: URLRequest, _ name: String) -> String? {
        URLComponents(url: request.url!, resolvingAgainstBaseURL: false)?
            .queryItems?.first { $0.name == name }?.value
    }

    // MARK: - PKCE

    @Test func pkceChallengeMatchesRFC7636AppendixB() {
        // RFC 7636 appendix B test vector.
        #expect(
            WalletLinkPKCE.challenge(
                for: "dBjftJeZ4CVP-mB92K27uhbUJU1p1r_wW1gFWFOEjXk")
            == "E9Melhoa2OwvFrEMTJguCHaoeK1t8URWbuGJSstw-cM")
    }

    @Test func pkceVerifierIs43CharBase64URL() {
        let verifier = WalletLinkPKCE.makeVerifier()
        #expect(verifier.count == 43)
        #expect(verifier.allSatisfy {
            $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "-" || $0 == "_")
        })
        // Random — two calls never match.
        #expect(WalletLinkPKCE.makeVerifier() != verifier)
        // State and nonce are base64url too.
        for value in [WalletLinkPKCE.makeState(), WalletLinkPKCE.makeNonce()] {
            #expect(value.allSatisfy {
                $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "-" || $0 == "_")
            })
        }
    }

    // MARK: - Authorize request + callback

    @Test func authorizeURLContainsEveryParameterExactly() throws {
        let request = WalletLinkAuthorizeRequest(
            authBaseURL: URL(string: "https://auth.amx.vn")!,
            clientID: "cli_abc",
            state: "state-1",
            nonce: "nonce-1",
            codeChallenge: "challenge-1"
        )
        let url = try #require(request.url())
        #expect(url.absoluteString.hasPrefix("https://auth.amx.vn/oauth/authorize?"))

        let items = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? []
        let query = Dictionary(uniqueKeysWithValues: items.map { ($0.name, $0.value ?? "") })
        #expect(query == [
            "response_type": "code",
            "client_id": "cli_abc",
            "redirect_uri": "vn.amx.finance://oauth/callback",
            "scope": "openid profile email offline_access",
            "state": "state-1",
            "nonce": "nonce-1",
            "code_challenge": "challenge-1",
            "code_challenge_method": "S256",
        ])
    }

    @Test func callbackExtractsCode() throws {
        let url = URL(string: "vn.amx.finance://oauth/callback?code=CODE123&state=s1")!
        #expect(
            try WalletLinkAuthorizationCallback.code(from: url, expectedState: "s1")
            == "CODE123")
    }

    @Test func callbackRejectsWrongState() {
        let url = URL(string: "vn.amx.finance://oauth/callback?code=CODE123&state=other")!
        do {
            _ = try WalletLinkAuthorizationCallback.code(from: url, expectedState: "s1")
            Issue.record("expected stateMismatch")
        } catch let error as WalletLinkError {
            #expect(error == .stateMismatch)
        } catch {
            Issue.record("unexpected error: \(error)")
        }
    }

    @Test func callbackSurfacesErrorAndDescription() {
        let url = URL(
            string: "vn.amx.finance://oauth/callback?error=access_denied&error_description=User%20refused&state=s1")!
        do {
            _ = try WalletLinkAuthorizationCallback.code(from: url, expectedState: "s1")
            Issue.record("expected authorizationDenied")
        } catch let error as WalletLinkError {
            #expect(
                error == .authorizationDenied(code: "access_denied", detail: "User refused"))
        } catch {
            Issue.record("unexpected error: \(error)")
        }
    }

    @Test func callbackWithoutCodeFails() {
        let url = URL(string: "vn.amx.finance://oauth/callback?state=s1")!
        do {
            _ = try WalletLinkAuthorizationCallback.code(from: url, expectedState: "s1")
            Issue.record("expected missingAuthCode")
        } catch let error as WalletLinkError {
            #expect(error == .missingAuthCode)
        } catch {
            Issue.record("unexpected error: \(error)")
        }
    }

    // MARK: - Token endpoint request bodies

    @Test func exchangeRequestBuildsExactFormBody() throws {
        let request = WalletLinkTokenEndpoint.exchangeRequest(
            config: try resolvedConfig(), code: "CODE", verifier: "VERIFIER")
        #expect(request.httpMethod == "POST")
        #expect(request.url?.absoluteString == "https://auth.amx.vn/oauth/token")
        #expect(
            request.value(forHTTPHeaderField: "Content-Type")
            == "application/x-www-form-urlencoded")
        let body = String(data: try #require(request.httpBody), encoding: .utf8)
        #expect(
            body == "grant_type=authorization_code&client_id=cli_test123&code=CODE"
                + "&redirect_uri=vn.amx.finance%3A%2F%2Foauth%2Fcallback"
                + "&code_verifier=VERIFIER")
    }

    @Test func refreshRequestBuildsExactFormBody() throws {
        let request = WalletLinkTokenEndpoint.refreshRequest(
            config: try resolvedConfig(), refreshToken: "R1")
        let body = String(data: try #require(request.httpBody), encoding: .utf8)
        #expect(body == "grant_type=refresh_token&client_id=cli_test123&refresh_token=R1")
    }

    // MARK: - JWT + tokens

    @Test func jwtPayloadDecodesSubEmailExp() {
        let token = makeAccessToken(sub: "u-9", email: "a@b.vn", exp: 1_800_000_000)
        let payload = WalletLinkJWT.payload(of: token)
        #expect(payload?.subject == "u-9")
        #expect(payload?.email == "a@b.vn")
        #expect(payload?.expiry == Date(timeIntervalSince1970: 1_800_000_000))
        #expect(WalletLinkJWT.payload(of: "not-a-jwt") == nil)
    }

    @Test func tokensDeriveIdentityAndExpiryFromAccessToken() {
        let now = Date(timeIntervalSince1970: 1_700_000_000)
        let tokens = WalletLinkTokens(
            accessToken: makeAccessToken(sub: "u-9", email: "e@x.vn"),
            refreshToken: "r",
            expiresIn: 900,
            now: now
        )
        #expect(tokens.email == "e@x.vn")
        #expect(tokens.subject == "u-9")
        #expect(tokens.accessTokenExpiry == now.addingTimeInterval(900))
        #expect(tokens.remainingLifetime(at: now) == 900)
    }

    // MARK: - Config

    @Test func configValidation() throws {
        // Missing client id.
        do {
            _ = try WalletLinkConfig.default.resolved()
            Issue.record("expected missingClientID")
        } catch let error as WalletLinkConfigError {
            #expect(error == .missingClientID)
        }

        // Non-https base URL.
        var config = Self.testConfig
        config.authBaseURL = "http://auth.amx.vn"
        do {
            _ = try config.resolved()
            Issue.record("expected invalidAuthBaseURL")
        } catch let error as WalletLinkConfigError {
            #expect(error == .invalidAuthBaseURL)
        }

        config = Self.testConfig
        config.walletBaseURL = "not a url"
        do {
            _ = try config.resolved()
            Issue.record("expected invalidWalletBaseURL")
        } catch let error as WalletLinkConfigError {
            #expect(error == .invalidWalletBaseURL)
        }

        let resolved = try resolvedConfig()
        #expect(resolved.authBaseURL.absoluteString == "https://auth.amx.vn")
        #expect(resolved.clientID == "cli_test123")
    }

    @Test func configStoreRoundTripsThroughUserDefaults() throws {
        let suiteName = "WalletLinkTests.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let store = WalletLinkConfigStore(defaults: defaults)
        #expect(store.load() == .default)

        var config = WalletLinkConfig.default
        config.clientID = "cli_round"
        config.authBaseURL = "https://auth.example.com"
        store.save(config)
        #expect(WalletLinkConfigStore(defaults: defaults).load() == config)
    }

    // MARK: - Refresh rotation + serialization

    @Test func refreshRotationStoresTheNewPair() async throws {
        let store = WalletLinkInMemoryTokenStore(stored: expiredTokens(refreshToken: "R1"))
        let newAccess = makeAccessToken(sub: "user-1", email: "moi@amx.vn")
        let server = StubServer { request in
            self.jsonResponse(
                url: request.url!,
                json: self.tokenResponseJSON(
                    accessToken: newAccess, refreshToken: "R2"))
        }
        let session = makeSession(store: store, server: server)

        let token = try await session.validAccessToken()
        #expect(token == newAccess)
        #expect(server.requestCount == 1)

        // The request carried the OLD refresh token.
        let request = try #require(server.capturedRequests.first)
        #expect(bodyString(of: request)?.contains("refresh_token=R1") == true)

        // …and the store now holds the rotated pair.
        let stored = try #require(store.load())
        #expect(stored.accessToken == newAccess)
        #expect(stored.refreshToken == "R2")
        #expect(stored.email == "moi@amx.vn")
    }

    @Test func concurrentValidAccessTokenTriggersExactlyOneRefresh() async throws {
        let store = WalletLinkInMemoryTokenStore(stored: expiredTokens(refreshToken: "R1"))
        let newAccess = makeAccessToken()
        let server = StubServer { request in
            self.jsonResponse(
                url: request.url!,
                json: self.tokenResponseJSON(
                    accessToken: newAccess, refreshToken: "R2"))
        }
        let session = makeSession(store: store, server: server)

        let tokens = try await withThrowingTaskGroup(of: String.self) { group in
            for _ in 0..<10 {
                group.addTask { try await session.validAccessToken() }
            }
            var results: [String] = []
            for try await token in group { results.append(token) }
            return results
        }

        #expect(tokens.count == 10)
        #expect(Set(tokens) == [newAccess])
        #expect(server.requestCount == 1)
    }

    @Test func invalidGrantSignsTheUserOut() async throws {
        let store = WalletLinkInMemoryTokenStore(stored: expiredTokens(refreshToken: "R1"))
        let server = StubServer { request in
            self.jsonResponse(
                url: request.url!, status: 400,
                json: #"{"error":"invalid_grant","error_description":"reused"}"#)
        }
        let session = makeSession(store: store, server: server)

        do {
            _ = try await session.validAccessToken()
            Issue.record("expected refreshDenied")
        } catch let error as WalletLinkError {
            #expect(error == .refreshDenied)
        }
        #expect(store.load() == nil)
        let status = await session.status
        #expect(status == .signedOut)
    }

    @Test func freshEnoughTokenSkipsRefresh() async throws {
        let tokens = WalletLinkTokens(
            accessToken: makeAccessToken(),
            refreshToken: "R1",
            accessTokenExpiry: .now.addingTimeInterval(3600),
            email: "cu@amx.vn",
            subject: "user-1"
        )
        let store = WalletLinkInMemoryTokenStore(stored: tokens)
        let server = StubServer { request in
            Issue.record("no network call expected")
            return self.jsonResponse(url: request.url!, json: "{}")
        }
        let session = makeSession(store: store, server: server)

        let token = try await session.validAccessToken()
        #expect(token == tokens.accessToken)
        #expect(server.requestCount == 0)
    }

    @Test func signOutClearsStoreAndRevokes() async throws {
        let store = WalletLinkInMemoryTokenStore(stored: expiredTokens(refreshToken: "R1"))
        let server = StubServer { request in
            self.jsonResponse(url: request.url!, json: "{}")
        }
        let session = makeSession(store: store, server: server)

        await session.signOut()
        #expect(store.load() == nil)
        let status = await session.status
        #expect(status == .signedOut)
        #expect(server.requestCount == 1)
        let request = try #require(server.capturedRequests.first)
        #expect(request.url?.absoluteString == "https://auth.amx.vn/oauth/revoke")
        #expect(bodyString(of: request)?.contains("token=R1") == true)
    }

    // MARK: - API decoding

    @Test func decodesAccountsResponse() async throws {
        let server = StubServer { request in
            self.jsonResponse(url: request.url!, json: """
            {"data":[{"id":12,"bank":"VPBank","account_number_masked":"*1234",\
            "holder_name":"NGUYEN VAN A","status":"active",\
            "last_listener_activity_at":"2026-11-22T10:15:00+07:00",\
            "last_transaction_at":null,"transactions_count":345}]}
            """)
        }
        let accounts = try await makeClient(server: server).accounts()

        let request = try #require(server.capturedRequests.first)
        #expect(request.url?.absoluteString == "https://wallet.amx.vn/api/v1/admin/bank/accounts")
        #expect(request.value(forHTTPHeaderField: "Authorization") == "Bearer test-token")

        let account = try #require(accounts.first)
        #expect(accounts.count == 1)
        #expect(account.id == 12)
        #expect(account.bank == "VPBank")
        #expect(account.accountNumberMasked == "*1234")
        #expect(account.holderName == "NGUYEN VAN A")
        #expect(account.status == "active")
        #expect(account.transactionsCount == 345)
        #expect(account.lastTransactionAt == nil)

        // "+07:00" parsed correctly — 10:15 Vietnam is 03:15 UTC.
        var utc = Calendar(identifier: .gregorian)
        utc.timeZone = TimeZone(identifier: "UTC")!
        let components = utc.dateComponents(
            [.year, .month, .day, .hour, .minute],
            from: try #require(account.lastListenerActivityAt))
        #expect(components.year == 2026 && components.month == 11 && components.day == 22)
        #expect(components.hour == 3 && components.minute == 15)
    }

    @Test func decodesTransactionsWithNullsAndNegativeAmount() async throws {
        let server = StubServer { request in
            self.jsonResponse(url: request.url!, json: """
            {"data":[{"id":981,"session_id":12,"bank_transaction_id":"FT26327",\
            "amount":-150000,"currency":"VND",\
            "transaction_date":"2026-11-22T09:58:12+07:00","note":null,\
            "counterparty_account_masked":null,\
            "created_at":"2026-11-22T09:58:20+07:00"}],\
            "meta":{"next_after_id":981,"has_more":false,\
            "server_time":"2026-11-22T10:20:00+07:00"}}
            """)
        }
        let page = try await makeClient(server: server)
            .transactions(sessionID: 12, afterID: 0, limit: 200)

        let request = try #require(server.capturedRequests.first)
        #expect(queryParam(request, "session_id") == "12")
        #expect(queryParam(request, "after_id") == "0")
        #expect(queryParam(request, "limit") == "200")

        let transaction = try #require(page.items.first)
        #expect(transaction.id == 981)
        #expect(transaction.sessionId == 12)
        #expect(transaction.bankTransactionId == "FT26327")
        #expect(transaction.amount == -150_000)
        #expect(transaction.currency == "VND")
        #expect(transaction.note == nil)
        #expect(transaction.counterpartyAccountMasked == nil)
        #expect(page.meta.hasMore == false)
        #expect(page.meta.nextAfterId == 981)
        #expect(page.meta.serverTime != nil)
    }

    // MARK: - API error mapping + 401 retry

    @Test func unauthorizedRefreshesAndRetriesOnce() async throws {
        let provider = StubTokenProvider(regular: "stale", refreshed: "fresh")
        let server = StubServer { request in
            if request.value(forHTTPHeaderField: "Authorization") == "Bearer stale" {
                return self.jsonResponse(
                    url: request.url!, status: 401,
                    json: #"{"error":"token_expired"}"#)
            }
            return self.jsonResponse(url: request.url!, json: #"{"data":[]}"#)
        }
        let accounts = try await makeClient(server: server, provider: provider).accounts()

        #expect(accounts.isEmpty)
        #expect(server.requestCount == 2)
        let forceCalls = await provider.forceCallCount
        #expect(forceCalls == 1)
        #expect(
            server.capturedRequests[1].value(forHTTPHeaderField: "Authorization")
            == "Bearer fresh")
    }

    @Test func unauthorizedTwiceMapsToNotSignedIn() async throws {
        let provider = StubTokenProvider(regular: "stale", refreshed: "still-stale")
        let server = StubServer { request in
            self.jsonResponse(url: request.url!, status: 401, json: #"{"error":"x"}"#)
        }
        do {
            _ = try await makeClient(server: server, provider: provider).accounts()
            Issue.record("expected notSignedIn")
        } catch let error as WalletAPIError {
            #expect(error == .notSignedIn)
        }
        #expect(server.requestCount == 2)
        let forceCalls = await provider.forceCallCount
        #expect(forceCalls == 1)
    }

    @Test func forbiddenMapsToNotAllowed() async throws {
        let server = StubServer { request in
            self.jsonResponse(
                url: request.url!, status: 403,
                json: #"{"detail":"not allowed"}"#)
        }
        do {
            _ = try await makeClient(server: server).accounts()
            Issue.record("expected notAllowed")
        } catch let error as WalletAPIError {
            #expect(error == .notAllowed)
        }
        #expect(server.requestCount == 1)
    }

    @Test func rateLimitedAndServerErrorsMap() async throws {
        for (status, body, expected) in [
            (429, "{}", WalletAPIError.rateLimited),
            (422, #"{"detail":"bad params"}"#,
             WalletAPIError.server(status: 422, detail: "bad params")),
            (500, "{}", WalletAPIError.server(status: 500, detail: nil)),
        ] {
            let server = StubServer { request in
                self.jsonResponse(url: request.url!, status: status, json: body)
            }
            do {
                _ = try await makeClient(server: server).accounts()
                Issue.record("expected \(expected)")
            } catch let error as WalletAPIError {
                #expect(error == expected)
            }
        }
    }

    // MARK: - Paging

    @Test func allTransactionsPagesUntilHasMoreIsFalse() async throws {
        let server = StubServer { request in
            if self.queryParam(request, "after_id") == "0" {
                return self.jsonResponse(url: request.url!, json: """
                {"data":[\
                {"id":1,"session_id":12,"bank_transaction_id":"A",\
                "amount":1000,"currency":"VND",\
                "transaction_date":"2026-11-22T09:00:00+07:00","note":null,\
                "counterparty_account_masked":null,"created_at":null},\
                {"id":2,"session_id":12,"bank_transaction_id":"B",\
                "amount":2000,"currency":"VND",\
                "transaction_date":"2026-11-22T09:01:00+07:00","note":null,\
                "counterparty_account_masked":null,"created_at":null}],\
                "meta":{"next_after_id":2,"has_more":true,"server_time":null}}
                """)
            }
            return self.jsonResponse(url: request.url!, json: """
            {"data":[\
            {"id":3,"session_id":12,"bank_transaction_id":"C",\
            "amount":3000,"currency":"VND",\
            "transaction_date":"2026-11-22T09:02:00+07:00","note":null,\
            "counterparty_account_masked":null,"created_at":null}],\
            "meta":{"next_after_id":3,"has_more":false,"server_time":null}}
            """)
        }
        let all = try await makeClient(server: server).allTransactions(sessionID: 12)

        #expect(all.map(\.id) == [1, 2, 3])
        #expect(server.requestCount == 2)
        #expect(queryParam(server.capturedRequests[1], "after_id") == "2")
    }

    @Test func allTransactionsStopsOnNonAdvancingCursor() async throws {
        let server = StubServer { request in
            // has_more stays true but the cursor never moves — must not loop.
            self.jsonResponse(url: request.url!, json: """
            {"data":[\
            {"id":7,"session_id":12,"bank_transaction_id":"A",\
            "amount":1000,"currency":"VND",\
            "transaction_date":"2026-11-22T09:00:00+07:00","note":null,\
            "counterparty_account_masked":null,"created_at":null}],\
            "meta":{"next_after_id":0,"has_more":true,"server_time":null}}
            """)
        }
        let all = try await makeClient(server: server).allTransactions(sessionID: 12)

        #expect(all.map(\.id) == [7])
        #expect(server.requestCount == 1)
    }
}
