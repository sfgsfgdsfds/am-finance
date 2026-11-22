import Foundation
import Security

/// The OAuth token set plus the identity decoded from the access token —
/// one snapshot, persisted as a single Keychain item. `email`/`subject` come
/// from the JWT payload (decode only, no signature check — the token arrives
/// over TLS straight from the issuer).
struct WalletLinkTokens: Codable, Equatable, Sendable {
    var accessToken: String
    var refreshToken: String?
    var accessTokenExpiry: Date
    var email: String?
    var subject: String?

    init(
        accessToken: String,
        refreshToken: String?,
        accessTokenExpiry: Date,
        email: String?,
        subject: String?
    ) {
        self.accessToken = accessToken
        self.refreshToken = refreshToken
        self.accessTokenExpiry = accessTokenExpiry
        self.email = email
        self.subject = subject
    }

    /// Convenience for a fresh token response: expiry = `now + expiresIn`,
    /// identity pulled out of the access-token JWT.
    init(accessToken: String, refreshToken: String?, expiresIn: TimeInterval, now: Date) {
        let payload = WalletLinkJWT.payload(of: accessToken)
        self.init(
            accessToken: accessToken,
            refreshToken: refreshToken,
            accessTokenExpiry: now.addingTimeInterval(expiresIn),
            email: payload?.email,
            subject: payload?.subject
        )
    }

    /// Seconds of access-token life left at `date`; negative means expired.
    func remainingLifetime(at date: Date) -> TimeInterval {
        accessTokenExpiry.timeIntervalSince(date)
    }
}

/// Reads the payload segment of a `header.payload.signature` JWT. Decode
/// only — the signature is intentionally not verified.
enum WalletLinkJWT {
    struct Payload: Equatable, Sendable {
        var subject: String?
        var email: String?
        var expiry: Date?
    }

    static func payload(of jwt: String) -> Payload? {
        let segments = jwt.split(separator: ".", omittingEmptySubsequences: false)
        guard segments.count == 3,
              let data = WalletLinkBase64.decode(String(segments[1])),
              let object = try? JSONSerialization.jsonObject(with: data),
              let dict = object as? [String: Any] else { return nil }

        var expiry: Date?
        if let exp = dict["exp"] as? NSNumber {
            expiry = Date(timeIntervalSince1970: exp.doubleValue)
        }
        return Payload(
            subject: dict["sub"] as? String,
            email: dict["email"] as? String,
            expiry: expiry
        )
    }
}

/// Storage seam for the token set — Keychain in the app, in-memory in tests
/// and previews.
protocol WalletLinkTokenStoring: Sendable {
    func load() throws -> WalletLinkTokens?
    func save(_ tokens: WalletLinkTokens) throws
    func clear() throws
}

enum WalletLinkTokenStoreError: LocalizedError, Equatable {
    case keychain(OSStatus)

    var errorDescription: String? {
        switch self {
        case .keychain(let status):
            return "Không đọc/ghi được khoá đăng nhập (Keychain \(status))."
        }
    }
}

/// Keychain generic-password store holding the whole token set as one JSON
/// blob. `AfterFirstUnlockThisDeviceOnly`: readable once the phone has been
/// unlocked, never leaves this device via backups or Keychain sync.
struct WalletLinkKeychainTokenStore: WalletLinkTokenStoring {
    private let service = "vn.amx.finance.wallet-link"
    private let account = "oauth-tokens"

    init() {}

    private var baseQuery: [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
    }

    func load() throws -> WalletLinkTokens? {
        var query = baseQuery
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        switch status {
        case errSecSuccess:
            guard let data = item as? Data,
                  let tokens = try? JSONDecoder().decode(WalletLinkTokens.self, from: data)
            else { throw WalletLinkTokenStoreError.keychain(errSecDecode) }
            return tokens
        case errSecItemNotFound:
            return nil
        default:
            throw WalletLinkTokenStoreError.keychain(status)
        }
    }

    func save(_ tokens: WalletLinkTokens) throws {
        let data = try JSONEncoder().encode(tokens)
        var attributes = baseQuery
        attributes[kSecValueData as String] = data
        attributes[kSecAttrAccessible as String] =
            kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly

        let status = SecItemAdd(attributes as CFDictionary, nil)
        if status == errSecDuplicateItem {
            let update = [kSecValueData as String: data]
            let updateStatus = SecItemUpdate(
                baseQuery as CFDictionary, update as CFDictionary)
            guard updateStatus == errSecSuccess else {
                throw WalletLinkTokenStoreError.keychain(updateStatus)
            }
        } else if status != errSecSuccess {
            throw WalletLinkTokenStoreError.keychain(status)
        }
    }

    func clear() throws {
        let status = SecItemDelete(baseQuery as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw WalletLinkTokenStoreError.keychain(status)
        }
    }
}

/// Volatile `WalletLinkTokenStoring` for tests and previews.
final class WalletLinkInMemoryTokenStore: WalletLinkTokenStoring, @unchecked Sendable {
    private let lock = NSLock()
    private var stored: WalletLinkTokens?

    init(stored: WalletLinkTokens? = nil) {
        self.stored = stored
    }

    func load() -> WalletLinkTokens? {
        lock.lock()
        defer { lock.unlock() }
        return stored
    }

    func save(_ tokens: WalletLinkTokens) {
        lock.lock()
        stored = tokens
        lock.unlock()
    }

    func clear() {
        lock.lock()
        stored = nil
        lock.unlock()
    }
}
