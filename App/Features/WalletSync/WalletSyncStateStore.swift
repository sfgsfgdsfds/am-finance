import Foundation

/// Per-bank-account sync progress, persisted as JSON in UserDefaults.
/// `cursor` is the opaque `after_id` cursor — the last imported server
/// transaction UUID, or "0" before anything was read (the server's own
/// start-of-table cursor; every UUID sorts after it).
struct WalletSyncAccountState: Codable, Equatable, Sendable {
    /// Cursor meaning "read from the start" — the server's `after_id`
    /// default.
    static let startCursor = "0"

    var cursor: String = WalletSyncAccountState.startCursor
    /// Only transactions on/after this date are imported; nil = full history.
    /// Captured once at link time so "Từ hôm nay" does not drift.
    var importFrom: Date?
    var lastSyncAt: Date?
    /// Last time a full rescan from "0" completed — throttles the
    /// self-healing rescan to once a day.
    var lastFullRescanAt: Date?
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
/// in-memory in tests. `sessionID` is the server session UUID string.
/// Also holds the tombstones: external ids of imported rows the user
/// deleted locally — they must never be imported again. Tombstones are
/// stored per external source, apart from the per-session state, so
/// `removeState` (unlinking) keeps them.
protocol WalletSyncStateStoring: Sendable {
    func state(for sessionID: String) -> WalletSyncAccountState
    func setState(_ state: WalletSyncAccountState, for sessionID: String)
    func removeState(for sessionID: String)
    /// Most recent `lastSyncAt` across all sessions; nil if never synced.
    var lastSyncAt: Date? { get }
    /// External ids tombstoned for `source` — deleted locally, never
    /// import again.
    func tombstonedIDs(source: String) -> Set<String>
    /// Records external ids as tombstoned for `source`. Re-recording an
    /// id bumps it to newest; the list is capped per source.
    func recordTombstones(_ ids: [String], source: String)
    /// Wipes every session state and every tombstone — the "Xoá dữ liệu"
    /// reset uses it; callers re-create states they still need.
    func removeAll()
}

/// UserDefaults-backed store: one JSON blob `[sessionID: state]` for the
/// cursors and a second `[source: [ids]]` blob for the tombstones.
final class WalletSyncStateStore: WalletSyncStateStoring, @unchecked Sendable {
    static let key = "walletSync.accountStates"
    static let tombstonesKey = "walletSync.tombstones"
    /// Tombstones kept per external source — the oldest ids drop off so
    /// the list stays bounded.
    static let tombstoneCap = 5_000

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

    func state(for sessionID: String) -> WalletSyncAccountState {
        all[sessionID] ?? WalletSyncAccountState()
    }

    func setState(_ state: WalletSyncAccountState, for sessionID: String) {
        var copy = all
        copy[sessionID] = state
        all = copy
    }

    func removeState(for sessionID: String) {
        var copy = all
        copy.removeValue(forKey: sessionID)
        all = copy
    }

    /// `[source: [ids]]`, ids ordered oldest → newest.
    private var tombstoneMap: [String: [String]] {
        get {
            guard let data = defaults.data(forKey: Self.tombstonesKey),
                  let decoded = try? JSONDecoder().decode(
                      [String: [String]].self, from: data)
            else { return [:] }
            return decoded
        }
        set {
            let data = try? JSONEncoder().encode(newValue)
            defaults.set(data, forKey: Self.tombstonesKey)
        }
    }

    func tombstonedIDs(source: String) -> Set<String> {
        Set(tombstoneMap[source] ?? [])
    }

    func recordTombstones(_ ids: [String], source: String) {
        guard !ids.isEmpty else { return }
        var map = tombstoneMap
        map[source] = Self.appending(ids, to: map[source] ?? [])
        tombstoneMap = map
    }

    /// Appends `ids` deduplicated (a repeat id becomes newest), then
    /// trims to the newest `tombstoneCap` entries.
    static func appending(_ ids: [String], to list: [String]) -> [String] {
        let fresh = Set(ids)
        var copy = list.filter { !fresh.contains($0) }
        copy.append(contentsOf: ids)
        if copy.count > tombstoneCap {
            copy = Array(copy.suffix(tombstoneCap))
        }
        return copy
    }

    func removeAll() {
        defaults.removeObject(forKey: Self.key)
        defaults.removeObject(forKey: Self.tombstonesKey)
    }
}

/// Volatile `WalletSyncStateStoring` for tests and previews.
final class WalletSyncInMemoryStateStore: WalletSyncStateStoring, @unchecked Sendable {
    private var states: [String: WalletSyncAccountState] = [:]
    private var tombstones: [String: [String]] = [:]

    init() {}

    var lastSyncAt: Date? {
        states.values.compactMap(\.lastSyncAt).max()
    }

    func state(for sessionID: String) -> WalletSyncAccountState {
        states[sessionID] ?? WalletSyncAccountState()
    }

    func setState(_ state: WalletSyncAccountState, for sessionID: String) {
        states[sessionID] = state
    }

    func removeState(for sessionID: String) {
        states.removeValue(forKey: sessionID)
    }

    func tombstonedIDs(source: String) -> Set<String> {
        Set(tombstones[source] ?? [])
    }

    func recordTombstones(_ ids: [String], source: String) {
        guard !ids.isEmpty else { return }
        tombstones[source] = WalletSyncStateStore.appending(
            ids, to: tombstones[source] ?? [])
    }

    func removeAll() {
        states = [:]
        tombstones = [:]
    }
}
