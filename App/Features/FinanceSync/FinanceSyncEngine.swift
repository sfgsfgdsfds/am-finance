import CryptoKit
import FinanceCore
import Foundation
import SwiftData

extension Notification.Name {
    /// Posted (object: nil) after the sync engine commits pulled server
    /// changes into the app store — a background-context write views never
    /// see. The app should hook it to
    /// `LedgerBalanceStores.shared(for: container).invalidate()`.
    static let financeSyncLocalStoreChanged =
        Notification.Name("financeSyncLocalStoreChanged")
}

/// How a cycle's diff phase covered the local store.
enum FinanceSyncScanMode: String, Equatable, Sendable {
    /// Every row's content hash is recomputed — the only scan that can
    /// catch edits that never stamped `updatedAt` and relationship
    /// nullifications SwiftData applies silently.
    case full
    /// The routine scan: transactions (the bulk entity) are only
    /// re-hashed when `updatedAt` moved past the previous scan's start
    /// (minus a safety margin) — inserts/deletes are caught by the
    /// id-set diff against the shadow either way; the eight small
    /// entities always hash fully.
    case quick
}

/// Counters from one `FinanceSyncEngine.syncOnce` cycle.
struct FinanceSyncReport: Equatable, Sendable {
    /// Pulled records seen — including no-op echoes of our own pushes,
    /// kept-local conflicts and skipped unknown entities.
    var pulled = 0
    /// Pulled upserts that inserted or updated a local row.
    var applied = 0
    /// Pulled tombstones that deleted a local row.
    var deletedLocally = 0
    /// Upsert changes the server acknowledged (incl. a replayed pending
    /// batch). A `skipped` result on an upsert still counts here.
    var pushedUpserts = 0
    /// Delete changes the server acknowledged (incl. `skipped` no-ops).
    var pushedDeletes = 0
    /// Pulled versions NOT applied because an unpushed local change won —
    /// a local edit or insert beating a server upsert/tombstone, or a
    /// local delete beating a server upsert.
    var conflictsKeptLocal = 0
    /// Records newly parked by a `422` `index ≥ 0` this cycle.
    var quarantined = 0
    /// `409` rounds retried beyond the first attempt.
    var retries409 = 0
    /// The scan the diff phase ran — `.full` on the first cycle after
    /// launch, on `syncOnce(fullScan:)` and when the last full scan aged
    /// out; `.quick` otherwise.
    var scanMode: FinanceSyncScanMode = .quick
    /// Transactions whose content hash was recomputed this cycle — the
    /// incremental scan's cost meter: ~0 on a clean QUICK cycle.
    var hashedTransactions = 0
    var duration: TimeInterval = 0
}

/// Failures only the engine itself produces; transport errors surface as
/// the `FinanceSyncError` the API client already defines.
enum FinanceSyncEngineError: LocalizedError, Equatable {
    /// `syncOnce` was called while a cycle was already running.
    case alreadyRunning
    /// The server kept answering `409` after `rounds` pull+retry rounds.
    case conflictUnresolved(rounds: Int)
    /// A pulled upsert record carried no `data` payload.
    case pulledRecordMissingData(SyncEntity, UUID)

    var errorDescription: String? {
        switch self {
        case .alreadyRunning:
            return "Đồng bộ đang chạy — hãy đợi lượt hiện tại xong."
        case .conflictUnresolved(let rounds):
            return "Máy chủ thay đổi dữ liệu liên tục — \(rounds) lần thử vẫn bị xung đột, hãy đồng bộ lại sau."
        case .pulledRecordMissingData(let entity, let id):
            return "Máy chủ gửi bản ghi \(entity.rawValue) \(id) thiếu dữ liệu."
        }
    }
}

