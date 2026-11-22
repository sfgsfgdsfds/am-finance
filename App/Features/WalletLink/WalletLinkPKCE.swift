import Foundation
import CryptoKit
import Security

/// Base64url (RFC 4648 §5) without padding — the alphabet shared by PKCE,
/// JWT payloads and OAuth parameters.
enum WalletLinkBase64 {
    static func encode(_ data: Data) -> String {
        data.base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }

    /// Accepts unpadded input and restores both the standard alphabet and
    /// the "=" padding `Data(base64Encoded:)` wants.
    static func decode(_ string: String) -> Data? {
        var base64 = string
            .replacingOccurrences(of: "-", with: "+")
            .replacingOccurrences(of: "_", with: "/")
        let remainder = base64.count % 4
        if remainder != 0 {
            base64 += String(repeating: "=", count: 4 - remainder)
        }
        return Data(base64Encoded: base64)
    }
}

/// PKCE (RFC 7636) plus the random `state`/`nonce` the authorize request
/// needs. Pure apart from the crypto RNG.
enum WalletLinkPKCE {
    /// 43-character verifier from 32 crypto-random bytes (RFC 7636 §4.1).
    static func makeVerifier() -> String {
        WalletLinkBase64.encode(randomBytes(32))
    }

    /// `BASE64URL-ENCODE(SHA256(verifier))`, no padding (RFC 7636 §4.2).
    static func challenge(for verifier: String) -> String {
        let digest = SHA256.hash(data: Data(verifier.utf8))
        return WalletLinkBase64.encode(Data(digest))
    }

    /// CSRF token sent on the authorize request and checked on the callback.
    static func makeState() -> String {
        WalletLinkBase64.encode(randomBytes(16))
    }

    /// Replay-protection nonce the server echoes inside the id_token.
    static func makeNonce() -> String {
        WalletLinkBase64.encode(randomBytes(16))
    }

    private static func randomBytes(_ count: Int) -> Data {
        var bytes = [UInt8](repeating: 0, count: count)
        _ = SecRandomCopyBytes(kSecRandomDefault, count, &bytes)
        return Data(bytes)
    }
}
