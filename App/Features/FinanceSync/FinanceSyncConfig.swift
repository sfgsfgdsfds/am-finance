import Foundation

/// Connection settings for the finance sync server — just the API base
/// URL today. Auth rides the existing WalletLink session (the server
/// accepts the same `auth.amx.vn` bearer tokens), so nothing else is
/// needed here.
struct FinanceSyncConfig: Equatable, Sendable {
    /// API base the endpoints hang under — every call hits
    /// `<baseURL>/v1/…`.
    var baseURL: String

    static let `default` = FinanceSyncConfig(
        baseURL: "https://finance.ledinhdai.com/api")

    /// Validates the base URL and produces the URL the client consumes.
    /// `http` is accepted so tests and a local dev server work; real
    /// deployments should keep the https default.
    func resolved() throws -> URL {
        let trimmed = baseURL.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let url = URL(string: trimmed),
              let scheme = url.scheme?.lowercased(),
              scheme == "https" || scheme == "http",
              url.host != nil
        else { throw FinanceSyncConfigError.invalidBaseURL }
        return url
    }
}

enum FinanceSyncConfigError: LocalizedError, Equatable {
    case invalidBaseURL

    var errorDescription: String? {
        switch self {
        case .invalidBaseURL:
            return "Địa chỉ máy chủ đồng bộ không hợp lệ — phải là URL http/https."
        }
    }
}

/// UserDefaults persistence for `FinanceSyncConfig` — the key exists so
/// tests (and later a settings field) can point the client elsewhere.
final class FinanceSyncConfigStore: @unchecked Sendable {
    static let baseURLKey = "financeSync.baseURL"

    let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    func load() -> FinanceSyncConfig {
        var config = FinanceSyncConfig.default
        if let baseURL = defaults.string(forKey: Self.baseURLKey), !baseURL.isEmpty {
            config.baseURL = baseURL
        }
        return config
    }

    func save(_ config: FinanceSyncConfig) {
        defaults.set(config.baseURL, forKey: Self.baseURLKey)
    }

    func reset() {
        defaults.removeObject(forKey: Self.baseURLKey)
    }
}
