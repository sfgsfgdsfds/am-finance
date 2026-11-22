import Foundation

/// Per-bank-account sync progress, persisted as JSON in UserDefaults.
/// `cursor` is the last imported server transaction id — the `after_id`
/// parameter of the next fetch.
struct WalletSyncAccountState: Codable, Equatable, Sendable {
    var cursor: Int = 0
    /// Only transactions on/after this date are imported; nil = full history.
    /// Captured once at link time so "Từ hôm nay" does not drift.
    var importFrom: Date?
    var lastSyncAt: Date?
}

/// The three "import from" choices offered when linking a bank account.
enum WalletSyncImportFrom: String, Codable, CaseIterable, Sendable {
    case today
    case last30Days
    case allHistory

    var displayName: String {
        switch self {
        case .today: return "Từ hôm nay"
        case .last30Days: return "30 ngày gần nhất"
        case .allHistory: return "Toàn bộ lịch sử"
        }
    }

    /// The absolute cutoff stored on the sync state — resolved once against
    /// `now` at link time; nil means no limit.
    func startDate(now: Date, calendar: Calendar = AppCalendar.vietnam) -> Date? {
        switch self {
        case .today:
            return calendar.startOfDay(for: now)
        case .last30Days:
            let back = calendar.date(byAdding: .day, value: -30, to: now) ?? now
            return calendar.startOfDay(for: back)
        case .allHistory:
            return nil
        }
    }
}

/// Storage seam for per-session sync state — UserDefaults in the app,
/// in-memory in tests.
protocol WalletSyncStateStoring: Sendable {
    func state(for sessionID: Int) -> WalletSyncAccountState
    func setState(_ state: WalletSyncAccountState, for sessionID: Int)
    func removeState(for sessionID: Int)
    /// Most recent `lastSyncAt` across all sessions; nil if never synced.
    var lastSyncAt: Date? { get }
}

/// UserDefaults-backed store: one JSON blob `[sessionID: state]`.
final class WalletSyncStateStore: WalletSyncStateStoring, @unchecked Sendable {
    static let key = "walletSync.accountStates"

    let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    private var all: [String: WalletSyncAccountState] {
        get {
            guard let data = defaults.data(forKey: Self.key),
                  let decoded = try? JSONDecoder().decode(
                      [String: WalletSyncAccountState].self, from: data)
            else { return [:] }
            return decoded
        }
        set {
            let data = try? JSONEncoder().encode(newValue)
            defaults.set(data, forKey: Self.key)
        }
    }

    var lastSyncAt: Date? {
        all.values.compactMap(\.lastSyncAt).max()
    }

    func state(for sessionID: Int) -> WalletSyncAccountState {
        all[String(sessionID)] ?? WalletSyncAccountState()
    }

    func setState(_ state: WalletSyncAccountState, for sessionID: Int) {
        var copy = all
        copy[String(sessionID)] = state
        all = copy
    }

    func removeState(for sessionID: Int) {
        var copy = all
        copy.removeValue(forKey: String(sessionID))
        all = copy
    }
}

/// Volatile `WalletSyncStateStoring` for tests and previews.
final class WalletSyncInMemoryStateStore: WalletSyncStateStoring, @unchecked Sendable {
    private var states: [Int: WalletSyncAccountState] = [:]

    init() {}

    var lastSyncAt: Date? {
        states.values.compactMap(\.lastSyncAt).max()
    }

    func state(for sessionID: Int) -> WalletSyncAccountState {
        states[sessionID] ?? WalletSyncAccountState()
    }

    func setState(_ state: WalletSyncAccountState, for sessionID: Int) {
        states[sessionID] = state
    }

    func removeState(for sessionID: Int) {
        states.removeValue(forKey: sessionID)
    }
}