/// The two-way sync engine: an `actor` writing the app store on its own
/// background `ModelContext` (never through main-context views). One
/// `syncOnce` is a single cycle:
///
/// 1. PULL every page from the stored cursor — apply in seq order with
///    parent-before-child resolution (`pendingRefs` parks a child whose
///    referenced ids are not in the store yet and re-applies it the
///    moment every parent exists; a child is never dropped). Tombstones
///    delete the local row; upserts go through `SyncRecordMapper` (the
///    `BackupRestorer` per-row upserts — a pulled `updatedAt` is kept,
///    never re-stamped). Conflict policy is fixed: a row with an unpushed
///    local change — its content hash differs from the shadow, or it was
///    deleted locally while still in the shadow — is NOT overwritten by
///    the pulled version; the local change wins, is counted in
///    `conflictsKeptLocal` and pushes this cycle. Applied pages save in
///    chunks, then shadow entries, then the cursor — the cursor is never
///    ahead of durably applied data.
/// 2. REPLAY the persisted pending push (same key + byte-identical body)
///    so a crash/network drop never duplicates a batch; a stale body is
///    discarded and the diff re-covers its rows.
/// 3. DIFF local content hashes vs the shadow (`SyncDiff`), skipping
///    quarantined upserts whose local hash has not changed. Two scan
///    modes — see `FinanceSyncScanMode`: QUICK is the routine mode and
///    only re-hashes transactions whose `updatedAt` passes the previous
///    scan's threshold (inserts/deletes still surface through the
///    id-set diff against the shadow); FULL re-hashes everything and is
///    the backstop for edits that bypass `updatedAt` and silent
///    relationship nullifications — it runs on the first cycle after
///    launch, on demand, and at most every `fullScanInterval` later.
/// 4. PUSH `SyncBatcher` batches with `base_seq` = the post-pull cursor.
///    Each batch persists key+body before sending; a `422 index ≥ 0`
///    quarantines that one record and resends the trimmed batch under a
///    fresh key; `409` reruns pull+diff+push (≤ `maxConflictRounds`); the
///    pull cursor never advances on push — the next pull returns our own
///    writes and they apply as no-ops.
///
/// Out of scope (later steps): scheduling, UI, first-sync mode.
actor FinanceSyncEngine {
    /// The app container this engine writes to — `context` is its
    /// background context, actor-owned so no main-context view ever sees
    /// a pulled write mid-apply.
    let modelContainer: ModelContainer
    /// Pull/push transport — a typed client (a stub-session instance in
    /// tests exercises the real request/response path).
    let api: FinanceSyncAPIClient
    /// Content-hash shadows, quarantine and sync state — a SEPARATE
    /// container from the app store (`FinanceSyncSchema`).
    let shadow: SyncShadowStore
    /// Pull page size — tests shrink it to force multi-page pulls.
    let pullLimit: Int
    /// The engine's own context on `modelContainer` — every fetched row,
    /// applied DTO and tombstone delete happens here, off the main actor.
    private let context: ModelContext

    /// `409` pull+retry rounds per `syncOnce` before the cycle fails.
    static let maxConflictRounds = 3
    /// A FULL re-hash runs at least this often — the backstop catching
    /// `updatedAt`-invisible local edits. Between fulls, QUICK cycles
    /// cost a scan of ids + stamps, not a hash per row.
    static let fullScanInterval: TimeInterval = 6 * 3_600
    /// QUICK scan headroom below `lastScanStart`: transactions stamped
    /// inside the margin are re-hashed anyway — saves racing the scan
    /// boundary and sub-second `updatedAt` fuzz can never slip through.
    static let quickScanSafetyMargin: TimeInterval = 5

    /// Pulled children whose references were not resolvable when applied —
    /// re-applied as soon as every parent exists (later in the page, a
    /// later page, or a later cycle while this engine instance lives).
    /// Never dropped: worst case the row keeps a nil reference. The stored
    /// hash/seq fix the shadow entry to the full pulled content once the
    /// row re-links — no phantom "changed" diff on the next cycle.
    private var pendingRefs:
        [SyncRecordKey: (dto: SyncBackupDTO, hash: String, seq: Int64)] = [:]
    /// id → live row per entity, rebuilt at each pull phase — the
    /// resolution index the mapper links references through.
    private var maps = BackupRowMaps()
    private var inFlight = false
    /// Whether this engine instance already ran a FULL scan — the first
    /// `syncOnce` after launch always re-hashes everything regardless of
    /// how fresh the persisted `lastFullScanAt` is.
    private var ranFullScan = false
    /// Fired after every commit of pulled server changes — step 4 hooks
    /// `LedgerBalanceStore.invalidate()` here; `.financeSyncLocalStoreChanged`
    /// is also posted for observers that cannot take a closure.
    private var changeHooks: [@Sendable () -> Void] = []

    init(
        modelContainer: ModelContainer,
        api: FinanceSyncAPIClient,
        shadow: SyncShadowStore,
        pullLimit: Int = 500
    ) {
        let context = ModelContext(modelContainer)
        context.autosaveEnabled = false
        self.modelContainer = modelContainer
        self.context = context
        self.api = api
        self.shadow = shadow
        self.pullLimit = pullLimit
    }

    /// Registers an observer fired (on this actor) after each commit of
    /// pulled server changes — the `LedgerBalanceStore` invalidation hook.
    func addLocalStoreChangeHook(_ hook: @escaping @Sendable () -> Void) {
        changeHooks.append(hook)
    }

    /// One sync cycle — see the type docstring for the four steps.
    /// `fullScan: true` forces a FULL local hash pass for the diff; the
    /// default is QUICK when the persisted markers allow it.
    @discardableResult
    func syncOnce(fullScan: Bool = false) async throws -> FinanceSyncReport {
        guard !inFlight else { throw FinanceSyncEngineError.alreadyRunning }
        inFlight = true
        defer { inFlight = false }
        let started = ContinuousClock.now
        var report = FinanceSyncReport()
        do {
            var round = 0
            var lastScan: (start: Date, mode: FinanceSyncScanMode)?
            while true {
                try await pullPhase(report: &report)
                try await replayPendingPush(report: &report)
                let pending = try await pendingChanges(
                    forceFullScan: fullScan, report: &report)
                lastScan = pending.scan
                do {
                    try await pushChanges(
                        pending.changes, wireBytes: pending.wireBytes,
                        report: &report)
                    break
                } catch FinanceSyncError.conflict(_) {
                    report.retries409 += 1
                    round += 1
                    guard round < Self.maxConflictRounds else {
                        throw FinanceSyncEngineError.conflictUnresolved(rounds: round)
                    }
                }
            }
            report.duration = Self.seconds(since: started)
            if let lastScan {
                // Persisted only on success — a failed cycle leaves the
                // threshold back so the next scan re-covers the window.
                try await shadow.updateScanMarkers(
                    lastScanStart: lastScan.start,
                    lastFullScanAt: lastScan.mode == .full ? lastScan.start : nil)
                if lastScan.mode == .full { ranFullScan = true }
            }
            try await shadow.recordSyncResult(finishedAt: .now, error: nil)
            return report
        } catch {
            report.duration = Self.seconds(since: started)
            try? await shadow.recordSyncResult(
                finishedAt: .now, error: error.localizedDescription)
            throw error
        }
    }

    /// Local content hashes for every synced row — a FULL scan's `local`
    /// output; tests use it to compare two engines' stores.
    func localContentHashes() async throws -> [SyncRecordKey: String] {
        try rebuildMaps()
        var report = FinanceSyncReport()
        return try await collectLocalRows(
            quickThreshold: nil, shadowSnapshot: [:], report: &report).hashes
    }

    // MARK: - Pull

    private enum PullApplyOutcome {
        /// The record was applied — payload is the hash of the row as now
        /// stored locally.
        case stored(String)
        /// Local already held this exact content — only `serverSeq` moved.
        case refreshSeq(String)
        /// An unpushed local change won; the pulled version was dropped.
        case keptLocal
    }

    /// Pulled upsert pre-work, computed off-actor per page: the record's
    /// decoded DTO and the canonical hash OF THAT DTO — the same hash a
    /// local row produces, so pulled content compares directly. Both are
    /// pure CPU so a 500-record page pays for them in parallel instead
    /// of inside the apply loop. A decode error rides along and is
    /// rethrown at that record's seq position, keeping the whole-page
    /// rollback ordering intact.
    private typealias PreparedUpsert
        = Result<(dto: SyncBackupDTO, hash: String), Error>

    /// Pulls from the stored cursor until `has_more == false`, applying
    /// each page, then shadow entries, then `next_cursor`.
    private func pullPhase(report: inout FinanceSyncReport) async throws {
        try rebuildMaps()
        var shadowView = try await shadow.snapshot()
        var cursor = try await shadow.pullCursor()
        while true {
            let page = try await api.pull(cursor: cursor, limit: pullLimit)
            report.pulled += page.records.count
            let sorted = page.records.sorted { $0.seq < $1.seq }
            let prepared: [Int: PreparedUpsert] =
                await withTaskGroup(
                    of: (Int, PreparedUpsert).self
                ) { group in
                    for (index, record) in sorted.enumerated() {
                        guard !record.deleted,
                              let entity = record.syncEntity,
                              let data = record.data
                        else { continue }
                        group.addTask {
                            (index, Result {
                                let dto = try SyncRecordMapper.decode(
                                    entity: entity, from: data)
                                return (
                                    dto: dto,
                                    hash: SyncRecordMapper.contentHash(of: dto))
                            })
                        }
                    }
                    var out: [Int: PreparedUpsert] = [:]
                    out.reserveCapacity(sorted.count)
                    for await (index, value) in group { out[index] = value }
                    return out
                }
            var shadowUpserts: [SyncShadowEntrySnapshot] = []
            var shadowRemovals: [SyncRecordKey] = []
            do {
                for (index, record) in sorted.enumerated() {
                    guard let entity = record.syncEntity else { continue }
                    let key = SyncRecordKey(entity: entity, id: record.id)
                    if record.deleted {
                        if try applyTombstone(
                            key: key, shadowHash: shadowView[key],
                            report: &report) {
                            shadowView.removeValue(forKey: key)
                            shadowRemovals.append(key)
                        }
                    } else {
                        guard let upsert = prepared[index] else {
                            throw FinanceSyncEngineError
                                .pulledRecordMissingData(entity, record.id)
                        }
                        let preparedUpsert = try upsert.get()
                        switch try applyUpsert(
                            key: key, dto: preparedUpsert.dto,
                            pulledHash: preparedUpsert.hash, seq: record.seq,
                            shadowHash: shadowView[key], report: &report) {
                        case .stored(let hash), .refreshSeq(let hash):
                            shadowView[key] = hash
                            shadowUpserts.append(SyncShadowEntrySnapshot(
                                entity: entity.rawValue, recordID: record.id,
                                contentHash: hash, serverSeq: record.seq))
                        case .keptLocal:
                            break
                        }
                    }
                }
                resolvePendingRefs(
                    shadowView: &shadowView, upserts: &shadowUpserts)
            } catch {
                context.rollback()
                throw error
            }
            if context.hasChanges {
                try context.save()
                notifyLocalStoreChanged()
            }
            try await shadow.updateEntries(
                upserts: shadowUpserts, removals: shadowRemovals)
            let next = max(page.nextCursor, cursor)
            try await shadow.setPullCursor(next)
            guard page.hasMore else { break }
            // Defensive: a server that pages without moving the cursor and
            // returns nothing must not loop forever.
            guard next > cursor || !page.records.isEmpty else { break }
            cursor = next
        }
    }

    /// Applies one pulled upsert per the conflict policy — see the type
    /// docstring. `dto`/`pulledHash` come from the page's parallel
    /// prepare stage.
    private func applyUpsert(
        key: SyncRecordKey, dto: SyncBackupDTO, pulledHash: String,
        seq: Int64, shadowHash: String?, report: inout FinanceSyncReport
    ) throws -> PullApplyOutcome {
        let existing = mapsRow(key)
        var localHash: String? = nil
        if let existing {
            localHash = try SyncRecordMapper.contentHash(of: existing)
        }
        if let localHash, localHash == pulledHash {
            // Identical content already stored — an own-push echo or two
            // sides that converged independently; just refresh `serverSeq`.
            pendingRefs.removeValue(forKey: key)
            return .refreshSeq(localHash)
        }
        if localHash != shadowHash || (existing == nil && shadowHash != nil) {
            // Unpushed local change — an edit, a never-synced insert, or a
            // local delete still present in the shadow — wins over the
            // pulled version and pushes this cycle.
            pendingRefs.removeValue(forKey: key)
            report.conflictsKeptLocal += 1
            return .keptLocal
        }
        let unresolved = unresolvedReferences(of: dto)
        let outcome = SyncRecordMapper.apply(dto, into: context, maps: &maps)
        if unresolved.isEmpty {
            pendingRefs.removeValue(forKey: key)
        } else {
            pendingRefs[key] = (dto: dto, hash: pulledHash, seq: seq)
        }
        if outcome != .skipped { report.applied += 1 }
        var storedHash = pulledHash
        if outcome == .skipped {
            // The merge rule refused the pulled copy — the row kept its
            // own content, so the hash computed above still stands.
            storedHash = localHash ?? pulledHash
        } else if !unresolved.isEmpty {
            // References still dangle — the stored row has nil fields
            // where the pulled DTO has ids; only this path re-hashes.
            // (`.inserted`/`.updated` with every ref resolved stores the
            // pulled content verbatim → pulledHash already matches.)
            if let row = mapsRow(key),
               let hash = try SyncRecordMapper.contentHash(of: row) {
                storedHash = hash
            }
        }
        return .stored(storedHash)
    }

    /// Applies one pulled tombstone. Returns true when a local row was
    /// deleted (the caller drops the shadow entry).
    private func applyTombstone(
        key: SyncRecordKey, shadowHash: String?,
        report: inout FinanceSyncReport
    ) throws -> Bool {
        pendingRefs.removeValue(forKey: key)
        guard let existing = mapsRow(key) else {
            // Already gone locally — if the shadow still holds it, our
            // unpushed delete wins and pushes this cycle (the server
            // answers `skipped`); no shadow at all is an own-delete echo.
            if shadowHash != nil { report.conflictsKeptLocal += 1 }
            return false
        }
        let localHash = try SyncRecordMapper.contentHash(of: existing)
        if localHash != shadowHash {
            report.conflictsKeptLocal += 1
            return false
        }
        context.delete(existing)
        removeFromMaps(key)
        report.deletedLocally += 1
        return true
    }

    /// Re-applies every pending child whose references now all resolve —
    /// run after each pulled page. The re-applied row holds the full DTO
    /// content, so its shadow entry is rewritten to the pulled hash/seq:
    /// without that the row would look locally-changed and push back.
    private func resolvePendingRefs(
        shadowView: inout [SyncRecordKey: String],
        upserts: inout [SyncShadowEntrySnapshot]
    ) {
        guard !pendingRefs.isEmpty else { return }
        let resolved = pendingRefs.keys.filter {
            unresolvedReferences(of: pendingRefs[$0]!.dto).isEmpty
        }
        for key in resolved {
            guard let entry = pendingRefs.removeValue(forKey: key)
            else { continue }
            SyncRecordMapper.apply(
                entry.dto, into: context, maps: &maps, force: true)
            shadowView[key] = entry.hash
            upserts.append(SyncShadowEntrySnapshot(
                entity: key.entity.rawValue, recordID: key.id,
                contentHash: entry.hash, serverSeq: entry.seq))
        }
    }

    /// A DTO's non-nil references that do not resolve to a live local row.
    private func unresolvedReferences(of dto: SyncBackupDTO) -> [SyncRecordKey] {
        SyncRecordMapper.references(of: dto).filter { mapsRow($0) == nil }
    }

    // MARK: - Diff

    private struct LocalRow {
        /// The DTO as wire `data` — built once, reused by the `SyncChange`.
        var json: SyncJSONValue
        var contentHash: String
        /// Canonical byte size — the batcher's per-change size estimate.
        var wireBytes: Int
    }

    /// The scan a `pendingChanges` run performs this round.
    private struct ScanPlan {
        var mode: FinanceSyncScanMode
        /// QUICK: transactions stamped at or before this (already the
        /// `quickScanSafetyMargin` below the last scan) keep their shadow
        /// hash untouched. FULL: nil — everything re-hashes.
        var transactionThreshold: Date?
        var startedAt: Date
    }

    /// Resolves this cycle's scan mode: forced, or the first cycle this
    /// engine runs, or whenever the persisted FULL scan aged out (or was
    /// never recorded). Fresh markers → QUICK with the margin-adjusted
    /// threshold.
    private func scanPlan(
        forced: Bool, at now: Date
    ) async throws -> ScanPlan {
        if forced || !ranFullScan {
            return ScanPlan(mode: .full, transactionThreshold: nil, startedAt: now)
        }
        let state = try await shadow.state()
        guard let lastFull = state.lastFullScanAt,
              now.timeIntervalSince(lastFull) < Self.fullScanInterval,
              let lastScan = state.lastScanStart
        else {
            return ScanPlan(mode: .full, transactionThreshold: nil, startedAt: now)
        }
        return ScanPlan(
            mode: .quick,
            transactionThreshold: lastScan.addingTimeInterval(
                -Self.quickScanSafetyMargin),
            startedAt: now)
    }

    /// Reads every synced row from the pull phase's `maps` into
    /// `(hashes, rows)` — the diff's `local` input plus the per-row wire
    /// payload for whatever turns out changed.
    ///
    /// `quickThreshold` is the QUICK path: a transaction stamped at or
    /// before it keeps its shadow hash (it cannot have changed in a way
    /// `updatedAt` reports — anything else is the FULL scan's job); rows
    /// missing from the shadow are always hashed (an insert). Inserts
    /// and deletes are caught by the id sets either way: a local key
    /// absent from the shadow hashes + upserts; a shadow key absent
    /// locally diffs as a delete. The eight small entities always hash
    /// fully — their tables are trivially small.
    ///
    /// Hashing itself fans out across cores in 250-row chunks: DTO +
    /// field extraction stays on this actor (SwiftData reads), the
    /// canonical encode + SHA-256 + wire AST are pure CPU off-actor.
    private func collectLocalRows(
        quickThreshold: Date?,
        shadowSnapshot: [SyncRecordKey: String],
        report: inout FinanceSyncReport
    ) async throws
        -> (hashes: [SyncRecordKey: String], rows: [SyncRecordKey: LocalRow])
    {
        var hashes: [SyncRecordKey: String] = [:]
        var pending: [(SyncRecordKey, SyncBackupDTO)] = []

        // The bulk entity — incremental under QUICK.
        for (id, row) in maps.transactions {
            let key = SyncRecordKey(entity: .transaction, id: id)
            if let threshold = quickThreshold,
               row.updatedAt <= threshold,
               let shadowHash = shadowSnapshot[key] {
                hashes[key] = shadowHash
                continue
            }
            guard let dto = SyncRecordMapper.dto(of: row) else { continue }
            pending.append((key, dto))
            report.hashedTransactions += 1
        }

        // The eight small entities — always a full pass.
        func queue<T: PersistentModel>(_ rows: some Sequence<T>) {
            for row in rows {
                guard let dto = SyncRecordMapper.dto(of: row) else { continue }
                pending.append((
                    SyncRecordKey(entity: dto.entity, id: dto.id), dto))
            }
        }
        queue(maps.accounts.values)
        queue(maps.categories.values)
        queue(maps.businesses.values)
        queue(maps.rateChanges.values)
        queue(maps.budgets.values)
        queue(maps.recurringRules.values)
        queue(maps.rentalUnits.values)
        queue(maps.rentalLeases.values)

        let rows = try await withThrowingTaskGroup(
            of: [(SyncRecordKey, LocalRow)].self
        ) { group in
            let chunkSize = 250
            for start in stride(from: 0, to: pending.count, by: chunkSize) {
                let slice = Array(
                    pending[start..<min(start + chunkSize, pending.count)])
                group.addTask {
                    try slice.map { key, dto in
                        let json = try SyncRecordMapper.jsonValue(of: dto)
                        let canonical = SyncContentHasher.canonicalData(
                            fields: SyncRecordMapper.canonicalFields(of: dto))
                        return (key, LocalRow(
                            json: json,
                            contentHash: SyncContentHasher.hash(
                                canonicalData: canonical),
                            wireBytes: canonical.count))
                    }
                }
            }
            var rows: [SyncRecordKey: LocalRow] = [:]
            rows.reserveCapacity(pending.count)
            for try await chunk in group {
                for (key, row) in chunk { rows[key] = row }
            }
            return rows
        }
        for (key, row) in rows { hashes[key] = row.contentHash }
        return (hashes, rows)
    }

    /// The wire change list: `SyncDiff` against the shadow, minus
    /// quarantined upserts whose local hash has not moved, upserts
    /// parent-first then deletes child-first. Each upsert carries its
    /// local hash so the ack can write the shadow without re-encoding;
    /// `wireBytes` feeds the batcher's size estimate. `scan` reports the
    /// mode + start the caller persists on success.
    private func pendingChanges(
        forceFullScan: Bool, report: inout FinanceSyncReport
    ) async throws
        -> (changes: [(change: SyncChange, contentHash: String)],
            wireBytes: [SyncRecordKey: Int],
            scan: (start: Date, mode: FinanceSyncScanMode))
    {
        let plan = try await scanPlan(
            forced: forceFullScan, at: .now)
        report.scanMode = plan.mode
        let shadowSnapshot = try await shadow.snapshot()
        let quarantined = try await shadow.quarantinedHashes()
        let local = try await collectLocalRows(
            quickThreshold: plan.transactionThreshold,
            shadowSnapshot: shadowSnapshot, report: &report)
        let diff = SyncDiff.compute(local: local.hashes, shadow: shadowSnapshot)
        var changes: [(SyncChange, String)] = []
        var wireBytes: [SyncRecordKey: Int] = [:]
        for key in diff.upserts {
            guard let row = local.rows[key] else { continue }
            if quarantined[key] == row.contentHash { continue }
            changes.append((
                SyncChange(
                    entity: key.entity, id: key.id, op: .upsert,
                    data: row.json),
                row.contentHash))
            wireBytes[key] = row.wireBytes
        }
        for key in diff.deletes {
            changes.append((
                SyncChange(entity: key.entity, id: key.id, op: .delete), ""))
        }
        return (changes, wireBytes, (plan.startedAt, plan.mode))
    }

    // MARK: - Push

    /// Replays the persisted pending push — the SAME key and bytes a
    /// crash/network drop interrupted, so the server de-dupes it. Rows
    /// the diff still covers are re-sent naturally when the stored body
    /// can no longer commit.
    private func replayPendingPush(report: inout FinanceSyncReport) async throws {
        guard let pending = try await shadow.pendingPush() else { return }
        guard let body = pending.body,
              let request = try? JSONDecoder().decode(
                  SyncPushRequest.self, from: body)
        else {
            // A corrupt marker is dropped — the records stay in the diff.
            try await shadow.clearPendingPush()
            return
        }
        do {
            let response = try await api.pushEncoded(
                body: body, idempotencyKey: pending.key)
            var hashes: [SyncRecordKey: String] = [:]
            for change in request.changes where change.op == .upsert {
                if let data = change.data {
                    hashes[SyncRecordKey(entity: change.entity, id: change.id)] =
                        SyncContentHasher.hash(data)
                }
            }
            try await acknowledgePush(
                request.changes, results: response.results,
                hashes: hashes, report: &report)
            try await shadow.clearPendingPush()
        } catch FinanceSyncError.conflict(_), FinanceSyncError.validation(_) {
            // The stored body can no longer commit (stale `base_seq` or a
            // now-invalid row). Its records are still unpushed, so a fresh
            // batch in this cycle carries them — drop the stale body.
            try await shadow.clearPendingPush()
        } catch FinanceSyncError.idempotencyKeyReused {
            try await shadow.clearPendingPush()
            throw FinanceSyncError.idempotencyKeyReused
        }
        // Transport/4xx/5xx errors propagate with the pending push still
        // stored — the next cycle replays the same bytes.
    }

    /// Sends the diff in `SyncBatcher` batches. Each batch persists its
    /// idempotency key + exact body before the wire sees it; `422 index ≥
    /// 0` quarantines that record and resends the trimmed batch under a
    /// fresh key; `409` propagates for the round retry.
    private func pushChanges(
        _ changes: [(change: SyncChange, contentHash: String)],
        wireBytes: [SyncRecordKey: Int],
        report: inout FinanceSyncReport
    ) async throws {
        guard !changes.isEmpty else { return }
        let baseSeq = try await shadow.pullCursor()
        var hashes: [SyncRecordKey: String] = [:]
        for (change, hash) in changes {
            hashes[SyncRecordKey(entity: change.entity, id: change.id)] = hash
        }
        let batches = try SyncBatcher.split(changes.map { $0.change }) {
            // The diff already canonicalized each upsert's `data` — its
            // size plus envelope headroom avoids a full re-encode per
            // change; deletes (no `data`) carry a fixed estimate.
            wireBytes[SyncRecordKey(entity: $0.entity, id: $0.id)]
                .map { $0 + 160 } ?? 1_024
        }
        for batch in batches {
            var work = batch
            while !work.isEmpty {
                let body = try JSONEncoder().encode(
                    SyncPushRequest(baseSeq: baseSeq, changes: work))
                let key = try await pendingKey(for: body)
                do {
                    let response = try await api.pushEncoded(
                        body: body, idempotencyKey: key)
                    try await acknowledgePush(
                        work, results: response.results,
                        hashes: hashes, report: &report)
                    try await shadow.clearPendingPush()
                    break
                } catch FinanceSyncError.validation(let detail)
                            where detail.index >= 0 && detail.index < work.count {
                    let rejected = work.remove(at: detail.index)
                    let rejectedKey = SyncRecordKey(
                        entity: rejected.entity, id: rejected.id)
                    try await shadow.quarantine(
                        entity: rejected.entity, recordID: rejected.id,
                        contentHash: hashes[rejectedKey] ?? "",
                        constraint: detail.constraint, message: detail.message)
                    report.quarantined += 1
                    if work.isEmpty { try await shadow.clearPendingPush() }
                }
            }
        }
    }

    /// The idempotency key for `body`: the stored pending key when the
    /// bytes match (the body is mid-flight), otherwise a fresh key whose
    /// pair is persisted BEFORE the request can leave.
    private func pendingKey(for body: Data) async throws -> String {
        let bodyHash = Self.sha256Hex(body)
        if let pending = try await shadow.pendingPush(),
           pending.bodyHash == bodyHash {
            return pending.key
        }
        let key = UUID().uuidString
        try await shadow.setPendingPush(key: key, body: body, bodyHash: bodyHash)
        return key
    }

    /// Writes the shadow for a `200` push: pushed upsert hash + assigned
    /// seq, shadow removal for deletes and `skipped` results, and release
    /// of any quarantine on acknowledged keys.
    private func acknowledgePush(
        _ sent: [SyncChange], results: [SyncPushResult],
        hashes: [SyncRecordKey: String], report: inout FinanceSyncReport
    ) async throws {
        var upserts: [SyncShadowEntrySnapshot] = []
        var removals: [SyncRecordKey] = []
        var pushedKeys: [SyncRecordKey] = []
        for (index, change) in sent.enumerated() {
            guard index < results.count else { break }
            let key = SyncRecordKey(entity: change.entity, id: change.id)
            switch results[index] {
            case .seq(let seq):
                switch change.op {
                case .upsert:
                    upserts.append(SyncShadowEntrySnapshot(
                        entity: change.entity.rawValue, recordID: change.id,
                        contentHash: hashes[key] ?? "", serverSeq: seq))
                    report.pushedUpserts += 1
                case .delete:
                    removals.append(key)
                    report.pushedDeletes += 1
                }
            case .skipped:
                removals.append(key)
                if change.op == .delete {
                    report.pushedDeletes += 1
                } else {
                    report.pushedUpserts += 1
                }
            }
            pushedKeys.append(key)
        }
        try await shadow.updateEntries(upserts: upserts, removals: removals)
        try await shadow.clearQuarantines(pushedKeys)
    }

    // MARK: - Store internals

    /// Rebuilds the id → live-row index the pull-apply links through.
    private func rebuildMaps() throws {
        maps = BackupRowMaps(
            accounts: try context.fetch(FetchDescriptor<Account>())
                .reduce(into: [:]) { $0[$1.id] = $1 },
            categories: try context.fetch(FetchDescriptor<LedgerCategory>())
                .reduce(into: [:]) { $0[$1.id] = $1 },
            businesses: try context.fetch(FetchDescriptor<Business>())
                .reduce(into: [:]) { $0[$1.id] = $1 },
            transactions: try context.fetch(FetchDescriptor<LedgerTransaction>())
                .reduce(into: [:]) { $0[$1.id] = $1 },
            rateChanges: try context.fetch(FetchDescriptor<LoanRateChange>())
                .reduce(into: [:]) { $0[$1.id] = $1 },
            budgets: try context.fetch(FetchDescriptor<Budget>())
                .reduce(into: [:]) { $0[$1.id] = $1 },
            recurringRules: try context.fetch(FetchDescriptor<RecurringRule>())
                .reduce(into: [:]) { $0[$1.id] = $1 },
            rentalUnits: try context.fetch(FetchDescriptor<RentalUnit>())
                .reduce(into: [:]) { $0[$1.id] = $1 },
            rentalLeases: try context.fetch(FetchDescriptor<RentalLease>())
                .reduce(into: [:]) { $0[$1.id] = $1 }
        )
    }

    private func mapsRow(_ key: SyncRecordKey) -> (any PersistentModel)? {
        switch key.entity {
        case .account: return maps.accounts[key.id]
        case .category: return maps.categories[key.id]
        case .business: return maps.businesses[key.id]
        case .transaction: return maps.transactions[key.id]
        case .loanRateChange: return maps.rateChanges[key.id]
        case .budget: return maps.budgets[key.id]
        case .recurringRule: return maps.recurringRules[key.id]
        case .rentalUnit: return maps.rentalUnits[key.id]
        case .rentalLease: return maps.rentalLeases[key.id]
        }
    }

    private func removeFromMaps(_ key: SyncRecordKey) {
        switch key.entity {
        case .account: maps.accounts.removeValue(forKey: key.id)
        case .category: maps.categories.removeValue(forKey: key.id)
        case .business: maps.businesses.removeValue(forKey: key.id)
        case .transaction: maps.transactions.removeValue(forKey: key.id)
        case .loanRateChange: maps.rateChanges.removeValue(forKey: key.id)
        case .budget: maps.budgets.removeValue(forKey: key.id)
        case .recurringRule: maps.recurringRules.removeValue(forKey: key.id)
        case .rentalUnit: maps.rentalUnits.removeValue(forKey: key.id)
        case .rentalLease: maps.rentalLeases.removeValue(forKey: key.id)
        }
    }

    private func notifyLocalStoreChanged() {
        for hook in changeHooks { hook() }
        NotificationCenter.default.post(
            name: .financeSyncLocalStoreChanged, object: nil)
    }

    private static func sha256Hex(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    private static func seconds(since start: ContinuousClock.Instant) -> TimeInterval {
        let components = (ContinuousClock.now - start).components
        return TimeInterval(components.seconds)
            + TimeInterval(components.attoseconds) / 1e18
    }
}
