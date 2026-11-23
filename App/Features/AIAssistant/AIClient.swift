import Foundation

/// Extracts the first JSON value from free-form model output. Tolerant of
/// ```json code fences and surrounding prose — used by the parsers and by
/// every call that asked for JSON without provider-side JSON mode.
enum AIJSON {
    /// Returns the raw bytes of the first balanced `{…}` or `[…]` in `text`,
    /// honoring string literals and escapes. Code fences are stripped first.
    static func firstValueData(in text: String) -> Data? {
        var haystack = text
        if let open = haystack.range(of: "```") {
            let after = haystack[open.upperBound...]
            if let close = after.range(of: "```") {
                var inner = after[..<close.lowerBound]
                if let newline = inner.firstIndex(of: "\n") {
                    let firstLine = inner[..<newline]
                    if !firstLine.contains("{") && !firstLine.contains("[") {
                        inner = inner[inner.index(after: newline)...]
                    }
                }
                haystack = String(inner)
            }
        }
        guard let start = haystack.firstIndex(where: { $0 == "{" || $0 == "[" })
        else { return nil }

        var stack: [Character] = []
        var inString = false
        var escaped = false
        var index = start
        while index < haystack.endIndex {
            let ch = haystack[index]
            if inString {
                if escaped { escaped = false }
                else if ch == "\\" { escaped = true }
                else if ch == "\"" { inString = false }
            } else {
                switch ch {
                case "\"": inString = true
                case "{": stack.append("}")
                case "[": stack.append("]")
                case "}", "]":
                    guard stack.popLast() == ch else { return nil }
                    if stack.isEmpty {
                        return haystack[start...index].data(using: .utf8)
                    }
                default: break
                }
            }
            index = haystack.index(after: index)
        }
        return nil
    }
}

/// A JPEG image attached to a message — produced by `AIImagePreparer`.
struct AIRequestImage: Sendable, Equatable {
    var jpeg: Data
}

enum AIRole: String, Sendable, Codable {
    case system
    case user
    case assistant
}

/// One chat turn. `images` ride on user turns; both API styles accept them.
struct AIMessage: Sendable, Equatable {
    var role: AIRole
    var text: String
    var images: [AIRequestImage]

    init(role: AIRole = .user, text: String, images: [AIRequestImage] = []) {
        self.role = role
        self.text = text
        self.images = images
    }
}

/// What the caller wants: a system prompt, an ordered multi-turn message
/// list, and whether the reply should be machine-readable JSON.
struct AIRequest: Sendable, Equatable {
    var system: String?
    var messages: [AIMessage]
    /// Ask for strict JSON. Enforced provider-side only when the profile is
    /// OpenAI-compatible with "JSON mode" on; otherwise the reply is parsed
    /// through `AIJSON` (the prompts already demand strict JSON).
    var jsonMode: Bool

    init(system: String? = nil, messages: [AIMessage], jsonMode: Bool = false) {
        self.system = system
        self.messages = messages
        self.jsonMode = jsonMode
    }

    /// Single-turn convenience.
    static func text(
        _ prompt: String,
        system: String? = nil,
        images: [AIRequestImage] = [],
        jsonMode: Bool = false
    ) -> AIRequest {
        AIRequest(
            system: system,
            messages: [AIMessage(role: .user, text: prompt, images: images)],
            jsonMode: jsonMode
        )
    }
}

/// A completed (non-streamed) reply.
struct AIResponse: Sendable, Equatable {
    var text: String
    var model: String?
    var inputTokens: Int?
    var outputTokens: Int?
}

/// `testConnection()` outcome: what the provider replied and how long it took.
struct AIConnectionTest: Sendable, Equatable {
    var reply: String
    var latency: TimeInterval
}

/// Incremental server-sent-events parser: feed it arbitrary text chunks
/// (any boundary — the caller must not rely on `AsyncBytes.lines`, which
/// drops the blank lines SSE uses as event delimiters), get back one
/// `data:` payload per completed event. Multi-line `data:` fields join
/// with `\n`; `event:`/`id:`/`retry:` lines and `:` comments are ignored.
struct AISSEParser {
    private var pending = ""
    private var dataLines: [String] = []

