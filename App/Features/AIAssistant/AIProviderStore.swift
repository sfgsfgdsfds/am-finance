import Foundation
import Security

/// Storage seam for provider API keys — Keychain in the app, in-memory in
/// tests and previews. `nil` from `key(for:)` means "no key saved".
protocol AIAPIKeyStoring: Sendable {
    /// The stored key for `profileID`, or nil.
    func key(for profileID: UUID) throws -> String?
    /// Saves `key`; pass nil to delete.
    func setKey(_ key: String?, for profileID: UUID) throws
}

enum AIKeyStoreError: LocalizedError, Equatable {
    case keychain(OSStatus)

    var errorDescription: String? {
        switch self {
        case .keychain(let status):
            return "Không đọc/ghi được khoá API (Keychain \(status))."
        }
    }
}

/// Keychain generic-password store, one item per profile id. Service
/// `vn.amx.finance.ai`, `AfterFirstUnlockThisDeviceOnly`: readable once the
/// phone has been unlocked, never leaves this device via backups or sync.
struct AIKeychainAPIKeyStore: AIAPIKeyStoring {
    private let service = "vn.amx.finance.ai"

    init() {}

    private func query(for profileID: UUID) -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: profileID.uuidString,
        ]
    }

    func key(for profileID: UUID) throws -> String? {
        var query = query(for: profileID)
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        switch status {
        case errSecSuccess:
            guard let data = item as? Data, let key = String(data: data, encoding: .utf8)
            else { throw AIKeyStoreError.keychain(errSecDecode) }
            return key
        case errSecItemNotFound:
            return nil
        default:
            throw AIKeyStoreError.keychain(status)
        }
    }

    func setKey(_ key: String?, for profileID: UUID) throws {
        guard let key, !key.isEmpty else {
            let status = SecItemDelete(query(for: profileID) as CFDictionary)
            guard status == errSecSuccess || status == errSecItemNotFound else {
                throw AIKeyStoreError.keychain(status)
            }
            return
        }
        let data = Data(key.utf8)
        var attributes = query(for: profileID)
        attributes[kSecValueData as String] = data
        attributes[kSecAttrAccessible as String] =
            kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly

        let status = SecItemAdd(attributes as CFDictionary, nil)
        if status == errSecDuplicateItem {
            let update = [kSecValueData as String: data]
            let updateStatus = SecItemUpdate(
                query(for: profileID) as CFDictionary, update as CFDictionary)
            guard updateStatus == errSecSuccess else {
                throw AIKeyStoreError.keychain(updateStatus)
            }
        } else if status != errSecSuccess {
            throw AIKeyStoreError.keychain(status)
        }
    }
}

/// Volatile `AIAPIKeyStoring` for tests and previews.
final class AIInMemoryAPIKeyStore: AIAPIKeyStoring, @unchecked Sendable {
    private let lock = NSLock()
    private var keys: [UUID: String] = [:]

    init(keys: [UUID: String] = [:]) {
        self.keys = keys
    }

    func key(for profileID: UUID) -> String? {
        lock.lock()
        defer { lock.unlock() }
        return keys[profileID]
    }

    func setKey(_ key: String?, for profileID: UUID) {
        lock.lock()
        if let key, !key.isEmpty {
            keys[profileID] = key
        } else {
            keys[profileID] = nil
        }
        lock.unlock()
    }
}

/// UserDefaults persistence for `AIProviderProfile` records plus the active
/// profile id. Secrets never touch UserDefaults — API keys go through the
/// injected `AIAPIKeyStoring` only. (`UserDefaults` is documented
/// thread-safe, hence `@unchecked Sendable`.)
final class AIProviderStore: @unchecked Sendable {
    static let profilesKey = "aiAssistant.profiles"
    static let activeProfileIDKey = "aiAssistant.activeProfileID"

    let defaults: UserDefaults
    let keyStore: any AIAPIKeyStoring

    init(
        defaults: UserDefaults = .standard,
        keyStore: any AIAPIKeyStoring = AIKeychainAPIKeyStore()
    ) {
        self.defaults = defaults
        self.keyStore = keyStore
    }

    // MARK: - Profiles

    func profiles() -> [AIProviderProfile] {
        guard let data = defaults.data(forKey: Self.profilesKey),
              let decoded = try? JSONDecoder().decode([AIProviderProfile].self, from: data)
        else { return [] }
        return decoded
    }

    /// Creates or updates a profile. The first profile saved automatically
    /// becomes the active one.
    func save(_ profile: AIProviderProfile) {
        var all = profiles()
        if let index = all.firstIndex(where: { $0.id == profile.id }) {
            all[index] = profile
        } else {
            all.append(profile)
        }
        persist(all)
        if activeProfileID == nil || !all.contains(where: { $0.id == activeProfileID }) {
            setActive(profile.id)
        }
    }

    /// Removes the profile and its Keychain API key.
    func delete(_ id: UUID) {
        persist(profiles().filter { $0.id != id })
        try? keyStore.setKey(nil, for: id)
        if activeProfileID == id {
            setActive(profiles().first?.id)
        }
    }

    private func persist(_ profiles: [AIProviderProfile]) {
        let data = try? JSONEncoder().encode(profiles)
        defaults.set(data, forKey: Self.profilesKey)
    }

    // MARK: - Active profile

    var activeProfileID: UUID? {
        defaults.string(forKey: Self.activeProfileIDKey)
            .flatMap { UUID(uuidString: $0) }
    }

    func setActive(_ id: UUID?) {
        if let id {
            defaults.set(id.uuidString, forKey: Self.activeProfileIDKey)
        } else {
            defaults.removeObject(forKey: Self.activeProfileIDKey)
        }
    }

    func activeProfile() -> AIProviderProfile? {
        guard let id = activeProfileID else { return nil }
        return profiles().first { $0.id == id }
    }

    // MARK: - API keys

    func apiKey(for profileID: UUID) throws -> String? {
        try keyStore.key(for: profileID)
    }

    func setAPIKey(_ key: String?, for profileID: UUID) throws {
        let trimmed = key?.trimmingCharacters(in: .whitespacesAndNewlines)
        try keyStore.setKey(trimmed, for: profileID)
    }

    /// A ready-to-call client for `profile` (default: the active one).
    /// Throws `AIError.notConfigured` when there is no profile, no key or the
    /// profile's non-secret fields are incomplete.
    func makeClient(
        profile requested: AIProviderProfile? = nil,
        urlSession: URLSession = .shared
    ) throws -> AIClient {
        guard let profile = requested ?? activeProfile() else {
            throw AIError.notConfigured
        }
        guard profile.isUsable,
              let key = try keyStore.key(for: profile.id), !key.isEmpty else {
            throw AIError.notConfigured
        }
        return AIClient(profile: profile, apiKey: key, urlSession: urlSession)
    }
}
