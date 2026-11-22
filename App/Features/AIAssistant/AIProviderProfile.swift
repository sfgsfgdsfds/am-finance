import Foundation

/// The wire protocol a provider speaks.
///
/// - `openAICompatible`: `POST {baseURL}/chat/completions` with an
///   `Authorization: Bearer <key>` header — used by OpenAI itself and most
///   self-hosted gateways (LiteLLM, Ollama, vLLM, OpenRouter…).
/// - `anthropic`: `POST {baseURL}/messages` with `x-api-key` and
///   `anthropic-version` headers.
enum AIAPIStyle: String, Codable, CaseIterable, Sendable {
    case openAICompatible
    case anthropic

    /// Vietnamese label for the UI.
    var displayName: String {
        switch self {
        case .openAICompatible: return "OpenAI tương thích"
        case .anthropic: return "Anthropic (Claude)"
        }
    }
}

/// Every failure the AI layer can report. `errorDescription` is Vietnamese —
/// settings and feature screens show it verbatim. Secrets never appear in
/// any message.
enum AIError: LocalizedError, Equatable {
    /// No usable profile: missing base URL, model or API key.
    case notConfigured
    /// The typed base URL is not a valid http/https URL.
    case invalidBaseURL
    /// http:// was typed for a public host — only localhost and private
    /// network addresses may skip TLS.
    case insecureBaseURL
    /// 401/403 — the key was rejected.
    case invalidAPIKey
    /// 404 — the model name does not exist at this provider.
    case modelNotFound(String)
    /// 429 — too many requests.
    case rateLimited
    /// Any other non-2xx status, with the provider's own message if any.
    case provider(status: Int, message: String?)
    /// `URLRequest.timeoutInterval` elapsed.
    case timeout
    /// No route to the network.
    case offline
    /// Other transport-level failure.
    case network(String)
    /// A 2xx body that did not match the expected shape.
    case unreadableResponse
    /// `listModels()` on a provider with no model-listing endpoint.
    case modelListingUnsupported
    /// One or more "Name: value" extra-header lines were malformed.
    case invalidExtraHeaders

    var errorDescription: String? {
        switch self {
        case .notConfigured:
            return "Chưa cấu hình AI — cần địa chỉ máy chủ, tên model và khoá API."
        case .invalidBaseURL:
            return "Địa chỉ máy chủ AI không hợp lệ — ví dụ https://api.openai.com/v1."
        case .insecureBaseURL:
            return "Chỉ chấp nhận http:// cho localhost hoặc địa chỉ mạng riêng (192.168.x.x, 10.x.x.x…) — vui lòng dùng https://."
        case .invalidAPIKey:
            return "Khoá API không hợp lệ hoặc đã hết hạn."
        case .modelNotFound(let model):
            return "Không tìm thấy model \"\(model)\" ở nhà cung cấp này."
        case .rateLimited:
            return "Nhà cung cấp AI đang giới hạn lượt gọi — thử lại sau ít phút."
        case .provider(let status, let message):
            let prefix = status > 0
                ? "Nhà cung cấp AI báo lỗi (\(status))" : "Nhà cung cấp AI báo lỗi"
            if let message, !message.isEmpty {
                return "\(prefix): \(message)"
            }
            return "\(prefix)."
        case .timeout:
            return "Yêu cầu AI quá thời gian chờ — tăng timeout hoặc thử lại."
        case .offline:
            return "Không có kết nối mạng."
        case .network(let detail):
            return "Không kết nối được máy chủ AI. \(detail)"
        case .unreadableResponse:
            return "Phản hồi từ nhà cung cấp AI không đọc được."
        case .modelListingUnsupported:
            return "Nhà cung cấp này không hỗ trợ liệt kê model — hãy nhập tên model thủ công."
        case .invalidExtraHeaders:
            return "Header bổ sung phải theo dạng \"Tên: giá trị\", mỗi dòng một header."
        }
    }
}

/// Validation and normalization for the user-typed provider base URL.
enum AIBaseURL {
    /// Turns what the user typed into the URL every request is built on:
    /// trims whitespace, auto-prepends `https://` when no scheme is given,
    /// requires a host and strips trailing slashes so
    /// `…/v1` + `/chat/completions` never double-slashes. `http://` is only
    /// accepted for localhost and private-network addresses.
    static func normalize(_ raw: String) throws -> URL {
        var trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { throw AIError.invalidBaseURL }
        if !trimmed.contains("://") {
            trimmed = "https://" + trimmed
        }
        guard let components = URLComponents(string: trimmed),
              let scheme = components.scheme?.lowercased(),
              scheme == "https" || scheme == "http",
              let host = components.host?.lowercased(),
              !host.isEmpty else {
            throw AIError.invalidBaseURL
        }
        if scheme == "http", !isPrivateHost(host) {
            throw AIError.insecureBaseURL
        }
        var path = components.percentEncodedPath
        while path.hasSuffix("/") { path.removeLast() }
        var rebuilt = components
        rebuilt.percentEncodedPath = path
        guard let url = rebuilt.url else { throw AIError.invalidBaseURL }
        return url
    }