    /// Buffers `chunk`, completes whole lines and returns the payload of
    /// every event closed by a blank line.
    mutating func feed(_ chunk: String) -> [String] {
        pending += chunk
        var events: [String] = []
        // Search scalars, not Characters: in "\r\n" the LF is part of one
        // grapheme and `firstIndex(of: "\n")` on Characters would miss it.
        while let newline = pending.unicodeScalars.firstIndex(of: "\n") {
            let line = pending[..<newline]
            pending = String(pending[pending.index(after: newline)...])
            if let payload = process(line) {
                events.append(payload)
            }
        }
        return events
    }

    /// Flushes an unterminated trailing line plus any open event.
    mutating func finish() -> [String] {
        var events: [String] = []
        if !pending.isEmpty {
            if let payload = process(pending[...]) { events.append(payload) }
            pending = ""
        }
        if !dataLines.isEmpty {
            events.append(dataLines.joined(separator: "\n"))
            dataLines.removeAll()
        }
        return events
    }

    /// One complete line (without the `\n`); returns the joined `data:`
    /// payload when a blank line closes an event.
    private mutating func process(_ raw: Substring) -> String? {
        var line = String(raw)
        if line.hasSuffix("\r") { line.removeLast() }
        if line.trimmingCharacters(in: .whitespaces).isEmpty {
            guard !dataLines.isEmpty else { return nil }
            defer { dataLines.removeAll() }
            return dataLines.joined(separator: "\n")
        }
        if line.hasPrefix(":") { return nil }
        if line.hasPrefix("data:") {
            var value = line.dropFirst(5)
            if value.hasPrefix(" ") { value = value.dropFirst() }
            dataLines.append(String(value))
        }
        return nil
    }
}

/// The HTTP client for one configured provider profile. Stateless and
/// `Sendable`; `URLSession` is injected so tests stub it with `URLProtocol`.
/// Nothing here ever logs — keys and request bodies stay off the console.
struct AIClient: Sendable {
    var profile: AIProviderProfile
    var apiKey: String
    var urlSession: URLSession

    init(
        profile: AIProviderProfile,
        apiKey: String,
        urlSession: URLSession = .shared
    ) {
        self.profile = profile
        self.apiKey = apiKey
        self.urlSession = urlSession
    }

    // MARK: - Public API

    /// One-shot completion: text plus optional images in, reply text out.
    func complete(_ request: AIRequest) async throws -> AIResponse {
        let urlRequest = try makeURLRequest(request, streaming: false)
        let (data, http) = try await perform(urlRequest)
        try throwIfFailed(http, data: data)
        return try decodeResponse(data)
    }

