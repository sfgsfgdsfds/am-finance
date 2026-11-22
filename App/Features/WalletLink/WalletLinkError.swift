import AuthenticationServices
import Foundation

/// Failures of the sign-in and token lifecycle against auth.amx.vn.
/// `errorDescription` is Vietnamese — the settings screen shows it verbatim.
enum WalletLinkError: LocalizedError, Equatable {
    /// The user dismissed the web login sheet.
    case signInCancelled
    /// `ASWebAuthenticationSession.start()` reported failure.
    case webSessionUnavailable
    /// The callback `state` does not match the one sent — possible CSRF.
    case stateMismatch
    /// The authorize redirect carried `error`/`error_description`.
    case authorizationDenied(code: String, detail: String?)
    /// The callback had neither a usable `code` nor an `error`.
    case missingAuthCode
    /// `POST /oauth/token` answered an OAuth error other than invalid_grant.
    case tokenRejected(code: String, detail: String?)
    /// `invalid_grant` — the refresh chain is dead, sign in again.
    case refreshDenied
    /// No usable tokens in the store.
    case notSignedIn
    /// A non-OAuth HTTP status from the auth server.
    case serverStatus(Int)
    /// Transport-level failure (offline, DNS, TLS…).
    case network
    /// A 2xx answer that did not decode into the expected shape.
    case invalidResponse

    var errorDescription: String? {
        switch self {
        case .signInCancelled:
            return "Đã huỷ đăng nhập."
        case .webSessionUnavailable:
            return "Không mở được màn hình đăng nhập."
        case .stateMismatch:
            return "Phản hồi đăng nhập không hợp lệ (state không khớp)."
        case .authorizationDenied(let code, let detail):
            if let detail, !detail.isEmpty {
                return "Máy chủ từ chối đăng nhập: \(code) — \(detail)"
            }
            return "Máy chủ từ chối đăng nhập: \(code)."
        case .missingAuthCode:
            return "Phản hồi đăng nhập thiếu mã xác thực."
        case .tokenRejected(let code, let detail):
            if let detail, !detail.isEmpty {
                return "Không lấy được phiên đăng nhập: \(code) — \(detail)"
            }
            return "Không lấy được phiên đăng nhập: \(code)."
        case .refreshDenied, .notSignedIn:
            return "Phiên đăng nhập đã hết hạn. Hãy đăng nhập lại."
        case .serverStatus(let status):
            return "Máy chủ đăng nhập trả về lỗi (HTTP \(status))."
        case .network:
            return "Không kết nối được máy chủ đăng nhập. Kiểm tra mạng."
        case .invalidResponse:
            return "Phản hồi của máy chủ đăng nhập không đúng định dạng."
        }
    }
}

extension WalletLinkError {
    /// Maps an `ASWebAuthenticationSession` completion error — user cancel
    /// becomes `signInCancelled`, everything else is a network failure.
    init(webSessionError error: Error?) {
        guard let error else {
            self = .invalidResponse
            return
        }
        if let sessionError = error as? ASWebAuthenticationSessionError,
           sessionError.code == .canceledLogin {
            self = .signInCancelled
            return
        }
        self = .network
    }
}
