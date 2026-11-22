import AuthenticationServices
import Foundation
import UIKit

/// Sign-in state shown on the connection screen.
enum WalletLinkStatus: Equatable, Sendable {
    case signedOut
    case signedIn(email: String?, subject: String?)

    /// Short Vietnamese label — "Đã đăng nhập: chu@amx.vn".
    var label: String {
        switch self {
        case .signedOut:
            return "Đã đăng xuất"
        case .signedIn(let email, let subject):
            if let name = email ?? subject {
                return "Đã đăng nhập: \(name)"
            }
            return "Đã đăng nhập"
        }
    }
}

/// `POST /oauth/token` and `POST /oauth/revoke` request builders — kept as
/// pure functions so tests can assert the exact form body.
enum WalletLinkTokenEndpoint {
    /// grant_type=authorization_code — swaps the callback code for tokens.
    static func exchangeRequest(
        config: WalletLinkConfig.Resolved, code: String, verifier: String
    ) -> URLRequest {
        formPost(baseURL: config.authBaseURL, path: "oauth/token", fields: [
            ("grant_type", "authorization_code"),
            ("client_id", config.clientID),
            ("code", code),
            ("redirect_uri", WalletLinkConfig.redirectURI),
            ("code_verifier", verifier),
        ])
    }

    /// grant_type=refresh_token — rotates the pair.
    static func refreshRequest(
        config: WalletLinkConfig.Resolved, refreshToken: String
    ) -> URLRequest {
        formPost(baseURL: config.authBaseURL, path: "oauth/token", fields: [
            ("grant_type", "refresh_token"),
            ("client_id", config.clientID),
            ("refresh_token", refreshToken),
        ])
    }

    /// RFC 7009 revocation — the public client authenticates with client_id.
    static func revokeRequest(
        config: WalletLinkConfig.Resolved, token: String
    ) -> URLRequest {
        formPost(baseURL: config.authBaseURL, path: "oauth/revoke", fields: [
            ("client_id", config.clientID),
            ("token", token),
            ("token_type_hint", "refresh_token"),
        ])
    }

