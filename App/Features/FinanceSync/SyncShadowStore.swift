import FinanceCore
import Foundation
import SwiftData

/// One row of the sync shadow: the content hash of a record the last
/// time it was in sync with the server, plus the server seq that state
/// came from. Lives in a SEPARATE `FinanceSync.store` — not in
/// `AppSchema`, not in the backup, wiped independently.
///
/// Fields keep the CloudKit-compatible style (defaults, no unique
/// constraints) even though this store never syncs to CloudKit —
/// uniqueness of `(entity, recordID)` is enforced by the store's
/// find-then-update logic.
@Model
final class SyncShadowEntry {
    /// Wire entity name — a `SyncEntity` raw value. Named `entityName`
    /// (not `entity`) because `entity` collides with
    /// `NSManagedObject.entity` inside `#Predicate`/CoreData fetches.
    var entityName: String = ""
    var recordID: UUID = UUID()
    /// `SyncContentHasher` hex of the record's canonical DTO JSON.
    var contentHash: String = ""
    /// The server seq this record was at when the shadow was written
    /// (assigned seq on a pushed change, record seq on a pulled one);
    /// 0 while a row has never left the device.
    var serverSeq: Int64 = 0

    init(entity: String, recordID: UUID, contentHash: String, serverSeq: Int64) {
        self.entityName = entity
        self.recordID = recordID
        self.contentHash = contentHash
        self.serverSeq = serverSeq
    }
}

/// Singleton sync state — one row, `singletonKey` == "state". Kept as a
/// model (not UserDefaults) so the whole sync state lives and wipes with
/// the same store.
@Model
final class SyncShadowState {
    static let singletonKey = "state"

    var singletonKey: String = SyncShadowState.singletonKey
    /// Last pulled seq — the `next_cursor` the engine resumes from and
    /// the `base_seq` pushes are computed against.
    var pullCursor: Int64 = 0
    /// Whether two-way sync is switched on.
    var isEnabled: Bool = false
    var lastSyncAt: Date? = nil
    /// Description of the most recent failed sync, nil when the last run
    /// was clean.
    var lastError: String? = nil

    /// Idempotency state of an in-flight push: after a network drop the
    /// engine must replay the SAME key and byte-identical body, so both
    /// (and the body's hash, for verification) persist here until the
    /// server answers.
    var pendingPushKey: String? = nil
    var pendingPushBodyHash: String? = nil
    var pendingPushBody: Data? = nil

    /// When the last diff-phase scan started — the next QUICK scan only
    /// re-hashes transactions stamped after this minus a safety margin.
    var lastScanStart: Date? = nil
    /// When the last FULL scan ran — a full re-hash is forced once this
    /// is older than the engine's full-scan interval.
    var lastFullScanAt: Date? = nil

    init() {}
}

/// A record the server refused with a `422` `index ≥ 0` — the change is
/// parked here and the diff leaves it out of later pushes until its local
/// content hash moves off `contentHash`. `constraint`/`message` keep the
/// server's reason so a UI can explain why the row is not syncing.
@Model
final class SyncQuarantineEntry {
    var entityName: String = ""
    var recordID: UUID = UUID()
    /// `SyncContentHasher` hex of the rejected local version; an upsert is
    /// retried only once its hash no longer equals this.
    var contentHash: String = ""
    var constraint: String = ""
    var message: String = ""
    var quarantinedAt: Date = Date.now

    init(
        entity: String, recordID: UUID, contentHash: String,
        constraint: String, message: String
    ) {
        self.entityName = entity
        self.recordID = recordID
        self.contentHash = contentHash
        self.constraint = constraint
        self.message = message
        self.quarantinedAt = .now
    }
}

/// A quarantine entry as a plain value.
struct SyncQuarantineSnapshot: Equatable, Sendable {
    var entity: String
    var recordID: UUID
    var contentHash: String
    var constraint: String
    var message: String
    var quarantinedAt: Date

