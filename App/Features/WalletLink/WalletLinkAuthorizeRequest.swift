import Foundation

/// Builds `GET <auth>/oauth/authorize?…` for the OIDC authorization-code
/// flow. Endpoint paths are hard-coded per the server; only the base URL is
/// configurable. Pure value type — the produced URL is fully testable.
struct WalletLinkAuthorizeRequest: Equatable, Sendable {
    var authBaseURL: URL
    var clientID: String
    var state: String
    var nonce: String
    var codeChallenge: String

    func url() -> URL? {
        var components = URLComponents(
            url: authBaseURL.appendingPathComponent("oauth/authorize"),
            resolvingAgainstBaseURL: false
        )
        components?.queryItems = [
            URLQueryItem(name: "response_type", value: "code"),
            URLQueryItem(name: "client_id", value: clientID),
            URLQueryItem(name: "redirect_uri", value: WalletLinkConfig.redirectURI),
            URLQueryItem(name: "scope", value: WalletLinkConfig.scopes),
            URLQueryItem(name: "state", value: state),
            URLQueryItem(name: "nonce", value: nonce),
            URLQueryItem(name: "code_challenge", value: codeChallenge),
            URLQueryItem(name: "code_challenge_method", value: "S256"),
        ]
        return components?.url
    }
}

/// Parses the `vn.amx.finance://oauth/callback?…` redirect the web session
/// returns: verifies `state`, surfaces `error`/`error_description`, and
/// extracts the authorization `code`.
enum WalletLinkAuthorizationCallback {
    static func code(from url: URL, expectedState: String) throws -> String {
        guard url.scheme?.lowercased() == WalletLinkConfig.callbackScheme else {
            throw WalletLinkError.missingAuthCode
        }
        let items = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? []
        func value(_ name: String) -> String? {
            items.first { $0.name == name }?.value
        }

        // State is verified before anything else is trusted.
        guard value("state") == expectedState else {
            throw WalletLinkError.stateMismatch
        }
        if let error = value("error"), !error.isEmpty {
            throw WalletLinkError.authorizationDenied(
                code: error, detail: value("error_description"))
        }
        guard let code = value("code"), !code.isEmpty else {
            throw WalletLinkError.missingAuthCode
        }
        return code
    }
}