    /// application/x-www-form-urlencoded body. Values are expected to be
    /// base64url/ASCII; the allowed set is the RFC 3986 unreserved range.
    static func formBody(_ fields: [(String, String)]) -> String {
        let allowed = CharacterSet(
            charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-._~")
        return fields
            .map { name, value in
                let n = name.addingPercentEncoding(withAllowedCharacters: allowed) ?? name
                let v = value.addingPercentEncoding(withAllowedCharacters: allowed) ?? value
                return "\(n)=\(v)"
            }
            .joined(separator: "&")
    }

    private static func formPost(
        baseURL: URL, path: String, fields: [(String, String)]
    ) -> URLRequest {
        var request = URLRequest(url: baseURL.appendingPathComponent(path))
        request.httpMethod = "POST"
        request.setValue(
            "application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        request.httpBody = Data(formBody(fields).utf8)
        return request
    }
}

/// JSON shape of `POST /oauth/token` on auth.amx.vn.
struct WalletLinkTokenResponse: Decodable, Equatable, Sendable {
    var accessToken: String
    var idToken: String?
    var refreshToken: String?
    var tokenType: String?
    var expiresIn: TimeInterval?
    var scope: String?

    /// Builds the stored snapshot — falls back to the previous refresh token
    /// when the server omits a new one.
    func tokens(now: Date, fallbackRefreshToken: String?) -> WalletLinkTokens {
        WalletLinkTokens(
            accessToken: accessToken,
            refreshToken: refreshToken ?? fallbackRefreshToken,
            expiresIn: expiresIn ?? 0,
            now: now
        )
    }
}

/// `{ "error": "…", "error_description": "…" }` — OAuth error bodies on both
/// the authorize redirect and the token endpoint.
struct WalletLinkOAuthError: Decodable, Equatable, Sendable {
    var error: String?
    var errorDescription: String?
}

/// Presents the auth.amx.vn login inside an `ASWebAuthenticationSession`.
/// `prefersEphemeralWebBrowserSession` stays off so a remembered login and
/// its cookies survive between sign-ins.
@MainActor
final class WalletLinkWebSession: NSObject, ASWebAuthenticationPresentationContextProviding {
    static let shared = WalletLinkWebSession()

    private var activeSession: ASWebAuthenticationSession?

    /// Runs the web login and resolves with the callback URL.
    func callbackURL(for authorizeURL: URL, scheme: String) async throws -> URL {
        try await withCheckedThrowingContinuation { continuation in
            let session = ASWebAuthenticationSession(
                url: authorizeURL,
                callbackURLScheme: scheme
            ) { [weak self] callbackURL, error in
                self?.activeSession = nil
                if let callbackURL {
                    continuation.resume(returning: callbackURL)
                } else {
                    continuation.resume(throwing: WalletLinkError(webSessionError: error))
                }
            }
            session.presentationContextProvider = self
            session.prefersEphemeralWebBrowserSession = false
            activeSession = session
            guard session.start() else {
                activeSession = nil
                continuation.resume(throwing: WalletLinkError.webSessionUnavailable)
                return
            }
        }
    }

    func presentationAnchor(
        for session: ASWebAuthenticationSession
    ) -> ASPresentationAnchor {
        let window = UIApplication.shared.connectedScenes
            .compactMap { $0 as? UIWindowScene }
            .filter { $0.activationState == .foregroundActive }
            .flatMap(\.windows)
            .first { $0.isKeyWindow }
        return window ?? ASPresentationAnchor()
    }
}

/// OAuth session against auth.amx.vn: web sign-in, strictly serialized
/// refresh-token rotation, best-effort revocation on sign-out. The server
/// config is re-read on every call so edits on the settings screen apply
/// immediately. Networking goes through the injected `URLSession`.
actor WalletLinkSession {
    private let configProvider: @Sendable () -> WalletLinkConfig
    private let store: any WalletLinkTokenStoring
    private let urlSession: URLSession

    private var cachedTokens: WalletLinkTokens?
    /// The single in-flight refresh — every other caller awaits this task.
    /// Reusing a rotated refresh token revokes the whole chain server-side,
    /// so there must never be two concurrent refreshes.
    private var inFlightRefresh: Task<WalletLinkTokens, Error>?

    init(
        configProvider: @escaping @Sendable () -> WalletLinkConfig,
        tokenStore: any WalletLinkTokenStoring,
        urlSession: URLSession
    ) {
        self.configProvider = configProvider
        self.store = tokenStore
        self.urlSession = urlSession
    }

    /// The app's shared session — config from standard UserDefaults, tokens
    /// in the Keychain, real networking.
    static let shared = WalletLinkSession.live()

    static func live(defaults: UserDefaults = .standard) -> WalletLinkSession {
        let configStore = WalletLinkConfigStore(defaults: defaults)
        return WalletLinkSession(
            configProvider: { configStore.load() },
            tokenStore: WalletLinkKeychainTokenStore(),
            urlSession: .shared
        )
    }

    /// Signed-in state for the settings screen; read from the cached/stored
    /// token set.
    var status: WalletLinkStatus {
        guard let tokens = currentTokens() else { return .signedOut }
        return .signedIn(email: tokens.email, subject: tokens.subject)
    }

    // MARK: - Sign in

    /// Full authorization-code + PKCE flow: web login, state-checked
    /// callback, code exchange, then the pair is persisted *before* use.
    @discardableResult
    func signIn() async throws -> WalletLinkTokens {
        let config = try configProvider().resolved()
        let verifier = WalletLinkPKCE.makeVerifier()
        let state = WalletLinkPKCE.makeState()
        let nonce = WalletLinkPKCE.makeNonce()

        guard let authorizeURL = WalletLinkAuthorizeRequest(
            authBaseURL: config.authBaseURL,
            clientID: config.clientID,
            state: state,
            nonce: nonce,
            codeChallenge: WalletLinkPKCE.challenge(for: verifier)
        ).url() else {
            throw WalletLinkError.invalidResponse
        }

        let callbackURL = try await WalletLinkWebSession.shared.callbackURL(
            for: authorizeURL, scheme: WalletLinkConfig.callbackScheme)
        let code = try WalletLinkAuthorizationCallback.code(
            from: callbackURL, expectedState: state)
        let tokens = try await exchange(code: code, verifier: verifier, config: config)

        try store.save(tokens)
        cachedTokens = tokens
        return tokens
    }

    private func exchange(
        code: String, verifier: String, config: WalletLinkConfig.Resolved
    ) async throws -> WalletLinkTokens {
        let request = WalletLinkTokenEndpoint.exchangeRequest(
            config: config, code: code, verifier: verifier)
        let response = try await sendTokenRequest(request)
        return response.tokens(now: .now, fallbackRefreshToken: nil)
    }

    // MARK: - Access token + refresh

    /// Access token with at least 60 seconds of life left — refreshes when
    /// shorter. Refreshes are strictly serialized through `inFlightRefresh`.
    func validAccessToken() async throws -> String {
        if let tokens = currentTokens(), tokens.remainingLifetime(at: .now) > 60 {
            return tokens.accessToken
        }
        return try await refreshedTokens().accessToken
    }

    /// Force-refresh used for the single retry after a 401, even when the
    /// local expiry still looks fine.
    func forceRefreshedAccessToken() async throws -> String {
        guard currentTokens() != nil else { throw WalletLinkError.notSignedIn }
        return try await refreshedTokens().accessToken
    }

    private func refreshedTokens() async throws -> WalletLinkTokens {
        if let inFlightRefresh {
            return try await inFlightRefresh.value
        }
        guard let tokens = currentTokens() else {
            throw WalletLinkError.notSignedIn
        }
        guard let refreshToken = tokens.refreshToken else {
            // Expired access token and nothing to rotate — session is dead.
            cachedTokens = nil
            try? store.clear()
            throw WalletLinkError.notSignedIn
        }
        let task = Task {
            try await performRefresh(tokens: tokens, refreshToken: refreshToken)
        }
        inFlightRefresh = task
        defer { inFlightRefresh = nil }
        return try await task.value
    }

    private func performRefresh(
        tokens: WalletLinkTokens, refreshToken: String
    ) async throws -> WalletLinkTokens {
        let config = try configProvider().resolved()
        let request = WalletLinkTokenEndpoint.refreshRequest(
            config: config, refreshToken: refreshToken)
        do {
            let response = try await sendTokenRequest(request)
            let newTokens = response.tokens(
                now: .now, fallbackRefreshToken: tokens.refreshToken)
            // The rotated pair is persisted before it is ever used — firing
            // a request with the old refresh token would revoke the chain.
            try store.save(newTokens)
            cachedTokens = newTokens
            return newTokens
        } catch let error as WalletLinkError {
            if error == .refreshDenied {
                cachedTokens = nil
                try? store.clear()
            }
            throw error
        }
    }

    // MARK: - Sign out

    /// Best-effort server-side revocation, then local cleanup. The store is
    /// cleared even when the network is down — signing out always works.
    func signOut() async {
        let refreshToken = currentTokens()?.refreshToken
        cachedTokens = nil
        try? store.clear()
        guard let refreshToken,
              let config = try? configProvider().resolved() else { return }
        let request = WalletLinkTokenEndpoint.revokeRequest(
            config: config, token: refreshToken)
        _ = try? await urlSession.data(for: request)
    }

    // MARK: - Internals

    private func currentTokens() -> WalletLinkTokens? {
        if let cachedTokens { return cachedTokens }
        guard let loaded = try? store.load() else { return nil }
        cachedTokens = loaded
        return loaded
    }

    private func sendTokenRequest(
        _ request: URLRequest
    ) async throws -> WalletLinkTokenResponse {
        let (data, http) = try await perform(request)
        if (200..<300).contains(http.statusCode) {
            guard let decoded = try? WalletLinkJSON.makeDecoder()
                .decode(WalletLinkTokenResponse.self, from: data),
                  !decoded.accessToken.isEmpty
            else { throw WalletLinkError.invalidResponse }
            return decoded
        }
        if let oauthError = try? WalletLinkJSON.makeDecoder()
            .decode(WalletLinkOAuthError.self, from: data),
           let code = oauthError.error, !code.isEmpty {
            if code == "invalid_grant" { throw WalletLinkError.refreshDenied }
            throw WalletLinkError.tokenRejected(
                code: code, detail: oauthError.errorDescription)
        }
        throw WalletLinkError.serverStatus(http.statusCode)
    }

    private func perform(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        do {
            let (data, response) = try await urlSession.data(for: request)
            guard let http = response as? HTTPURLResponse else {
                throw WalletLinkError.network
            }
            return (data, http)
        } catch let error as WalletLinkError {
            throw error
        } catch {
            throw WalletLinkError.network
        }
    }
}