    /// `true` when `host` is a loopback name/address or an RFC 1918 /
    /// link-local / ULA address — the only hosts allowed to use plain http.
    static func isPrivateHost(_ host: String) -> Bool {
        let name = host.lowercased()
        if name == "localhost" || name.hasSuffix(".localhost")
            || name.hasSuffix(".local") || name.hasSuffix(".lan")
            || name.hasSuffix(".internal") {
            return true
        }
        if name == "::1" || name == "[::1]" { return true }
        if name.hasPrefix("fe80:") || name.hasPrefix("fc") || name.hasPrefix("fd") {
            // fe80::/10 link-local and fc00::/7 unique-local (fc…, fd…).
            return name.contains(":")
        }
        let parts = name.split(separator: ".", omittingEmptySubsequences: false)
        guard parts.count == 4,
              let first = UInt8(parts[0]),
              let second = UInt8(parts[1]),
              UInt8(parts[2]) != nil, UInt8(parts[3]) != nil else {
            return false
        }
        switch first {
        case 127, 10: return true                    // loopback, private A
        case 192: return second == 168               // 192.168.0.0/16
        case 172: return (16...31).contains(second)  // 172.16.0.0/12
        case 169: return second == 254               // link-local
        default: return false
        }
    }
}

/// Extra request headers typed one "Name: value" per line. Blank lines are
/// skipped; a malformed line fails the whole parse so a typo never silently
/// sends a wrong header.
enum AIExtraHeaders {
    /// Parses the multiline text into `(name, value)` pairs preserving order.
    static func parse(_ text: String) throws -> [(name: String, value: String)] {
        var result: [(name: String, value: String)] = []
        for rawLine in text.components(separatedBy: .newlines) {
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            if line.isEmpty { continue }
            guard let colon = line.firstIndex(of: ":") else {
                throw AIError.invalidExtraHeaders
            }
            let name = String(line[..<colon]).trimmingCharacters(in: .whitespaces)
            let value = String(line[line.index(after: colon)...])
                .trimmingCharacters(in: .whitespaces)
            guard isValidName(name), !value.isEmpty else {
                throw AIError.invalidExtraHeaders
            }
            result.append((name: name, value: value))
        }
        return result
    }

    /// RFC 7230 token characters — valid HTTP field names.
    static func isValidName(_ name: String) -> Bool {
        guard !name.isEmpty else { return false }
        return name.allSatisfy { ch in
            ch.isASCII && (ch.isLetter || ch.isNumber
                || "!#$%&'*+-.^_`|~".contains(ch))
        }
    }
}

/// One saved AI provider configuration. The API key is NOT here — it lives
/// in the Keychain (`AIAPIKeyStoring`) under this profile's `id`.
struct AIProviderProfile: Codable, Equatable, Identifiable, Sendable {
    var id: UUID = UUID()
    var name: String = ""
    var styleRaw: String = AIAPIStyle.openAICompatible.rawValue
    /// The user-typed base URL — normalize through `AIBaseURL` before use.
    var baseURL: String = ""
    var model: String = ""
    /// Optional model used instead of `model` when the request has images.
    var visionModel: String = ""
    /// Extra headers as raw "Name: value" lines (see `AIExtraHeaders`).
    var extraHeaders: String = ""
    var temperature: Double = 0.2
    var maxTokens: Int = 2000
    var timeout: TimeInterval = 60
    var supportsJSONMode: Bool = true
    var createdAt: Date = Date.now

    init(
        id: UUID = UUID(),
        name: String,
        style: AIAPIStyle = .openAICompatible,
        baseURL: String,
        model: String,
        visionModel: String = "",
        extraHeaders: String = "",
        temperature: Double = 0.2,
        maxTokens: Int = 2000,
        timeout: TimeInterval = 60,
        supportsJSONMode: Bool = true,
        createdAt: Date = Date.now
    ) {
        self.id = id
        self.name = name
        self.styleRaw = style.rawValue
        self.baseURL = baseURL
        self.model = model
        self.visionModel = visionModel
        self.extraHeaders = extraHeaders
        self.temperature = temperature
        self.maxTokens = maxTokens
        self.timeout = timeout
        self.supportsJSONMode = supportsJSONMode
        self.createdAt = createdAt
    }

