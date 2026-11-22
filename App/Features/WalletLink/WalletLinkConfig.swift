import Foundation

/// Connection settings for the owner's AMX servers — the OIDC login on
/// auth.amx.vn and the read-only wallet API on wallet.amx.vn. The client id
/// ("cli_…") is issued when the app is registered on the server, so it is
/// typed in on the connection screen and kept in UserDefaults. Tokens are
/// never stored here.
struct WalletLinkConfig: Equatable, Sendable {
    var authBaseURL: String
    var walletBaseURL: String
    var clientID: String

    static let `default` = WalletLinkConfig(
        authBaseURL: "https://auth.amx.vn",
        walletBaseURL: "https://wallet.amx.vn",
        clientID: ""
    )

    /// Redirect URI registered on the server — must match exactly.
    static let redirectURI = "vn.amx.finance://oauth/callback"
    /// Scheme `ASWebAuthenticationSession` listens on for the callback.
    static let callbackScheme = "vn.amx.finance"
    /// Scopes the server expects the app to request.
    static let scopes = "openid profile email offline_access"

    var trimmedClientID: String {
        clientID.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    var isConfigured: Bool { !trimmedClientID.isEmpty }

    /// Validates the typed values and produces a config with real URLs —
    /// what the networking layer consumes so it never sees a raw string.
    func resolved() throws -> Resolved {
        guard isConfigured else { throw WalletLinkConfigError.missingClientID }
        guard let auth = Self.httpsURL(from: authBaseURL) else {
            throw WalletLinkConfigError.invalidAuthBaseURL
        }
        guard let wallet = Self.httpsURL(from: walletBaseURL) else {
            throw WalletLinkConfigError.invalidWalletBaseURL
        }
        return Resolved(
            authBaseURL: auth, walletBaseURL: wallet, clientID: trimmedClientID)
    }

    private static func httpsURL(from string: String) -> URL? {
        let trimmed = string.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let url = URL(string: trimmed),
              url.scheme?.lowercased() == "https",
              url.host != nil else { return nil }
        return url
    }

    /// A `WalletLinkConfig` after validation — https URLs and a non-empty
    /// client id.
    struct Resolved: Equatable, Sendable {
        var authBaseURL: URL
        var walletBaseURL: URL
        var clientID: String
    }
}

/// Validation failures for `WalletLinkConfig.resolved()`. Descriptions are
/// Vietnamese — the settings screen shows them verbatim.
enum WalletLinkConfigError: LocalizedError, Equatable {
    case missingClientID
    case invalidAuthBaseURL
    case invalidWalletBaseURL

    var errorDescription: String? {
        switch self {
        case .missingClientID:
            return "Chưa nhập Client ID. Hãy nhập mã client do máy chủ cấp (dạng cli_…)."
        case .invalidAuthBaseURL:
            return "Địa chỉ máy chủ đăng nhập không hợp lệ — phải là URL https."
        case .invalidWalletBaseURL:
            return "Địa chỉ máy chủ ví không hợp lệ — phải là URL https."
        }
    }
}

/// UserDefaults persistence for `WalletLinkConfig` — only the client id and
/// the two base URLs. Tokens never live here. (`UserDefaults` is documented
/// thread-safe, hence `@unchecked Sendable`.)
final class WalletLinkConfigStore: @unchecked Sendable {
    static let clientIDKey = "walletLink.clientID"
    static let authBaseURLKey = "walletLink.authBaseURL"
    static let walletBaseURLKey = "walletLink.walletBaseURL"

    let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    func load() -> WalletLinkConfig {
        var config = WalletLinkConfig.default
        if let clientID = defaults.string(forKey: Self.clientIDKey) {
            config.clientID = clientID
        }
        if let auth = defaults.string(forKey: Self.authBaseURLKey), !auth.isEmpty {
            config.authBaseURL = auth
        }
        if let wallet = defaults.string(forKey: Self.walletBaseURLKey), !wallet.isEmpty {
            config.walletBaseURL = wallet
        }
        return config
    }

    func save(_ config: WalletLinkConfig) {
        defaults.set(config.clientID, forKey: Self.clientIDKey)
        defaults.set(config.authBaseURL, forKey: Self.authBaseURLKey)
        defaults.set(config.walletBaseURL, forKey: Self.walletBaseURLKey)
    }
}