    var recordKey: SyncRecordKey? {
        guard let entity = SyncEntity(rawValue: entity) else { return nil }
        return SyncRecordKey(entity: entity, id: recordID)
    }
}

/// A shadow entry as a plain value — what crosses the actor boundary.
struct SyncShadowEntrySnapshot: Equatable, Sendable {
    var entity: String
    var recordID: UUID
    var contentHash: String
    var serverSeq: Int64

    var recordKey: SyncRecordKey? {
        guard let entity = SyncEntity(rawValue: entity) else { return nil }
        return SyncRecordKey(entity: entity, id: recordID)
    }
}

/// The `SyncShadowState` row as a plain value.
struct SyncShadowStateSnapshot: Equatable, Sendable {
    var pullCursor: Int64 = 0
    var isEnabled = false
    var lastSyncAt: Date? = nil
    var lastError: String? = nil
    var pendingPushKey: String? = nil
    var pendingPushBodyHash: String? = nil
    var pendingPushBody: Data? = nil
    var lastScanStart: Date? = nil
    var lastFullScanAt: Date? = nil
}

/// Everything the engine needs to replay an interrupted push: the
/// idempotency key plus the exact request body (and its hash for a
/// cheap sanity check before resending).
struct SyncPendingPush: Equatable, Sendable {
    var key: String
    var body: Data?
    var bodyHash: String
}

/// The shadow store's SwiftData schema — a separate container from the
/// app's, defaulting to `Application Support/FinanceSync.store`.
enum FinanceSyncSchema {
    static let models: [any PersistentModel.Type] = [
        SyncShadowEntry.self,
        SyncShadowState.self,
        SyncQuarantineEntry.self,
    ]

    static let storeFileName = "FinanceSync.store"

    /// `inMemory` is the test/preview variant; the app builds the actor
    /// over the file store so the shadow survives relaunches.
    static func makeContainer(inMemory: Bool = false) throws -> ModelContainer {
        let schema = Schema(models)
        let configuration: ModelConfiguration
        if inMemory {
            configuration = ModelConfiguration(
                schema: schema,
                isStoredInMemoryOnly: true,
                cloudKitDatabase: .none)
        } else {
            let url = FileManager.default
                .urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
                .appendingPathComponent(storeFileName)
            configuration = ModelConfiguration(
                schema: schema,
                url: url,
                cloudKitDatabase: .none)
        }
        return try ModelContainer(for: schema, configurations: [configuration])
    }
}