    var style: AIAPIStyle {
        get { AIAPIStyle(rawValue: styleRaw) ?? .openAICompatible }
        set { styleRaw = newValue.rawValue }
    }

    /// The model to call for a request that carries images.
    var effectiveVisionModel: String {
        let vision = visionModel.trimmingCharacters(in: .whitespacesAndNewlines)
        return vision.isEmpty ? model : vision
    }

    var trimmedModel: String {
        model.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// True when every non-secret field needed to send a request is present.
    var isUsable: Bool {
        !trimmedModel.isEmpty && (try? AIBaseURL.normalize(baseURL)) != nil
    }

    /// Anthropic always requires `max_tokens`; OpenAI-style only receives it
    /// when positive — kept simple by always sending the configured cap.
    var clampedMaxTokens: Int {
        max(1, min(maxTokens, 200_000))
    }

    var clampedTemperature: Double {
        min(max(temperature, 0), 2)
    }

    var clampedTimeout: TimeInterval {
        max(5, min(timeout, 600))
    }

    /// Parsed extra headers — an empty string parses to an empty list.
    var parsedExtraHeaders: [(name: String, value: String)] {
        (try? AIExtraHeaders.parse(extraHeaders)) ?? []
    }
}

/// Editable form state for `AIProfileEditView` — pure value type so the
/// validation rules are unit-testable without a view.
struct AIProfileDraft: Equatable, Sendable {
    var name = ""
    var style: AIAPIStyle = .openAICompatible
    var baseURL = ""
    /// Only ever holds what the user typed this session — never the saved key.
    var apiKey = ""
    /// Whether a key is already stored for the profile being edited.
    var hasSavedKey = false
    var model = ""
    var visionModel = ""
    var extraHeaders = ""
    var temperature = 0.2
    var maxTokens = 2000
    var timeout = 60.0
    var supportsJSONMode = true

    init() {}

    init(profile: AIProviderProfile, hasSavedKey: Bool) {
        name = profile.name
        style = profile.style
        baseURL = profile.baseURL
        self.hasSavedKey = hasSavedKey
        model = profile.model
        visionModel = profile.visionModel
        extraHeaders = profile.extraHeaders
        temperature = profile.temperature
        maxTokens = profile.maxTokens
        timeout = profile.timeout
        supportsJSONMode = profile.supportsJSONMode
    }

    /// Sensible defaults when the user picks an API style.
    mutating func applyStyleDefaults() {
        switch style {
        case .openAICompatible:
            if baseURL.isEmpty { baseURL = "https://api.openai.com/v1" }
            supportsJSONMode = true
        case .anthropic:
            if baseURL.isEmpty { baseURL = "https://api.anthropic.com/v1" }
            supportsJSONMode = false
        }
    }

    /// The validation error for the current base-URL text, if any — the form
    /// footer shows this (or the normalized URL when valid).
    var baseURLError: AIError? {
        do {
            _ = try AIBaseURL.normalize(baseURL)
            return nil
        } catch let error as AIError {
            return error
        } catch {
            return .invalidBaseURL
        }
    }

    /// The normalized URL preview shown under the field.
    var normalizedBaseURLString: String? {
        try? AIBaseURL.normalize(baseURL).absoluteString
    }

    var extraHeadersValid: Bool {
        (try? AIExtraHeaders.parse(extraHeaders)) != nil
    }

    var isValid: Bool {
        !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && !model.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && baseURLError == nil
            && extraHeadersValid
            && maxTokens > 0
            && timeout >= 5
    }

    func makeProfile(id: UUID = UUID(), createdAt: Date = .now) -> AIProviderProfile {
        AIProviderProfile(
            id: id,
            name: name.trimmingCharacters(in: .whitespacesAndNewlines),
            style: style,
            baseURL: baseURL.trimmingCharacters(in: .whitespacesAndNewlines),
            model: model.trimmingCharacters(in: .whitespacesAndNewlines),
            visionModel: visionModel.trimmingCharacters(in: .whitespacesAndNewlines),
            extraHeaders: extraHeaders,
            temperature: temperature,
            maxTokens: maxTokens,
            timeout: timeout,
            supportsJSONMode: supportsJSONMode,
            createdAt: createdAt
        )
    }
}