    /// Streams reply text deltas via server-sent events
    /// (`choices.delta.content` for OpenAI-style, `content_block_delta` for
    /// Anthropic). When the provider rejects the streaming request with a
    /// non-2xx status, falls back to `complete` and yields the whole reply.
    func stream(_ request: AIRequest) -> AsyncThrowingStream<String, Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    let urlRequest = try makeURLRequest(request, streaming: true)
                    let (bytes, http) = try await openStream(urlRequest)
                    guard (200..<300).contains(http.statusCode) else {
                        let response = try await complete(request)
                        if !response.text.isEmpty {
                            continuation.yield(response.text)
                        }
                        continuation.finish()
                        return
                    }
                    // AsyncBytes.lines drops blank lines — the SSE event
                    // delimiter — so feed the parser raw text at newline
                    // boundaries instead.
                    var parser = AISSEParser()
                    var pending = Data()
                    var done = false
                    for try await byte in bytes {
                        pending.append(byte)
                        guard byte == UInt8(ascii: "\n") else { continue }
                        if try dispatchStreamPayloads(
                            parser.feed(String(decoding: pending, as: UTF8.self)),
                            continuation: continuation) {
                            done = true
                            break
                        }
                        pending.removeAll(keepingCapacity: true)
                    }
                    if !done && !pending.isEmpty {
                        done = try dispatchStreamPayloads(
                            parser.feed(String(decoding: pending, as: UTF8.self)),
                            continuation: continuation)
                    }
                    if !done {
                        _ = try dispatchStreamPayloads(
                            parser.finish(), continuation: continuation)
                    }
                    continuation.finish()
                } catch is CancellationError {
                    continuation.finish(throwing: CancellationError())
                } catch {
                    continuation.finish(throwing: mapError(error))
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    /// Sends a tiny prompt and returns the reply and the round-trip latency.
    func testConnection() async throws -> AIConnectionTest {
        let start = Date.now
        let response = try await complete(
            .text("Hãy trả lời đúng một từ: OK"))
        return AIConnectionTest(
            reply: response.text.trimmingCharacters(in: .whitespacesAndNewlines),
            latency: Date.now.timeIntervalSince(start)
        )
    }

    /// `GET {baseURL}/models` — OpenAI-compatible providers only; throws
    /// `AIError.modelListingUnsupported` for Anthropic (callers tolerate it).
    func listModels() async throws -> [String] {
        guard profile.style == .openAICompatible else {
            throw AIError.modelListingUnsupported
        }
        let base = try AIBaseURL.normalize(profile.baseURL)
        var request = URLRequest(url: base.appendingPathComponent("models"))
        request.timeoutInterval = profile.clampedTimeout
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        for header in profile.parsedExtraHeaders {
            request.setValue(header.value, forHTTPHeaderField: header.name)
        }
        let (data, http) = try await perform(request)
        try throwIfFailed(http, data: data)
        guard let dict = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let items = dict["data"] as? [[String: Any]] else {
            throw AIError.unreadableResponse
        }
        return items.compactMap { $0["id"] as? String }
    }

    // MARK: - Request building

    /// The model for this request — the vision model when set and the
    /// request carries images.
    private func model(for request: AIRequest) throws -> String {
        let hasImages = request.messages.contains { !$0.images.isEmpty }
        let chosen = hasImages ? profile.effectiveVisionModel : profile.trimmedModel
        guard !chosen.isEmpty else { throw AIError.notConfigured }
        return chosen
    }

    private func makeURLRequest(_ request: AIRequest, streaming: Bool) throws -> URLRequest {
        let base = try AIBaseURL.normalize(profile.baseURL)
        let path = profile.style == .openAICompatible ? "chat/completions" : "messages"
        var urlRequest = URLRequest(url: base.appendingPathComponent(path))
        urlRequest.httpMethod = "POST"
        urlRequest.timeoutInterval = profile.clampedTimeout
        urlRequest.setValue("application/json", forHTTPHeaderField: "Content-Type")
        switch profile.style {
        case .openAICompatible:
            urlRequest.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        case .anthropic:
            urlRequest.setValue(apiKey, forHTTPHeaderField: "x-api-key")
            urlRequest.setValue("2023-06-01", forHTTPHeaderField: "anthropic-version")
        }
        // Extra headers last — a self-hosted gateway may legitimately need to
        // override e.g. anthropic-version.
        for header in profile.parsedExtraHeaders {
            urlRequest.setValue(header.value, forHTTPHeaderField: header.name)
        }
        urlRequest.httpBody = try JSONSerialization.data(
            withJSONObject: body(request, streaming: streaming))
        return urlRequest
    }

    private func body(_ request: AIRequest, streaming: Bool) throws -> [String: Any] {
        let model = try model(for: request)
        switch profile.style {
        case .openAICompatible:
            return openAIBody(request, model: model, streaming: streaming)
        case .anthropic:
            return anthropicBody(request, model: model, streaming: streaming)
        }
    }

    private func openAIBody(
        _ request: AIRequest, model: String, streaming: Bool
    ) -> [String: Any] {
        var messages: [[String: Any]] = []
        if let system = request.system, !system.isEmpty {
            messages.append(["role": "system", "content": system])
        }
        for message in request.messages {
            if message.role == .system {
                messages.append(["role": "system", "content": message.text])
                continue
            }
            if message.images.isEmpty {
                messages.append(["role": message.role.rawValue, "content": message.text])
            } else {
                var parts: [[String: Any]] = [["type": "text", "text": message.text]]
                for image in message.images {
                    parts.append([
                        "type": "image_url",
                        "image_url": [
                            "url": "data:image/jpeg;base64,\(image.jpeg.base64EncodedString())"
                        ],
                    ])
                }
                messages.append(["role": message.role.rawValue, "content": parts])
            }
        }
        var body: [String: Any] = [
            "model": model,
            "messages": messages,
            "temperature": profile.clampedTemperature,
            "max_tokens": profile.clampedMaxTokens,
        ]
        if streaming { body["stream"] = true }
        if request.jsonMode && profile.supportsJSONMode {
            body["response_format"] = ["type": "json_object"]
        }
        return body
    }

    private func anthropicBody(
        _ request: AIRequest, model: String, streaming: Bool
    ) -> [String: Any] {
        var systemParts: [String] = []
        if let system = request.system, !system.isEmpty {
            systemParts.append(system)
        }
        var messages: [[String: Any]] = []
        for message in request.messages {
            if message.role == .system {
                systemParts.append(message.text)
                continue
            }
            var blocks: [[String: Any]] = []
            for image in message.images {
                blocks.append([
                    "type": "image",
                    "source": [
                        "type": "base64",
                        "media_type": "image/jpeg",
                        "data": image.jpeg.base64EncodedString(),
                    ],
                ])
            }
            blocks.append(["type": "text", "text": message.text])
            messages.append(["role": message.role.rawValue, "content": blocks])
        }
        var body: [String: Any] = [
            "model": model,
            "max_tokens": profile.clampedMaxTokens,
            "temperature": profile.clampedTemperature,
            "messages": messages,
        ]
        if !systemParts.isEmpty {
            body["system"] = systemParts.joined(separator: "\n\n")
        }
        if streaming { body["stream"] = true }
        return body
    }

    // MARK: - Streaming internals

    private enum AIStreamEvent {
        case text(String)
        case done
        case ignored
    }

    private func openStream(
        _ request: URLRequest
    ) async throws -> (URLSession.AsyncBytes, HTTPURLResponse) {
        do {
            let (bytes, response) = try await urlSession.bytes(for: request)
            guard let http = response as? HTTPURLResponse else {
                throw AIError.unreadableResponse
            }
            return (bytes, http)
        } catch let error as AIError {
            throw error
        } catch {
            throw mapError(error)
        }
    }

    /// Yields every text delta in `payloads`; returns true once a
    /// terminator (`[DONE]` / `message_stop`) is seen so the caller stops
    /// reading.
    private func dispatchStreamPayloads(
        _ payloads: [String],
        continuation: AsyncThrowingStream<String, Error>.Continuation
    ) throws -> Bool {
        for payload in payloads {
            switch try streamEvent(payload) {
            case .text(let delta): continuation.yield(delta)
            case .done: return true
            case .ignored: break
            }
        }
        return false
    }

    /// Maps one SSE `data:` payload to a text delta, a terminator or noise.
    private func streamEvent(_ payload: String) throws -> AIStreamEvent {
        if payload.trimmingCharacters(in: .whitespaces) == "[DONE]" {
            return .done
        }
        guard let data = payload.data(using: .utf8),
              let dict = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { return .ignored }

        switch profile.style {
        case .openAICompatible:
            if let error = dict["error"] as? [String: Any] {
                throw AIError.provider(
                    status: 0, message: error["message"] as? String)
            }
            let choices = dict["choices"] as? [[String: Any]]
            let delta = choices?.first?["delta"] as? [String: Any]
            if let content = delta?["content"] as? String, !content.isEmpty {
                return .text(content)
            }
            return .ignored
        case .anthropic:
            let type = dict["type"] as? String
            if type == "error" {
                let error = dict["error"] as? [String: Any]
                throw AIError.provider(
                    status: 0, message: error?["message"] as? String)
            }
            if type == "message_stop" { return .done }
            if type == "content_block_delta",
               let delta = dict["delta"] as? [String: Any],
               delta["type"] as? String == "text_delta",
               let text = delta["text"] as? String, !text.isEmpty {
                return .text(text)
            }
            return .ignored
        }
    }

    // MARK: - Response handling

    private func perform(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        do {
            let (data, response) = try await urlSession.data(for: request)
            guard let http = response as? HTTPURLResponse else {
                throw AIError.unreadableResponse
            }
            return (data, http)
        } catch let error as AIError {
            throw error
        } catch {
            throw mapError(error)
        }
    }

    private func throwIfFailed(_ http: HTTPURLResponse, data: Data) throws {
        switch http.statusCode {
        case 200..<300:
            return
        case 401, 403:
            throw AIError.invalidAPIKey
        case 404:
            throw AIError.modelNotFound(profile.trimmedModel)
        case 429:
            throw AIError.rateLimited
        default:
            throw AIError.provider(
                status: http.statusCode, message: providerMessage(from: data))
        }
    }

    /// The provider's own error text: `{error:{message}}`, `{message}`,
    /// `{error:"…"}` or a short plain-text body.
    private func providerMessage(from data: Data) -> String? {
        guard let dict = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else {
            let text = String(data: data, encoding: .utf8)?
                .trimmingCharacters(in: .whitespacesAndNewlines)
            guard let text, !text.isEmpty, text.count < 300 else { return nil }
            return text
        }
        if let error = dict["error"] as? [String: Any],
           let message = error["message"] as? String { return message }
        if let message = dict["message"] as? String { return message }
        if let error = dict["error"] as? String { return error }
        return nil
    }

    private func decodeResponse(_ data: Data) throws -> AIResponse {
        guard let dict = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { throw AIError.unreadableResponse }
        let usage = dict["usage"] as? [String: Any]
        switch profile.style {
        case .openAICompatible:
            guard let choices = dict["choices"] as? [[String: Any]],
                  let message = choices.first?["message"] as? [String: Any]
            else { throw AIError.unreadableResponse }
            let text: String
            if let content = message["content"] as? String {
                text = content
            } else if let parts = message["content"] as? [[String: Any]] {
                text = parts.compactMap { $0["text"] as? String }.joined()
            } else {
                throw AIError.unreadableResponse
            }
            return AIResponse(
                text: text,
                model: dict["model"] as? String,
                inputTokens: (usage?["prompt_tokens"] as? NSNumber)?.intValue,
                outputTokens: (usage?["completion_tokens"] as? NSNumber)?.intValue
            )
        case .anthropic:
            guard let content = dict["content"] as? [[String: Any]]
            else { throw AIError.unreadableResponse }
            let text = content.compactMap {
                $0["type"] as? String == "text" ? $0["text"] as? String : nil
            }.joined()
            return AIResponse(
                text: text,
                model: dict["model"] as? String,
                inputTokens: (usage?["input_tokens"] as? NSNumber)?.intValue,
                outputTokens: (usage?["output_tokens"] as? NSNumber)?.intValue
            )
        }
    }

    /// Transport failures → typed errors; `AIError`s pass through untouched.
    private func mapError(_ error: Error) -> Error {
        if error is AIError { return error }
        if error is CancellationError { return error }
        guard let urlError = error as? URLError else {
            return AIError.network(error.localizedDescription)
        }
        switch urlError.code {
        case .cancelled:
            return CancellationError()
        case .timedOut:
            return AIError.timeout
        case .notConnectedToInternet, .networkConnectionLost,
             .dataNotAllowed, .internationalRoamingOff:
            return AIError.offline
        default:
            return AIError.network(urlError.localizedDescription)
        }
    }
}

/// The surface every AI feature screen calls. `AIClient` already
/// implements both methods; tests substitute a fake so no network is
/// involved.
protocol AIChatClientProtocol: Sendable {
    func complete(_ request: AIRequest) async throws -> AIResponse
    func stream(_ request: AIRequest) -> AsyncThrowingStream<String, Error>
}

extension AIClient: AIChatClientProtocol {}
