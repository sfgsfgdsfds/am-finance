import Testing
import Foundation
import UIKit
import FinanceCore
@testable import AMFinance

/// Tests for the AI foundation: provider profiles + base-URL rules, the
/// UserDefaults/Keychain stores, request building for both API styles (with
/// and without images and JSON mode), SSE streaming incl. split chunks and
/// fallback, every error mapping, context builder budgets and privacy
/// switches, the extraction and categorization parsers, and image sizing.
/// Serialized because every test shares the one static `URLProtocol` hook.
@Suite(.serialized)
struct AIAssistantTests {

    // MARK: - Test scaffolding

    /// `URLProtocol` that forwards every request to the test-installed
    /// `AIStubServer`. Data can be delivered in several chunks to exercise
    /// streaming parsing.
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
                let stub = try server.handle(request)
                client?.urlProtocol(
                    self, didReceive: stub.response, cacheStoragePolicy: .notAllowed)
                for chunk in stub.chunks {
                    client?.urlProtocol(self, didLoad: chunk)
                }
                if let error = stub.error {
                    client?.urlProtocol(self, didFailWithError: error)
                    return
                }
                client?.urlProtocolDidFinishLoading(self)
            } catch {
                client?.urlProtocol(self, didFailWithError: error)
            }
        }

        override func stopLoading() {}
    }

    /// What the stub answers: an HTTP response plus optional body chunks and
    /// an optional transport error delivered after the headers.
    private struct StubReply {
        var response: HTTPURLResponse
        var chunks: [Data] = []
        var error: Error?

        static func data(
            url: URL, status: Int = 200, json: String
        ) -> StubReply {
            StubReply(
                response: HTTPURLResponse(
                    url: url, statusCode: status, httpVersion: nil,
                    headerFields: ["Content-Type": "application/json"])!,
                chunks: [Data(json.utf8)])
        }

        static func sse(url: URL, chunks: [String]) -> StubReply {
            StubReply(
                response: HTTPURLResponse(
                    url: url, statusCode: 200, httpVersion: nil,
                    headerFields: ["Content-Type": "text/event-stream"])!,
                chunks: chunks.map { Data($0.utf8) })
        }

        static func transport(url: URL, code: URLError.Code) -> StubReply {
            StubReply(
                response: HTTPURLResponse(
                    url: url, statusCode: 200, httpVersion: nil,
                    headerFields: nil)!,
                error: URLError(code))
        }
    }

    /// Records requests and answers them through a test handler.
    private final class StubServer: @unchecked Sendable {
        private let lock = NSLock()
        private let handler: (URLRequest) throws -> StubReply
        private var requests: [URLRequest] = []

        init(handler: @escaping (URLRequest) throws -> StubReply) {
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

        fileprivate func handle(_ request: URLRequest) throws -> StubReply {
            lock.lock()
            requests.append(request)
            lock.unlock()
            return try handler(request)
        }
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

    private func bodyJSON(_ request: URLRequest) throws -> [String: Any] {
        let body = try #require(bodyString(of: request))
        let object = try JSONSerialization.jsonObject(with: Data(body.utf8))
        return try #require(object as? [String: Any])
    }

    private func openAIProfile(
        baseURL: String = "https://api.test/v1",
        model: String = "m-1",
        visionModel: String = "",
        extraHeaders: String = "",
        supportsJSONMode: Bool = true
    ) -> AIProviderProfile {
        AIProviderProfile(
            name: "Test", style: .openAICompatible, baseURL: baseURL,
            model: model, visionModel: visionModel,
            extraHeaders: extraHeaders, supportsJSONMode: supportsJSONMode)
    }

    private func anthropicProfile(
        baseURL: String = "https://claude.test/v1",
        model: String = "claude-test"
    ) -> AIProviderProfile {
        AIProviderProfile(
            name: "Claude", style: .anthropic, baseURL: baseURL, model: model)
    }

    private func client(
        profile: AIProviderProfile, server: StubServer, key: String = "k-1"
    ) -> AIClient {
        AIClient(profile: profile, apiKey: key, urlSession: server.session)
    }

    private func openAIReplyJSON(_ text: String) -> String {
        #"{"choices":[{"message":{"content":"\#(text)"}}],"model":"m-1","usage":{"prompt_tokens":3,"completion_tokens":2}}"#
    }

    private func anthropicReplyJSON(_ text: String) -> String {
        #"{"content":[{"type":"text","text":"\#(text)"}],"model":"claude-test","usage":{"input_tokens":5,"output_tokens":2}}"#
    }

    // MARK: - Base URL

    @Test func baseURLNormalization() throws {
        // Trailing slashes collapse; missing scheme becomes https.
        #expect(try AIBaseURL.normalize("https://api.openai.com/v1/").absoluteString
            == "https://api.openai.com/v1")
        #expect(try AIBaseURL.normalize("https://api.openai.com/v1///").absoluteString
            == "https://api.openai.com/v1")
        #expect(try AIBaseURL.normalize("  api.openai.com/v1  ").absoluteString
            == "https://api.openai.com/v1")

        // http allowed only for localhost / private addresses.
        #expect(try AIBaseURL.normalize("http://localhost:11434/v1").absoluteString
            == "http://localhost:11434/v1")
        #expect(try AIBaseURL.normalize("http://127.0.0.1:8080").absoluteString
            == "http://127.0.0.1:8080")
        #expect(try AIBaseURL.normalize("http://192.168.1.10:3000/openai").absoluteString
            == "http://192.168.1.10:3000/openai")
        #expect(try AIBaseURL.normalize("http://10.0.0.5").absoluteString == "http://10.0.0.5")
        #expect(try AIBaseURL.normalize("http://gateway.local/v1").absoluteString
            == "http://gateway.local/v1")

        // http on a public host is refused.
        do {
            _ = try AIBaseURL.normalize("http://api.openai.com/v1")
            Issue.record("expected insecureBaseURL")
        } catch let error as AIError {
            #expect(error == .insecureBaseURL)
        }
        do {
            _ = try AIBaseURL.normalize("http://8.8.8.8")
            Issue.record("expected insecureBaseURL")
        } catch let error as AIError {
            #expect(error == .insecureBaseURL)
        }

        // Garbage is invalid.
        for raw in ["", "   ", "ht tp://x", "https://"] {
            do {
                _ = try AIBaseURL.normalize(raw)
                Issue.record("expected invalidBaseURL for \(raw.debugDescription)")
            } catch let error as AIError {
                #expect(error == .invalidBaseURL)
            }
        }
    }

    @Test func isPrivateHost() {
        for host in ["localhost", "api.localhost", "127.0.0.1", "::1",
                     "10.1.2.3", "172.16.0.1", "172.31.9.9", "192.168.0.1",
                     "169.254.1.1", "nas.local", "pi.lan", "fd00::1"] {
            #expect(AIBaseURL.isPrivateHost(host), Comment(rawValue: host))
        }
        for host in ["api.openai.com", "8.8.8.8", "172.32.0.1", "11.0.0.1",
                     "192.167.0.1", "126.0.0.1", "example.com"] {
            #expect(!AIBaseURL.isPrivateHost(host), Comment(rawValue: host))
        }
    }

    // MARK: - Extra headers

    @Test func extraHeadersParsing() throws {
        let headers = try AIExtraHeaders.parse("X-Tenant: blue\n\nX-Flag: on\n")
        #expect(headers.count == 2)
        #expect(headers[0].name == "X-Tenant")
        #expect(headers[0].value == "blue")
        #expect(headers[1] == ("X-Flag", "on"))

        // Values may contain colons (e.g. JSON).
        let json = try AIExtraHeaders.parse("X-Config: {\"a\":1}")
        #expect(json[0].value == "{\"a\":1}")

        for bad in ["no colon", "X-Bad: ", ": value"] {
            #expect(throws: AIError.self) { try AIExtraHeaders.parse(bad) }
        }
    }

    // MARK: - Provider store

    private func makeStore(
        keys: AIInMemoryAPIKeyStore = AIInMemoryAPIKeyStore()
    ) throws -> (AIProviderStore, AIInMemoryAPIKeyStore, UserDefaults, String) {
        let suiteName = "AIAssistantTests.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        return (
            AIProviderStore(defaults: defaults, keyStore: keys),
            keys, defaults, suiteName
        )
    }

    @Test func storeRoundTripsAndTracksActive() throws {
        let (store, _, defaults, suite) = try makeStore()
        defer { defaults.removePersistentDomain(forName: suite) }

        #expect(store.profiles().isEmpty)
        #expect(store.activeProfile() == nil)

        let first = openAIProfile()
        let second = anthropicProfile()
        store.save(first)
        // First profile saved becomes active automatically.
        #expect(store.activeProfile()?.id == first.id)
        store.save(second)
        #expect(store.profiles().count == 2)
        #expect(store.activeProfile()?.id == first.id)

        store.setActive(second.id)
        #expect(store.activeProfile()?.id == second.id)

        var renamed = first
        renamed.name = "Đổi tên"
        store.save(renamed)
        #expect(store.profiles().count == 2)
        #expect(store.profiles().first { $0.id == first.id }?.name == "Đổi tên")
    }

    @Test func keyLivesOutsideUserDefaults() throws {
        let keys = AIInMemoryAPIKeyStore()
        let (store, _, defaults, suite) = try makeStore(keys: keys)
        defer { defaults.removePersistentDomain(forName: suite) }

        let profile = openAIProfile()
        store.save(profile)
        try store.setAPIKey("sk-super-secret-123", for: profile.id)
        #expect(try store.apiKey(for: profile.id) == "sk-super-secret-123")

        // No UserDefaults value may contain the key — check text and Data.
        for (key, value) in defaults.dictionaryRepresentation() {
            #expect(!String(describing: value).contains("sk-super-secret-123"),
                    Comment(rawValue: "key \(key) leaks the API key"))
            if let data = value as? Data {
                let text = String(data: data, encoding: .utf8) ?? ""
                #expect(!text.contains("sk-super-secret-123"),
                        Comment(rawValue: "key \(key) leaks the API key"))
            }
        }
    }

    @Test func deletingProfileRemovesItsKey() throws {
        let keys = AIInMemoryAPIKeyStore()
        let (store, _, defaults, suite) = try makeStore(keys: keys)
        defer { defaults.removePersistentDomain(forName: suite) }

        let profile = openAIProfile()
        let other = anthropicProfile()
        store.save(profile)
        store.save(other)
        try store.setAPIKey("sk-delete-me", for: profile.id)

        store.delete(profile.id)
        #expect(try store.apiKey(for: profile.id) == nil)
        #expect(store.profiles().map(\.id) == [other.id])
        // Active falls back to the remaining profile.
        #expect(store.activeProfile()?.id == other.id)
    }

    @Test func makeClientRequiresKeyAndUsableProfile() throws {
        let keys = AIInMemoryAPIKeyStore()
        let (store, _, defaults, suite) = try makeStore(keys: keys)
        defer { defaults.removePersistentDomain(forName: suite) }

        let profile = openAIProfile()
        store.save(profile)
        // No key → notConfigured.
        #expect(throws: AIError.notConfigured) { try store.makeClient() }
        // Bad base URL → notConfigured.
        try store.setAPIKey("k", for: profile.id)
        var broken = profile
        broken.baseURL = "not a url"
        #expect(throws: AIError.notConfigured) {
            try store.makeClient(profile: broken)
        }
        _ = try store.makeClient(profile: profile)
    }

    // MARK: - OpenAI-style requests

    @Test func openAIRequestBuildsURLHeadersBody() async throws {
        let profile = openAIProfile(
            baseURL: "https://api.test/v1/",
            extraHeaders: "X-Tenant: blue\nX-Flag: on")
        let server = StubServer { request in
            .data(url: request.url!, json: self.openAIReplyJSON("xin chào"))
        }
        let response = try await client(profile: profile, server: server, key: "k-secret")
            .complete(.text("hi", system: "sys", jsonMode: true))

        #expect(response.text == "xin chào")
        #expect(response.model == "m-1")
        #expect(response.inputTokens == 3)
        #expect(response.outputTokens == 2)

        let request = try #require(server.capturedRequests.first)
        #expect(request.url?.absoluteString == "https://api.test/v1/chat/completions")
        #expect(request.httpMethod == "POST")
        #expect(request.value(forHTTPHeaderField: "Authorization") == "Bearer k-secret")
        #expect(request.value(forHTTPHeaderField: "Content-Type") == "application/json")
        #expect(request.value(forHTTPHeaderField: "X-Tenant") == "blue")
        #expect(request.value(forHTTPHeaderField: "X-Flag") == "on")

        let body = try bodyJSON(request)
        #expect(body["model"] as? String == "m-1")
        #expect(body["max_tokens"] as? Int == 2000)
        #expect(body["temperature"] as? Double == 0.2)
        #expect(body["stream"] == nil)
        #expect((body["response_format"] as? [String: Any])?["type"] as? String == "json_object")

        let messages = try #require(body["messages"] as? [[String: Any]])
        #expect(messages.count == 2)
        #expect(messages[0]["role"] as? String == "system")
        #expect(messages[0]["content"] as? String == "sys")
        #expect(messages[1]["role"] as? String == "user")
        #expect(messages[1]["content"] as? String == "hi")
    }

    @Test func openAIImagesBecomeDataURLsAndPickVisionModel() async throws {
        let profile = openAIProfile(visionModel: "vision-9")
        let server = StubServer { request in
            .data(url: request.url!, json: self.openAIReplyJSON("ok"))
        }
        let image = AIRequestImage(jpeg: Data([0xFF, 0xD8, 0x01, 0x02]))
        _ = try await client(profile: profile, server: server)
            .complete(.text("đọc bill", images: [image]))

        let body = try bodyJSON(try #require(server.capturedRequests.first))
        // The vision model is used because the request carries an image.
        #expect(body["model"] as? String == "vision-9")
        let messages = try #require(body["messages"] as? [[String: Any]])
        let parts = try #require(messages[0]["content"] as? [[String: Any]])
        #expect(parts.count == 2)
        #expect(parts[0]["type"] as? String == "text")
        #expect(parts[0]["text"] as? String == "đọc bill")
        #expect(parts[1]["type"] as? String == "image_url")
        let imageURL = (parts[1]["image_url"] as? [String: Any])?["url"] as? String
        #expect(imageURL?.hasPrefix("data:image/jpeg;base64,") == true)
        #expect(imageURL?.contains(image.jpeg.base64EncodedString()) == true)
    }

    @Test func openAIJSONModeSwitchOffOmitsResponseFormat() async throws {
        let profile = openAIProfile(supportsJSONMode: false)
        let server = StubServer { request in
            .data(url: request.url!, json: self.openAIReplyJSON("ok"))
        }
        _ = try await client(profile: profile, server: server)
            .complete(.text("hi", jsonMode: true))
        let body = try bodyJSON(try #require(server.capturedRequests.first))
        #expect(body["response_format"] == nil)
    }

    // MARK: - Anthropic-style requests

    @Test func anthropicRequestBuildsURLHeadersBody() async throws {
        let profile = anthropicProfile()
        let server = StubServer { request in
            .data(url: request.url!, json: self.anthropicReplyJSON("chào bạn"))
        }
        let response = try await client(profile: profile, server: server, key: "ak-9")
            .complete(.text("hi", system: "sys", jsonMode: true))

        #expect(response.text == "chào bạn")
        #expect(response.inputTokens == 5)
        #expect(response.outputTokens == 2)

        let request = try #require(server.capturedRequests.first)
        #expect(request.url?.absoluteString == "https://claude.test/v1/messages")
        #expect(request.value(forHTTPHeaderField: "x-api-key") == "ak-9")
        #expect(request.value(forHTTPHeaderField: "anthropic-version") == "2023-06-01")
        #expect(request.value(forHTTPHeaderField: "Authorization") == nil)

        let body = try bodyJSON(request)
        #expect(body["model"] as? String == "claude-test")
        #expect(body["max_tokens"] as? Int == 2000)
        #expect(body["system"] as? String == "sys")
        // jsonMode is not sent for Anthropic — the parser extracts JSON.
        #expect(body["response_format"] == nil)

        let messages = try #require(body["messages"] as? [[String: Any]])
        #expect(messages.count == 1)
        #expect(messages[0]["role"] as? String == "user")
        let blocks = try #require(messages[0]["content"] as? [[String: Any]])
        #expect(blocks[0]["type"] as? String == "text")
        #expect(blocks[0]["text"] as? String == "hi")
    }

    @Test func anthropicImagesBecomeSourceBlocks() async throws {
        let profile = anthropicProfile()
        let server = StubServer { request in
            .data(url: request.url!, json: self.anthropicReplyJSON("ok"))
        }
        let image = AIRequestImage(jpeg: Data([0xAA, 0xBB]))
        _ = try await client(profile: profile, server: server)
            .complete(.text("đọc bill", images: [image]))

        let body = try bodyJSON(try #require(server.capturedRequests.first))
        let messages = try #require(body["messages"] as? [[String: Any]])
        let blocks = try #require(messages[0]["content"] as? [[String: Any]])
        #expect(blocks.count == 2)
        #expect(blocks[0]["type"] as? String == "image")
        let source = try #require(blocks[0]["source"] as? [String: Any])
        #expect(source["type"] as? String == "base64")
        #expect(source["media_type"] as? String == "image/jpeg")
        #expect(source["data"] as? String == image.jpeg.base64EncodedString())
        #expect(blocks[1]["type"] as? String == "text")
    }

    // MARK: - SSE parser

    @Test func sseParserHandlesEventsAndDone() {
        var parser = AISSEParser()
        // `event:` and comment lines are ignored; blank line dispatches.
        // Chunks may split mid-line — the parser buffers partial input.
        #expect(parser.feed("event: message\n: heartbeat\nda") == [])
        #expect(parser.feed("ta: {\"a\":1}\n\n") == ["{\"a\":1}"])
        // Multi-line data joins with \n; whitespace-only line is blank.
        #expect(parser.feed("data: part1\ndata: part2\n  \n") == ["part1\npart2"])
        // CRLF line endings work the same.
        #expect(parser.feed("data: x\r\n\r\n") == ["x"])
        // Trailing event without blank line flushes via finish().
        #expect(parser.feed("data: [DONE]") == [])
        #expect(parser.finish() == ["[DONE]"])
        #expect(parser.finish() == [])
    }

    @Test func openAIStreamingYieldsDeltas() async throws {
        let payload = #"data: {"choices":[{"delta":{"content":"Xin"}}]}"# + "\n\n"
            + #"data: {"choices":[{"delta":{"content":" chào"}}]}"# + "\n\n"
            + "data: [DONE]\n\n"
        // Split mid-payload to prove incremental assembly.
        let cut = payload.index(payload.startIndex, offsetBy: payload.count / 2)
        let chunks = [String(payload[..<cut]), String(payload[cut...])]
        let server = StubServer { request in
            .sse(url: request.url!, chunks: chunks)
        }
        let stream = client(profile: openAIProfile(), server: server)
            .stream(.text("hi"))

        var deltas: [String] = []
        for try await delta in stream { deltas.append(delta) }
        #expect(deltas == ["Xin", " chào"])
        #expect(server.requestCount == 1)
    }

    @Test func anthropicStreamingYieldsTextDeltas() async throws {
        let chunks = [
            "event: content_block_delta\n"
                + #"data: {"type":"content_block_delta","index":0,"delta":{"type":"text_delta","text":"A"}}"# + "\n\n"
                + "event: ping\n" + #"data: {"type":"ping"}"# + "\n\n"
                + #"data: {"type":"content_block_delta","index":0,"delta":{"type":"text_delta","text":"B"}}"# + "\n\n"
                + #"data: {"type":"message_stop"}"# + "\n\n"
        ]
        let server = StubServer { request in
            .sse(url: request.url!, chunks: chunks)
        }
        let stream = client(profile: anthropicProfile(), server: server)
            .stream(.text("hi"))

        var deltas: [String] = []
        for try await delta in stream { deltas.append(delta) }
        #expect(deltas == ["A", "B"])
    }

    @Test func streamingFallsBackToNonStreamingWhenRejected() async throws {
        let server = StubServer { request in
            let isStream = self.bodyString(of: request)?.contains("\"stream\":true") ?? false
            if isStream {
                return .data(url: request.url!, status: 400,
                            json: #"{"error":{"message":"stream unsupported"}}"#)
            }
            return .data(url: request.url!, json: self.openAIReplyJSON("đầy đủ"))
        }
        var deltas: [String] = []
        for try await delta in client(profile: openAIProfile(), server: server)
            .stream(.text("hi")) {
            deltas.append(delta)
        }
        #expect(deltas == ["đầy đủ"])
        #expect(server.requestCount == 2)
    }

    @Test func streamPropagatesMappedErrorWhenFallbackAlsoFails() async throws {
        let server = StubServer { request in
            .data(url: request.url!, status: 401,
                  json: #"{"error":{"message":"bad key"}}"#)
        }
        do {
            for try await _ in client(profile: openAIProfile(), server: server)
                .stream(.text("hi")) {}
            Issue.record("expected invalidAPIKey")
        } catch let error as AIError {
            #expect(error == .invalidAPIKey)
        }
        #expect(server.requestCount == 2)
    }

    // MARK: - Error mapping

    @Test func errorMappingCoversEveryCase() async throws {
        var profile = openAIProfile()

        // 401 / 403 → invalidAPIKey
        for status in [401, 403] {
            let server = StubServer { request in
                .data(url: request.url!, status: status,
                      json: #"{"error":{"message":"nope"}}"#)
            }
            do {
                _ = try await client(profile: profile, server: server).complete(.text("x"))
                Issue.record("expected invalidAPIKey")
            } catch let error as AIError {
                #expect(error == .invalidAPIKey)
            }
        }

        // 404 → modelNotFound with the model name
        let notFound = StubServer { request in
            .data(url: request.url!, status: 404, json: #"{"error":{"message":"no model"}}"#)
        }
        do {
            _ = try await client(profile: profile, server: notFound).complete(.text("x"))
            Issue.record("expected modelNotFound")
        } catch let error as AIError {
            #expect(error == .modelNotFound("m-1"))
        }

        // 429 → rateLimited
        let limited = StubServer { request in
            .data(url: request.url!, status: 429, json: "{}")
        }
        do {
            _ = try await client(profile: profile, server: limited).complete(.text("x"))
            Issue.record("expected rateLimited")
        } catch let error as AIError {
            #expect(error == .rateLimited)
        }

        // 500 → provider with the provider's own message
        let broken = StubServer { request in
            .data(url: request.url!, status: 500,
                  json: #"{"error":{"message":"server exploded"}}"#)
        }
        do {
            _ = try await client(profile: profile, server: broken).complete(.text("x"))
            Issue.record("expected provider error")
        } catch let error as AIError {
            #expect(error == .provider(status: 500, message: "server exploded"))
        }

        // Anthropic error shape {error:{type,message}} also maps.
        let claudeError = StubServer { request in
            .data(url: request.url!, status: 500,
                  json: #"{"error":{"type":"api_error","message":"overloaded"}}"#)
        }
        do {
            _ = try await client(profile: anthropicProfile(), server: claudeError)
                .complete(.text("x"))
            Issue.record("expected provider error")
        } catch let error as AIError {
            #expect(error == .provider(status: 500, message: "overloaded"))
        }

        // Transport errors
        let timeout = StubServer { request in
            .transport(url: request.url!, code: .timedOut)
        }
        do {
            _ = try await client(profile: profile, server: timeout).complete(.text("x"))
            Issue.record("expected timeout")
        } catch let error as AIError {
            #expect(error == .timeout)
        }
        let offline = StubServer { request in
            .transport(url: request.url!, code: .notConnectedToInternet)
        }
        do {
            _ = try await client(profile: profile, server: offline).complete(.text("x"))
            Issue.record("expected offline")
        } catch let error as AIError {
            #expect(error == .offline)
        }

        // 200 with garbage → unreadableResponse
        let garbage = StubServer { request in
            .data(url: request.url!, json: "this is not json")
        }
        do {
            _ = try await client(profile: profile, server: garbage).complete(.text("x"))
            Issue.record("expected unreadableResponse")
        } catch let error as AIError {
            #expect(error == .unreadableResponse)
        }

        // Empty model → notConfigured before any request is sent.
        profile.model = "   "
        let unused = StubServer { _ in
            Issue.record("no request should be sent")
            return .data(url: URL(string: "https://api.test")!, json: "{}")
        }
        do {
            _ = try await client(profile: profile, server: unused).complete(.text("x"))
            Issue.record("expected notConfigured")
        } catch let error as AIError {
            #expect(error == .notConfigured)
        }
        #expect(unused.requestCount == 0)
    }

    // MARK: - testConnection + listModels

    @Test func testConnectionReturnsReplyAndLatency() async throws {
        let server = StubServer { request in
            .data(url: request.url!, json: self.openAIReplyJSON("OK"))
        }
        let result = try await client(profile: openAIProfile(), server: server)
            .testConnection()
        #expect(result.reply == "OK")
        #expect(result.latency >= 0)
    }

    @Test func listModelsOpenAI() async throws {
        let server = StubServer { request in
            .data(url: request.url!,
                  json: #"{"data":[{"id":"gpt-4o-mini"},{"id":"gpt-4o"}],"object":"list"}"#)
        }
        let ids = try await client(profile: openAIProfile(), server: server, key: "k-9")
            .listModels()
        #expect(ids == ["gpt-4o-mini", "gpt-4o"])
        let request = try #require(server.capturedRequests.first)
        #expect(request.url?.absoluteString == "https://api.test/v1/models")
        #expect(request.httpMethod == "GET")
        #expect(request.value(forHTTPHeaderField: "Authorization") == "Bearer k-9")
    }

    @Test func listModelsAnthropicUnsupported() async throws {
        let server = StubServer { _ in
            Issue.record("no request expected")
            return .data(url: URL(string: "https://x.test")!, json: "{}")
        }
        do {
            _ = try await client(profile: anthropicProfile(), server: server).listModels()
            Issue.record("expected modelListingUnsupported")
        } catch let error as AIError {
            #expect(error == .modelListingUnsupported)
        }
        #expect(server.requestCount == 0)
    }

    // MARK: - Finance context builder

    private func richSnapshot() -> AIFinanceSnapshot {
        var snapshot = AIFinanceSnapshot(
            periodLabel: "Tháng 11/2026", income: 45_000_000, expense: 32_500_000)
        snapshot.categories = [
            .init(name: "Ăn uống", kind: .expense, amount: 8_000_000),
            .init(name: "Nhà cửa", kind: .expense, amount: 6_000_000),
            .init(name: "Lương & thù lao", kind: .income, amount: 45_000_000),
        ]
        snapshot.businesses = [
            .init(name: "Căn hộ dịch vụ", income: 20_000_000, expense: 8_000_000),
        ]
        snapshot.accounts = [
            .init(name: "ACB x123", kind: .bank, balance: 30_000_000),
            .init(name: "Ví chính", kind: .cash, balance: 5_000_000),
            .init(name: "Thẻ Visa", kind: .creditCard, balance: -4_200_000),
        ]
        snapshot.budgets = [
            .init(name: "Ăn uống", spent: 8_000_000, limit: 10_000_000),
            .init(name: nil, spent: 32_500_000, limit: 45_000_000),
        ]
        snapshot.upcomingDues = [
            .init(title: "Tiền phòng T12",
                  date: day(2026, 12, 1), amount: 12_000_000),
        ]
        snapshot.recurring = [
            .init(name: "Netflix", amount: 260_000, scheduleLabel: "mỗi tháng"),
        ]
        snapshot.transactions = [
            .init(date: day(2026, 11, 20), signedAmount: -85_000,
                  categoryName: "Ăn uống", businessName: nil,
                  accountName: "ACB x123", note: "phở bò"),
            .init(date: day(2026, 11, 21), signedAmount: 20_000_000,
                  categoryName: "Tiền thuê phòng", businessName: "Căn hộ dịch vụ",
                  accountName: "ACB x123", note: nil),
        ]
        return snapshot
    }

    private func day(_ y: Int, _ m: Int, _ d: Int) -> Date {
        AppCalendar.vietnam.date(from: DateComponents(year: y, month: m, day: d))!
    }

    @Test func contextBuilderIncludesEverySection() {
        let context = AIFinanceContextBuilder.build(snapshot: richSnapshot())
        #expect(context.text.contains("Bối cảnh tài chính — Tháng 11/2026"))
        #expect(context.text.contains("Thu 45 tr"))
        #expect(context.text.contains("Chi 32,5 tr"))
        #expect(context.text.contains("Chi theo danh mục: Ăn uống 8 tr"))
        #expect(context.text.contains("Thu theo danh mục: Lương & thù lao 45 tr"))
        #expect(context.text.contains("Lãi lỗ theo mảng: Căn hộ dịch vụ lãi 12 tr"))
        #expect(context.text.contains("Tài khoản: ACB x123 (ngân hàng) +30 tr"))
        #expect(context.text.contains("Nợ & thẻ: Thẻ Visa còn nợ 4,2 tr"))
        #expect(context.text.contains("Ngân sách: Ăn uống 8 tr/10 tr (80%)"))
        #expect(context.text.contains("Chung 32,5 tr/45 tr"))
        #expect(context.text.contains("Sắp đến hạn: Tiền phòng T12 01/12 12 tr"))
        #expect(context.text.contains("Định kỳ: Netflix 260 k mỗi tháng"))
        #expect(context.text.contains("Giao dịch trong kỳ (2):"))
        #expect(context.includedTransactions == 2)
        #expect(context.omittedTransactions == 0)
        // outgoingText returns exactly what build() produced.
        #expect(AIFinanceContextBuilder.outgoingText(snapshot: richSnapshot())
            == context.text)
    }

    @Test func contextBuilderHonoursPrivacySwitches() {
        let snapshot = richSnapshot()
        let closed = AIFinanceContextBuilder.build(
            snapshot: snapshot,
            options: AIFinancePrivacyOptions(
                includeTransactions: true, includeNotes: false,
                includeAccountNames: false))
        // Real names are gone; kinds remain.
        #expect(!closed.text.contains("ACB x123"))
        #expect(closed.text.contains("Ngân hàng #1"))
        // Notes are off → "phở bò" never appears.
        #expect(!closed.text.contains("phở bò"))

        let notesOn = AIFinanceContextBuilder.build(
            snapshot: snapshot,
            options: AIFinancePrivacyOptions(
                includeTransactions: true, includeNotes: true,
                includeAccountNames: true))
        #expect(notesOn.text.contains("phở bò"))

        let noTransactions = AIFinanceContextBuilder.build(
            snapshot: snapshot,
            options: .minimal)
        #expect(!noTransactions.text.contains("Giao dịch trong kỳ"))
        #expect(!noTransactions.text.contains("phở bò"))
        #expect(!noTransactions.text.contains("ACB x123"))
    }

    @Test func contextBuilderTruncatesTransactionsFirstAndCountsOmitted() {
        var snapshot = AIFinanceSnapshot(
            periodLabel: "Tháng 11/2026", income: 0, expense: 0)
        snapshot.transactions = (1...60).map { i in
            .init(date: day(2026, 11, 1), signedAmount: -1000 * Int64(i),
                  categoryName: "Ăn uống", businessName: nil,
                  accountName: "ACB", note: nil)
        }
        let context = AIFinanceContextBuilder.build(
            snapshot: snapshot, characterBudget: 500)
        #expect(context.text.count <= 500)
        #expect(context.includedTransactions < 60)
        #expect(context.omittedTransactions == 60 - context.includedTransactions)
        #expect(context.text.contains("đã lược bớt \(context.omittedTransactions) giao dịch"))
    }

    @Test func contextBuilderHardTruncatesWhenHeadAloneExceedsBudget() {
        var snapshot = AIFinanceSnapshot(
            periodLabel: "Tháng 11/2026", income: 1, expense: 2)
        snapshot.categories = (1...30).map {
            .init(name: "Danh mục rất dài số \($0)", kind: .expense,
                  amount: 1_000_000)
        }
        let context = AIFinanceContextBuilder.build(
            snapshot: snapshot, characterBudget: 120)
        #expect(context.text.count <= 120)
        #expect(context.text.hasSuffix("…"))
    }

    // MARK: - Transaction extraction

    private func extractionTables() -> AITransactionExtraction.MatchTables {
        let eatID = UUID(uuidString: "AAAAAAAA-0000-4000-8000-000000000001")!
        let salaryID = UUID(uuidString: "AAAAAAAA-0000-4000-8000-000000000002")!
        let cashID = UUID(uuidString: "BBBBBBBB-0000-4000-8000-000000000001")!
        let bankID = UUID(uuidString: "BBBBBBBB-0000-4000-8000-000000000002")!
        let bizID = UUID(uuidString: "CCCCCCCC-0000-4000-8000-000000000001")!
        return .init(
            expenseCategories: AINameIndex([(id: eatID, name: "Ăn uống")]),
            incomeCategories: AINameIndex([(id: salaryID, name: "Lương & thù lao")]),
            accounts: AINameIndex([
                (id: cashID, name: "Tiền mặt"),
                (id: bankID, name: "ACB x123"),
            ]),
            businesses: AINameIndex([(id: bizID, name: "Căn hộ dịch vụ")])
        )
    }

    private var eatCategoryID: UUID {
        UUID(uuidString: "AAAAAAAA-0000-4000-8000-000000000001")!
    }
    private var cashAccountID: UUID {
        UUID(uuidString: "BBBBBBBB-0000-4000-8000-000000000001")!
    }
    private var bankAccountID: UUID {
        UUID(uuidString: "BBBBBBBB-0000-4000-8000-000000000002")!
    }
    private var businessID: UUID {
        UUID(uuidString: "CCCCCCCC-0000-4000-8000-000000000001")!
    }

    private let fixedNow = Date(timeIntervalSince1970: 1_800_000_000) // ~2027-01

    @Test func extractionParsesFencedJSON() throws {
        let text = """
        ```json
        {"items":[{"kind":"expense","amount":85000,"date":"2026-11-22",
        "note":"phở bò","category":"Ăn uống","account":"Tiền mặt",
        "toAccount":null,"business":null,"confidence":0.9}],"message":null}
        ```
        """
        let result = AITransactionExtraction.parse(
            text, tables: extractionTables(), now: fixedNow)
        #expect(result.rejections.isEmpty)
        let draft = try #require(result.drafts.first)
        #expect(draft.kind == .expense)
        #expect(draft.amount == 85_000)
        #expect(draft.categoryID == eatCategoryID)
        #expect(draft.accountID == cashAccountID)
        #expect(draft.confidence == 0.9)
        #expect(draft.note == "phở bò")
    }

    @Test func extractionParsesJSONWrappedInProse() {
        let text = """
        Dưới đây là kết quả trích xuất nhé anh:
        {"items":[{"kind":"income","amount":"2tr","date":"2026-11-20","note":"lương",
        "category":"Lương & thù lao","account":"ACB x123","confidence":0.8}]}
        Xong!
        """
        let result = AITransactionExtraction.parse(
            text, tables: extractionTables(), now: fixedNow)
        #expect(result.drafts.count == 1)
        #expect(result.drafts[0].kind == .income)
        #expect(result.drafts[0].amount == 2_000_000)
    }

    @Test func extractionHandlesVietnameseAmountShorthand() {
        // JSON array form is accepted too.
        let text = """
        [{"kind":"expense","amount":"85k","date":"2026-11-22"},
         {"kind":"expense","amount":"1tr2","date":"2026-11-22"},
         {"kind":"expense","amount":"2 củ","date":"2026-11-22"},
         {"kind":"expense","amount":"3 cành","date":"2026-11-22"},
         {"kind":"expense","amount":50000,"date":"2026-11-22"}]
        """
        let result = AITransactionExtraction.parse(
            text, tables: extractionTables(), now: fixedNow)
        #expect(result.rejections.isEmpty)
        #expect(result.drafts.map(\.amount)
            == [85_000, 1_200_000, 2_000_000, 3_000, 50_000])
    }

    @Test func extractionMatchesNamesLoosely() {
        // Case- and diacritic-insensitive name matching.
        let text = """
        {"items":[{"kind":"expense","amount":10000,"category":"an uong",
        "account":"tien mat","confidence":0.4}]}
        """
        let result = AITransactionExtraction.parse(
            text, tables: extractionTables(), now: fixedNow)
        #expect(result.drafts.first?.categoryID == eatCategoryID)
        #expect(result.drafts.first?.accountID == cashAccountID)
        #expect(result.drafts.first?.confidence == 0.4)
    }

    @Test func extractionFlagsUnknownNamesAndKeepsNil() throws {
        let text = """
        {"items":[{"kind":"expense","amount":10000,"category":"Tàu vũ trụ",
        "account":"Ví bí mật","business":"Công ty ma","confidence":0.9}]}
        """
        let result = AITransactionExtraction.parse(
            text, tables: extractionTables(), now: fixedNow)
        let draft = try #require(result.drafts.first)
        #expect(draft.categoryID == nil)
        #expect(draft.accountID == nil)
        #expect(draft.businessID == nil)
        #expect(draft.warnings.count == 3)
    }

    @Test func extractionClampsFarFutureDates() throws {
        let text = """
        {"items":[{"kind":"expense","amount":10000,"date":"2042-01-01"}]}
        """
        let result = AITransactionExtraction.parse(
            text, tables: extractionTables(), now: fixedNow)
        let draft = try #require(result.drafts.first)
        let upper = AppCalendar.vietnam.date(
            byAdding: .year, value: 1, to: fixedNow)!
        #expect(draft.date == upper)
        #expect(draft.warnings.isEmpty == false)
    }

    @Test func extractionRejectsNonPositiveAmounts() {
        let text = """
        {"items":[{"kind":"expense","amount":0,"date":"2026-11-22"},
                  {"kind":"expense","amount":-5000,"date":"2026-11-22"},
                  {"kind":"expense","amount":"không rõ","date":"2026-11-22"},
                  {"kind":"expense","amount":12000,"date":"2026-11-22"}]}
        """
        let result = AITransactionExtraction.parse(
            text, tables: extractionTables(), now: fixedNow)
        #expect(result.drafts.count == 1)
        #expect(result.drafts[0].amount == 12_000)
        #expect(result.rejections.count == 3)
        #expect(result.rejections.map(\.index) == [0, 1, 2])
        #expect(result.rejections[0].reason.contains("số tiền"))
    }

    @Test func extractionBuildsTransferWithDestination() throws {
        let text = """
        {"items":[{"kind":"transfer","amount":5000000,"date":"2026-11-22",
        "account":"Tiền mặt","toAccount":"ACB x123","confidence":0.95}]}
        """
        let result = AITransactionExtraction.parse(
            text, tables: extractionTables(), now: fixedNow)
        let draft = try #require(result.drafts.first)
        #expect(draft.kind == .transfer)
        #expect(draft.accountID == cashAccountID)
        #expect(draft.toAccountID == bankAccountID)
        #expect(draft.categoryID == nil)
    }

    @Test func extractionSurfacesMessageWhenNothingExtracted() {
        let text = #"{"items":[],"message":"Không đọc được hoá đơn — ảnh mờ quá."}"#
        let result = AITransactionExtraction.parse(
            text, tables: extractionTables(), now: fixedNow)
        #expect(result.drafts.isEmpty)
        #expect(result.message == "Không đọc được hoá đơn — ảnh mờ quá.")

        // No JSON at all → nil-result message.
        let empty = AITransactionExtraction.parse(
            "trả lời không có JSON", tables: extractionTables(), now: fixedNow)
        #expect(empty.drafts.isEmpty)
        #expect(empty.message != nil)
    }

    @Test func extractionPromptListsEverythingTheModelNeeds() {
        let prompt = AITransactionExtraction.systemPrompt(for: .init(
            now: fixedNow,
            expenseCategories: ["Ăn uống", "Đi chơi"],
            incomeCategories: ["Lương & thù lao"],
            accounts: [(name: "Tiền mặt", kind: .cash),
                       (name: "ACB x123", kind: .bank)],
            businesses: ["Căn hộ dịch vụ"]))
        #expect(prompt.contains("Asia/Ho_Chi_Minh"))
        #expect(prompt.contains("Ăn uống, Đi chơi"))
        #expect(prompt.contains("Lương & thù lao"))
        #expect(prompt.contains("Tiền mặt (Tiền mặt)"))
        #expect(prompt.contains("ACB x123 (Ngân hàng)"))
        #expect(prompt.contains("Căn hộ dịch vụ"))
        #expect(prompt.contains("85k"))
        #expect(prompt.contains("1tr2"))
        #expect(prompt.contains("2 củ"))
        #expect(prompt.contains("\"items\""))
    }

    // MARK: - Categorization

    @Test func categorizationPromptAndParse() {
        let eatID = eatCategoryID
        let bizID = businessID
        let expense = AINameIndex([(id: eatID, name: "Ăn uống")])
        let income = AINameIndex([(id: UUID(), name: "Thu khác")])
        let businesses = AINameIndex([(id: bizID, name: "Căn hộ dịch vụ")])

        let prompt = AICategorization.systemPrompt(
            expenseCategories: ["Ăn uống"],
            incomeCategories: ["Thu khác"],
            businesses: ["Căn hộ dịch vụ"])
        #expect(prompt.contains("Ăn uống"))
        #expect(prompt.contains("transfer"))
        #expect(prompt.contains("\"suggestions\""))

        // The user prompt embeds the rows as JSON.
        let rows = [AIBankRow(id: "t1", signedAmount: -50_000, note: "PHO BO")]
        #expect(AICategorization.userPrompt(rows: rows).contains("\"amount\":-50000"))

        let reply = """
        {"suggestions":[
          {"id":"t1","category":"Ăn uống","confidence":0.93},
          {"id":"t2","business":"căn hộ dịch vụ","confidence":0.7},
          {"id":"t3","transfer":true,"confidence":0.99},
          {"id":"tX","category":"Ăn uống","confidence":0.9},
          {"id":"t4","category":"Không tồn tại","confidence":0.5},
          {"id":"t5","confidence":0.1}
        ]}
        """
        let result = AICategorization.parse(
            reply,
            validIDs: ["t1", "t2", "t3", "t4", "t5"],
            expenseCategories: expense, incomeCategories: income,
            businesses: businesses)
        #expect(result["t1"]?.target == .category(eatID))
        #expect(result["t1"]?.confidence == 0.93)
        #expect(result["t2"]?.target == .business(bizID))
        #expect(result["t3"]?.target == .internalTransfer)
        // Unknown id, unknown name and "no choice" rows are ignored.
        #expect(result["tX"] == nil)
        #expect(result["t4"] == nil)
        #expect(result["t5"] == nil)
    }

    // MARK: - Image sizing

    @Test func imageSizingMath() {
        #expect(AIImagePreparer.targetSize(for: CGSize(width: 4000, height: 3000))
            == CGSize(width: 1600, height: 1200))
        #expect(AIImagePreparer.targetSize(for: CGSize(width: 3000, height: 4000))
            == CGSize(width: 1200, height: 1600))
        // Already small → unchanged.
        #expect(AIImagePreparer.targetSize(for: CGSize(width: 1000, height: 500))
            == CGSize(width: 1000, height: 500))
        #expect(AIImagePreparer.targetSize(for: CGSize(width: 1600, height: 1600))
            == CGSize(width: 1600, height: 1600))
        // Degenerate inputs → zero.
        #expect(AIImagePreparer.targetSize(for: .zero) == .zero)
        // Custom cap.
        #expect(AIImagePreparer.targetSize(
            for: CGSize(width: 800, height: 600), maxLongSide: 400)
            == CGSize(width: 400, height: 300))
    }

    @Test func imagePreparerCapsAtThreeAndProducesJPEG() {
        let renderer = UIGraphicsImageRenderer(size: CGSize(width: 20, height: 20))
        let image = renderer.image { _ in }
        let prepared = AIImagePreparer.prepareImages(
            [image, image, image, image])
        #expect(prepared.count == 3)
        // JPEG magic bytes.
        #expect(prepared[0].jpeg.prefix(2) == Data([0xFF, 0xD8]))
    }

    // MARK: - AM Router preset

    @Test func amRouterPresetFillsDraftButLeavesModelAndKeyOpen() {
        var draft = AIProfileDraft()
        draft.applyPreset(.amRouter)
        #expect(draft.name == "AM Router")
        #expect(draft.style == .openAICompatible)
        #expect(draft.baseURL == "https://provider.amx.vn/v1")
        #expect(draft.normalizedBaseURLString == "https://provider.amx.vn/v1")
        #expect(draft.baseURLError == nil)
        #expect(draft.supportsJSONMode)
        // Model, vision model and key stay empty until the user picks/types.
        #expect(draft.model.isEmpty)
        #expect(draft.visionModel.isEmpty)
        #expect(draft.apiKey.isEmpty)
        // Not yet valid — a model is still required to save.
        #expect(!draft.isValid)
        #expect(draft.matchingPreset == .amRouter)
    }

    @Test func amRouterPresetClearsFieldsCarriedOverFromAnotherProvider() {
        var draft = AIProfileDraft()
        draft.name = "OpenAI của tôi"
        draft.apiKey = "sk-third-party"
        draft.model = "gpt-4o"
        draft.visionModel = "gpt-4o"
        draft.extraHeaders = "X-Tenant: blue"
        draft.supportsJSONMode = false
        draft.applyPreset(.amRouter)
        // A key typed for another provider is wiped — it must never be
        // sent to the AM Router origin by tapping the preset.
        #expect(draft.apiKey.isEmpty)
        #expect(draft.model.isEmpty)
        #expect(draft.visionModel.isEmpty)
        #expect(draft.extraHeaders.isEmpty)
        #expect(draft.name == "AM Router")
        #expect(draft.supportsJSONMode)
    }

    @Test func styleChangeNeverOverwritesAMRouterPreset() {
        var draft = AIProfileDraft()
        draft.applyPreset(.amRouter)
        // The style picker's onChange hook calls applyStyleDefaults — it
        // may tune flags but must never retarget the gateway or rename.
        draft.style = .anthropic
        draft.applyStyleDefaults()
        #expect(draft.baseURL == "https://provider.amx.vn/v1")
        #expect(draft.name == "AM Router")
        #expect(draft.matchingPreset == nil)   // wrong style → no match
        draft.style = .openAICompatible
        draft.applyStyleDefaults()
        #expect(draft.baseURL == "https://provider.amx.vn/v1")
        #expect(draft.matchingPreset == .amRouter)
    }

    @Test func matchingPresetDetectsHandTypedGatewayURL() {
        var draft = AIProfileDraft()
        #expect(draft.matchingPreset == nil)
        // Scheme-less and trailing-slash spellings normalize to the same
        // gateway and count as the preset.
        draft.baseURL = "provider.amx.vn/v1/"
        #expect(draft.matchingPreset == .amRouter)
        draft.baseURL = "https://provider.amx.vn/v1"
        draft.style = .anthropic
        #expect(draft.matchingPreset == nil)
        draft.style = .openAICompatible
        draft.baseURL = "https://api.openai.com/v1"
        #expect(draft.matchingPreset == nil)
    }

    @Test func amRouterDraftLeavesNoSavedKeyReachable() throws {
        let keys = AIInMemoryAPIKeyStore()
        let (store, _, defaults, suite) = try makeStore(keys: keys)
        defer { defaults.removePersistentDomain(forName: suite) }

        // Another profile already saved with its own third-party key.
        let other = openAIProfile()
        store.save(other)
        try store.setAPIKey("sk-third-party", for: other.id)

        var draft = AIProfileDraft()
        draft.apiKey = "sk-third-party"   // typed before noticing the preset
        draft.applyPreset(.amRouter)
        #expect(draft.apiKey.isEmpty)
        #expect(!draft.hasSavedKey)
        // The new profile's id owns no key until the user types one; the
        // third-party key stays bound to its own profile.
        let saved = draft.makeProfile()
        #expect(try store.apiKey(for: saved.id) == nil)
        #expect(try store.apiKey(for: other.id) == "sk-third-party")
    }

    @Test func amRouterProfileUsesGatewayRoutesWithBearerKey() async throws {
        var draft = AIProfileDraft()
        draft.applyPreset(.amRouter)
        draft.model = "am-text-1"
        draft.apiKey = "amr-secret"
        let profile = draft.makeProfile()
        #expect(profile.isUsable)

        let server = StubServer { request in
            if request.url?.path.hasSuffix("/models") == true {
                return .data(url: request.url!, json:
                    #"{"data":[{"id":"am-vision-1"},{"id":"am-text-1"}],"object":"list"}"#)
            }
            return .data(url: request.url!, json: self.openAIReplyJSON("ok"))
        }
        let aiClient = client(profile: profile, server: server, key: "amr-secret")

        _ = try await aiClient.complete(.text("hi"))
        let completion = try #require(server.capturedRequests.first)
        #expect(completion.url?.absoluteString
            == "https://provider.amx.vn/v1/chat/completions")
        #expect(completion.value(forHTTPHeaderField: "Authorization")
            == "Bearer amr-secret")

        // The existing fetched-model picker is fed by GET /models on the
        // same gateway with the same bearer key.
        let ids = try await aiClient.listModels()
        #expect(ids == ["am-vision-1", "am-text-1"])
        let modelsRequest = try #require(server.capturedRequests.last)
        #expect(modelsRequest.url?.absoluteString
            == "https://provider.amx.vn/v1/models")
        #expect(modelsRequest.value(forHTTPHeaderField: "Authorization")
            == "Bearer amr-secret")
    }
}