/// Concurrency-safe access to the shadow store — a `ModelActor` so
/// every read/write runs on its own context off the main actor.
@ModelActor
actor SyncShadowStore {

    // MARK: - Entries

    /// Number of shadow entries without materialising them — the
    /// first-sync bootstrap's "never synced" probe.
    func entryCount() throws -> Int {
        try modelContext.fetchCount(FetchDescriptor<SyncShadowEntry>())
    }

    /// Every entry, for the diff's shadow side and for tests.
    func allEntries() throws -> [SyncShadowEntrySnapshot] {
        try modelContext.fetch(FetchDescriptor<SyncShadowEntry>()).map {
            SyncShadowEntrySnapshot(
                entity: $0.entityName, recordID: $0.recordID,
                contentHash: $0.contentHash, serverSeq: $0.serverSeq)
        }
    }

    /// `key -> contentHash` for every entry — `SyncDiff`'s shadow input.
    /// Entries with an entity name this build does not know are dropped:
    /// they could never be produced locally.
    func snapshot() throws -> [SyncRecordKey: String] {
        var result: [SyncRecordKey: String] = [:]
        for entry in try allEntries() {
            if let key = entry.recordKey {
                result[key] = entry.contentHash
            }
        }
        return result
    }

    /// The stored hash of one record — nil if the row was never synced.
    func contentHash(entity: SyncEntity, recordID: UUID) throws -> String? {
        try entry(entity: entity, recordID: recordID)?.contentHash
    }

    /// The server seq the shadow last saw for one record — nil if never.
    func serverSeq(entity: SyncEntity, recordID: UUID) throws -> Int64? {
        try entry(entity: entity, recordID: recordID)?.serverSeq
    }

    /// Writes (or updates) the shadow for one record.
    func upsertEntry(
        entity: SyncEntity, recordID: UUID,
        contentHash: String, serverSeq: Int64
    ) throws {
        if let existing = try entry(entity: entity, recordID: recordID) {
            existing.contentHash = contentHash
            existing.serverSeq = serverSeq
        } else {
            modelContext.insert(SyncShadowEntry(
                entity: entity.rawValue, recordID: recordID,
                contentHash: contentHash, serverSeq: serverSeq))
        }
        try modelContext.save()
    }

    /// Drops one record's shadow — after a pulled tombstone has been
    /// applied and acknowledged locally.
    func removeEntry(entity: SyncEntity, recordID: UUID) throws {
        if let existing = try entry(entity: entity, recordID: recordID) {
            modelContext.delete(existing)
            try modelContext.save()
        }
    }

    /// Drops every entry — full resync from an empty shadow.
    func removeAllEntries() throws {
        for entry in try modelContext.fetch(FetchDescriptor<SyncShadowEntry>()) {
            modelContext.delete(entry)
        }
        try modelContext.save()
    }

    /// Batched shadow write — one `save()` for a whole pull page or push
    /// acknowledgement instead of a save per record. The touched entries
    /// are found with a single `IN` fetch — a fetch per record was the
    /// page's dominant cost.
    func updateEntries(
        upserts: [SyncShadowEntrySnapshot],
        removals: [SyncRecordKey]
    ) throws {
        let ids = upserts.map(\.recordID) + removals.map(\.id)
        var found: [String: SyncShadowEntry] = [:]
        if !ids.isEmpty {
            for entry in try modelContext.fetch(FetchDescriptor<SyncShadowEntry>(
                predicate: #Predicate { ids.contains($0.recordID) })) {
                found["\(entry.entityName)/\(entry.recordID)"] = entry
            }
        }
        for snapshot in upserts {
            guard SyncEntity(rawValue: snapshot.entity) != nil else { continue }
            if let existing = found["\(snapshot.entity)/\(snapshot.recordID)"] {
                existing.contentHash = snapshot.contentHash
                existing.serverSeq = snapshot.serverSeq
            } else {
                modelContext.insert(SyncShadowEntry(
                    entity: snapshot.entity, recordID: snapshot.recordID,
                    contentHash: snapshot.contentHash, serverSeq: snapshot.serverSeq))
            }
        }
        for key in removals {
            if let existing = found["\(key.entity.rawValue)/\(key.id)"] {
                modelContext.delete(existing)
            }
        }
        try modelContext.save()
    }

    /// Replaces the whole entry table in one save — the first-sync
    /// bootstrap seeds the shadow with the local content hashes after an
    /// upload/download replace, where a per-row find-then-update would
    /// cost one fetch per record for no benefit.
    func replaceEntries(_ entries: [SyncShadowEntrySnapshot]) throws {
        for entry in try modelContext.fetch(FetchDescriptor<SyncShadowEntry>()) {
            modelContext.delete(entry)
        }
        for snapshot in entries {
            modelContext.insert(SyncShadowEntry(
                entity: snapshot.entity, recordID: snapshot.recordID,
                contentHash: snapshot.contentHash, serverSeq: snapshot.serverSeq))
        }
        try modelContext.save()
    }

    // MARK: - Quarantine

    /// Parks one rejected change: entity/id, the refused content hash and
    /// the server's `constraint`/`message`.
    func quarantine(
        entity: SyncEntity, recordID: UUID,
        contentHash: String, constraint: String, message: String
    ) throws {
        if let existing = try quarantineEntry(entity: entity, recordID: recordID) {
            existing.contentHash = contentHash
            existing.constraint = constraint
            existing.message = message
            existing.quarantinedAt = .now
        } else {
            modelContext.insert(SyncQuarantineEntry(
                entity: entity.rawValue, recordID: recordID,
                contentHash: contentHash, constraint: constraint,
                message: message))
        }
        try modelContext.save()
    }

    /// `key -> rejected-hash` for every quarantined record — the diff
    /// skips an upsert while its local hash still equals this.
    func quarantinedHashes() throws -> [SyncRecordKey: String] {
        var result: [SyncRecordKey: String] = [:]
        for entry in try modelContext.fetch(FetchDescriptor<SyncQuarantineEntry>()) {
            if let entity = SyncEntity(rawValue: entry.entityName) {
                result[SyncRecordKey(entity: entity, id: entry.recordID)] = entry.contentHash
            }
        }
        return result
    }

    /// Every quarantine entry, for tests and a future settings surface.
    func quarantines() throws -> [SyncQuarantineSnapshot] {
        try modelContext.fetch(FetchDescriptor<SyncQuarantineEntry>()).map {
            SyncQuarantineSnapshot(
                entity: $0.entityName, recordID: $0.recordID,
                contentHash: $0.contentHash, constraint: $0.constraint,
                message: $0.message, quarantinedAt: $0.quarantinedAt)
        }
    }

    /// Releases one record — after a successful push or when it should
    /// retry.
    func clearQuarantine(entity: SyncEntity, recordID: UUID) throws {
        if let existing = try quarantineEntry(entity: entity, recordID: recordID) {
            modelContext.delete(existing)
            try modelContext.save()
        }
    }

    /// Releases several records in one save — the push ack path. Same
    /// single-`IN`-fetch pattern as `updateEntries`.
    func clearQuarantines(_ keys: [SyncRecordKey]) throws {
        let ids = keys.map(\.id)
        if !ids.isEmpty {
            let wanted = Set(keys.map { "\($0.entity.rawValue)/\($0.id)" })
            for entry in try modelContext.fetch(FetchDescriptor<SyncQuarantineEntry>(
                predicate: #Predicate { ids.contains($0.recordID) })) {
                if wanted.contains("\(entry.entityName)/\(entry.recordID)") {
                    modelContext.delete(entry)
                }
            }
        }
        try modelContext.save()
    }

    // MARK: - State

    /// The whole state row as a value. Read-pure: a missing row reads
    /// back as defaults instead of materializing one — the row is
    /// created by the first WRITE through `stateRow()`, so a read-only
    /// session never leaves pending changes on the context.
    func state() throws -> SyncShadowStateSnapshot {
        guard let row = try modelContext.fetch(
            FetchDescriptor<SyncShadowState>()).first
        else { return SyncShadowStateSnapshot() }
        return SyncShadowStateSnapshot(
            pullCursor: row.pullCursor,
            isEnabled: row.isEnabled,
            lastSyncAt: row.lastSyncAt,
            lastError: row.lastError,
            pendingPushKey: row.pendingPushKey,
            pendingPushBodyHash: row.pendingPushBodyHash,
            pendingPushBody: row.pendingPushBody,
            lastScanStart: row.lastScanStart,
            lastFullScanAt: row.lastFullScanAt)
    }

    func pullCursor() throws -> Int64 {
        try existingStateRow()?.pullCursor ?? 0
    }

    func setPullCursor(_ cursor: Int64) throws {
        try stateRow().pullCursor = cursor
        try modelContext.save()
    }

    func isEnabled() throws -> Bool {
        try existingStateRow()?.isEnabled ?? false
    }

    func setEnabled(_ enabled: Bool) throws {
        try stateRow().isEnabled = enabled
        try modelContext.save()
    }

    /// Stamps the outcome of a sync run — `finishedAt` on every run,
    /// `error` only when it failed.
    func recordSyncResult(finishedAt: Date, error: String?) throws {
        let row = try stateRow()
        row.lastSyncAt = finishedAt
        row.lastError = error
        try modelContext.save()
    }

    /// Records the diff-phase scan markers on a successful cycle:
    /// `lastScanStart` moves the next QUICK scan's `updatedAt` threshold
    /// forward; a FULL scan also refreshes `lastFullScanAt` (nil leaves
    /// it — QUICK cycles must not push the 6-hour horizon out).
    func updateScanMarkers(lastScanStart: Date, lastFullScanAt: Date?) throws {
        let row = try stateRow()
        row.lastScanStart = lastScanStart
        if let lastFullScanAt { row.lastFullScanAt = lastFullScanAt }
        try modelContext.save()
    }

    /// The pending push waiting for a replay — nil when nothing is
    /// in flight.
    func pendingPush() throws -> SyncPendingPush? {
        guard let row = try existingStateRow(),
              let key = row.pendingPushKey else { return nil }
        return SyncPendingPush(
            key: key, body: row.pendingPushBody,
            bodyHash: row.pendingPushBodyHash ?? "")
    }

    /// Records the push about to be sent so a dropped connection can be
    /// replayed byte-identically after relaunch.
    func setPendingPush(key: String, body: Data?, bodyHash: String) throws {
        let row = try stateRow()
        row.pendingPushKey = key
        row.pendingPushBody = body
        row.pendingPushBodyHash = bodyHash
        try modelContext.save()
    }

    /// The server answered (or the batch was abandoned) — clears the
    /// in-flight marker.
    func clearPendingPush() throws {
        let row = try stateRow()
        row.pendingPushKey = nil
        row.pendingPushBody = nil
        row.pendingPushBodyHash = nil
        try modelContext.save()
    }

    /// Entries AND state — a clean slate, e.g. when the user signs out or
    /// resets all data.
    func wipeAll() throws {
        try removeAllEntries()
        for entry in try modelContext.fetch(FetchDescriptor<SyncQuarantineEntry>()) {
            modelContext.delete(entry)
        }
        let row = try stateRow()
        row.pullCursor = 0
        row.isEnabled = false
        row.lastSyncAt = nil
        row.lastError = nil
        row.pendingPushKey = nil
        row.pendingPushBody = nil
        row.pendingPushBodyHash = nil
        row.lastScanStart = nil
        row.lastFullScanAt = nil
        try modelContext.save()
    }

    // MARK: - Internals

    private func entry(entity: SyncEntity, recordID: UUID) throws -> SyncShadowEntry? {
        let raw = entity.rawValue
        var descriptor = FetchDescriptor<SyncShadowEntry>(
            predicate: #Predicate {
                $0.entityName == raw && $0.recordID == recordID
            })
        descriptor.fetchLimit = 1
        return try modelContext.fetch(descriptor).first
    }

    private func quarantineEntry(
        entity: SyncEntity, recordID: UUID
    ) throws -> SyncQuarantineEntry? {
        let raw = entity.rawValue
        var descriptor = FetchDescriptor<SyncQuarantineEntry>(
            predicate: #Predicate {
                $0.entityName == raw && $0.recordID == recordID
            })
        descriptor.fetchLimit = 1
        return try modelContext.fetch(descriptor).first
    }

    /// The singleton state row if it exists — nil on a fresh store, so
    /// pure reads never create it.
    private func existingStateRow() throws -> SyncShadowState? {
        try modelContext.fetch(FetchDescriptor<SyncShadowState>()).first
    }

    /// The singleton state row, created on first touch — write paths
    /// only; every caller saves the context right after.
    private func stateRow() throws -> SyncShadowState {
        if let existing = try modelContext.fetch(
            FetchDescriptor<SyncShadowState>()).first {
            return existing
        }
        let created = SyncShadowState()
        modelContext.insert(created)
        return created
    }
}
