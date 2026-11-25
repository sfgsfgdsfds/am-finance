import FinanceCore
import Foundation
import SwiftData

/// What `probe()` learned about the two stores — the inputs a "first
/// sync" chooser needs before offering upload vs download.
struct FinanceSyncProbe: Equatable, Sendable {
    /// true when the server's change stream holds no record at all —
    /// a brand-new account, or one just replaced.
    var serverEmpty: Bool
    /// Live local row counts per synced entity.
    var localCounts: [SyncEntity: Int]
    /// Total live local rows.
    var localTotal: Int
    /// No shadow entries — this device has never completed a sync.
    var shadowEmpty: Bool
    /// Whether two-way sync is switched on.
    var isEnabled: Bool
    /// The pull cursor the engine resumes from.
    var pullCursor: Int64
}

/// Counters from one bootstrap run — a UI reports what moved.
struct FinanceSyncBootstrapReport: Equatable, Sendable {
    /// `uploadReplace`: local rows inside the exported document.
    var exportedRows = 0
    /// `uploadReplace`: upserts the server reported, all sections summed.
    var importUpserted = 0
    /// `uploadReplace`: pre-existing server rows the replace tombstoned.
    var importTombstoned = 0
    /// `uploadReplace`: dangling references the server wrote NULL.
    var importRefsNulled = 0
    /// `downloadReplace`: live records pulled and decoded.
    var recordsDownloaded = 0
    /// `downloadReplace`: tombstone records skipped (nothing to insert).
    var tombstonesSkipped = 0
    /// `downloadReplace`: records skipped because this build does not
    /// know their entity — a newer server's rows, never fatal.
    var unknownSkipped = 0
    /// `downloadReplace`: `BackupRestorer` counters (inserts dominate in
    /// `.replace` mode).
    var restoreInserted = 0
    var restoreUpdated = 0
    var restoreSkipped = 0
    /// `downloadReplace`: pull pages fetched from cursor 0.
    var pagesPulled = 0
    /// Counters of the terminal reconcile `syncOnce`.
    var sync: FinanceSyncReport?
}

/// Failures only the bootstrap produces; transport/decoding problems
/// surface as the `FinanceSyncError`/`FinanceSyncEngineError` the client
/// and engine already define.
enum FinanceSyncBootstrapError: LocalizedError, Equatable {
    /// A bootstrap was already running on this instance.
    case alreadyRunning
    /// The terminal reconcile found an engine cycle in flight — nothing
    /// was enabled; safe to retry once it finishes.
    case syncInProgress

    var errorDescription: String? {
        switch self {
        case .alreadyRunning:
            return "Đang thiết lập đồng bộ — hãy đợi lượt hiện tại xong."
        case .syncInProgress:
            return "Đang có một lượt đồng bộ khác chạy — hãy thử lại sau."
        }
    }
}

/// The two "first sync" modes — how a device with existing data and a
/// possibly non-empty server reach one shared state before two-way sync
/// is switched on. An `actor` like the engine; it reuses the engine's
/// public surface (`syncOnce`, `localContentHashes`) and never touches
/// its internals.
///
/// `probe()` is read-only and safe to call any time. `uploadReplace()`
/// and `downloadReplace()` are the two modes:
///
/// - **uploadReplace** ("Đưa dữ liệu iPhone lên server") — the phone's
///   copy wins. Exports the full store as one backup-v5 document and
///   `POST /v1/backup/import`s it: inside one server transaction every
///   record is upserted and every live server row the document does not
///   carry is tombstoned. Then the shadow is seeded with the local
///   content hashes at cursor 0 and `engine.syncOnce()` reconciles:
///   the pull walks the import's own records (equal rows are no-op
///   `refreshSeq`s, so nothing re-uploads) and any server-normalised
///   difference converges to the server's form.
/// - **downloadReplace** ("Tải dữ liệu từ server về iPhone") — the
///   server's copy wins. Pulls every page from cursor 0, assembles the
///   live records into a backup-v5 document (tombstones skipped,
///   unknown entities skipped) and runs `BackupRestorer.restore`
///   `.replace` — the same atomic delete-then-insert a file restore
///   performs, posting `.financeSyncLocalStoreChanged` like the engine
///   does after pulled writes. Then the shadow is seeded with the
///   restored local hashes, the cursor jumps to the pulled stream head
///   so the reconcile `syncOnce` does not replay history — it pushes
///   nothing by construction.
///
/// Both modes enable sync only as their LAST step: a run that fails or
/// is interrupted leaves `isEnabled` off, so no scheduled sync can run
/// against a half-migrated shadow — and both are naturally resumable
/// (`import` is a server-side replace transaction; `.replace` restore is
/// atomic; the shadow reset repeats cleanly). A second bootstrap on the
/// same instance is refused (`alreadyRunning`); an engine cycle found
/// in flight at the reconcile step fails the run with `syncInProgress`
/// rather than racing it.
actor FinanceSyncBootstrap {
    /// The app container this bootstrap reads and (for downloadReplace)
    /// rewrites — `context` is its own background context, never the
    /// main-context one views use.
    let modelContainer: ModelContainer
    /// Pull/import transport — the same typed client the engine uses.
    let api: FinanceSyncAPIClient
    /// The sync engine — used only through its public API.
    let engine: FinanceSyncEngine
    /// Content-hash shadows, quarantine and sync state.
    let shadow: SyncShadowStore
    /// Pull page size — tests shrink it to force multi-page pulls.
    let pullLimit: Int
    /// The bootstrap's own context on `modelContainer` — export reads
    /// and the `.replace` restore happen here, off the main actor.
    private let context: ModelContext

    private var busy = false
    /// Fired after `downloadReplace`'s restore commits — mirrors the
    /// engine's hook so the app can invalidate `LedgerBalanceStore`.
    private var changeHooks: [@Sendable () -> Void] = []

    init(
        modelContainer: ModelContainer,
        api: FinanceSyncAPIClient,
        engine: FinanceSyncEngine,
        shadow: SyncShadowStore,
        pullLimit: Int = 500
    ) {
        let context = ModelContext(modelContainer)
        context.autosaveEnabled = false
        self.modelContainer = modelContainer
        self.context = context
        self.api = api
        self.engine = engine
        self.shadow = shadow
        self.pullLimit = pullLimit
    }

    /// Registers an observer fired (on this actor) after the restore
    /// commit inside `downloadReplace` — the `LedgerBalanceStore`
    /// invalidation hook, mirroring `engine.addLocalStoreChangeHook`.
    func addLocalStoreChangeHook(_ hook: @escaping @Sendable () -> Void) {
        changeHooks.append(hook)
    }

    // MARK: - Probe

    /// Server emptiness (one record is enough to know), local row
    /// counts and shadow state — read-only, safe any time.
    func probe() async throws -> FinanceSyncProbe {
        let page = try await api.pull(cursor: 0, limit: 1)
        let counts = try localCounts()
        let state = try await shadow.state()
        return FinanceSyncProbe(
            serverEmpty: page.records.isEmpty,
            localCounts: counts,
            localTotal: counts.values.reduce(0, +),
            shadowEmpty: try await shadow.entryCount() == 0,
            isEnabled: state.isEnabled,
            pullCursor: state.pullCursor)
    }

    // MARK: - Upload

    /// "Đưa dữ liệu iPhone lên server" — see the type docstring.
    @discardableResult
    func uploadReplace() async throws -> FinanceSyncBootstrapReport {
        try begin()
        defer { busy = false }
        var report = FinanceSyncBootstrapReport()

        // The whole local store as one backup-v5 document — the same
        // encoding "Xuất bản sao lưu" writes.
        let body = try BackupCodec.encode(context: context)

        // Server-side REPLACE: upserts + tombstones with fresh seqs.
        let summary = try await api.importBackup(body)
        for section in summary.entities.values {
            report.importUpserted += section.upserted
            report.importTombstoned += section.tombstoned
            report.importRefsNulled += section.refsNulled
        }

        // Shadow = the local content hashes at cursor 0 — the reconcile
        // pull then walks the import's own records and marks them all
        // in-sync instead of re-uploading them.
        try await shadow.wipeAll()
        report.exportedRows = try await seedShadowFromLocalHashes()

        report.sync = try await reconcile()
        try await shadow.setEnabled(true)
        return report
    }

    // MARK: - Download

    /// "Tải dữ liệu từ server về iPhone" — see the type docstring.
    @discardableResult
    func downloadReplace() async throws -> FinanceSyncBootstrapReport {
        try begin()
        defer { busy = false }
        var report = FinanceSyncBootstrapReport()

        // Every record the server holds, paged from the start.
        var records: [SyncPullRecord] = []
        var cursor: Int64 = 0
        while true {
            let page = try await api.pull(cursor: cursor, limit: pullLimit)
            report.pagesPulled += 1
            records.append(contentsOf: page.records)
            let next = max(page.nextCursor, cursor)
            let advanced = next > cursor || !page.records.isEmpty
            cursor = next
            // Same defensive guard as the engine: a server that pages
            // without moving the cursor and returns nothing must not
            // loop forever.
            guard page.hasMore, advanced else { break }
        }

        // The live records as a backup-v5 document, restored exactly
        // like a file picked in BackupView — `.replace` deletes all
        // local rows first, then inserts the document's.
        let document = try document(from: records, into: &report)
        let restored = try BackupRestorer.restore(
            document, mode: .replace, into: context)
        report.restoreInserted = restored.inserted
        report.restoreUpdated = restored.updated
        report.restoreSkipped = restored.skipped
        notifyLocalStoreChanged()

        // Shadow = the restored local hashes; cursor = the stream's
        // head so the reconcile does not replay the records the
        // restore just applied — and pushes nothing by construction.
        try await shadow.wipeAll()
        _ = try await seedShadowFromLocalHashes()
        try await shadow.setPullCursor(cursor)

        report.sync = try await reconcile()
        try await shadow.setEnabled(true)
        return report
    }

    // MARK: - Internals

    private func begin() throws {
        guard !busy else { throw FinanceSyncBootstrapError.alreadyRunning }
        busy = true
    }

    /// The terminal `syncOnce` — maps a busy engine to the bootstrap's
    /// own refusal so the failure reads as "retry", never half-enabled.
    private func reconcile() async throws -> FinanceSyncReport {
        do {
            return try await engine.syncOnce()
        } catch FinanceSyncEngineError.alreadyRunning {
            throw FinanceSyncBootstrapError.syncInProgress
        }
    }

    /// Shadow entries = `SyncRecordMapper.contentHash` of every live
    /// local row — via `engine.localContentHashes()`, the same hash
    /// pipeline the diff uses — at `serverSeq` 0. The reconcile pull
    /// fills the real seqs in. Returns the row count.
    @discardableResult
    private func seedShadowFromLocalHashes() async throws -> Int {
        let hashes = try await engine.localContentHashes()
        try await shadow.replaceEntries(hashes.map { key, hash in
            SyncShadowEntrySnapshot(
                entity: key.entity.rawValue, recordID: key.id,
                contentHash: hash, serverSeq: 0)
        })
        return hashes.count
    }

    /// The pulled records as a backup-v5 document: latest record per
    /// key (the stream already emits one per row; keeping max seq is
    /// cheap insurance), tombstones and unknown entities skipped.
    private func document(
        from records: [SyncPullRecord],
        into report: inout FinanceSyncBootstrapReport
    ) throws -> BackupDocument {
        var latest: [SyncRecordKey: SyncPullRecord] = [:]
        for record in records {
            guard let entity = record.syncEntity else {
                report.unknownSkipped += 1
                continue
            }
            let key = SyncRecordKey(entity: entity, id: record.id)
            if let existing = latest[key], existing.seq >= record.seq {
                continue
            }
            latest[key] = record
        }
        var document = BackupDocument(
            formatVersion: BackupCodec.formatVersion,
            exportedAt: .now,
            appVersion: BackupCodec.appVersion,
            accounts: [], categories: [], businesses: [], transactions: [])
        for (key, record) in latest.sorted(by: { $0.value.seq < $1.value.seq }) {
            if record.deleted {
                report.tombstonesSkipped += 1
                continue
            }
            guard let data = record.data else {
                throw FinanceSyncEngineError.pulledRecordMissingData(
                    key.entity, key.id)
            }
            switch try SyncRecordMapper.decode(entity: key.entity, from: data) {
            case .account(let dto): document.accounts.append(dto)
            case .category(let dto): document.categories.append(dto)
            case .business(let dto): document.businesses.append(dto)
            case .transaction(let dto): document.transactions.append(dto)
            case .loanRateChange(let dto): document.loanRateChanges.append(dto)
            case .budget(let dto): document.budgets.append(dto)
            case .recurringRule(let dto): document.recurringRules.append(dto)
            case .rentalUnit(let dto): document.rentalUnits.append(dto)
            case .rentalLease(let dto): document.rentalLeases.append(dto)
            }
            report.recordsDownloaded += 1
        }
        return document
    }

    private func localCounts() throws -> [SyncEntity: Int] {
        [
            .account: try context.fetchCount(FetchDescriptor<Account>()),
            .category: try context.fetchCount(FetchDescriptor<LedgerCategory>()),
            .business: try context.fetchCount(FetchDescriptor<Business>()),
            .transaction: try context.fetchCount(FetchDescriptor<LedgerTransaction>()),
            .loanRateChange: try context.fetchCount(FetchDescriptor<LoanRateChange>()),
            .budget: try context.fetchCount(FetchDescriptor<Budget>()),
            .recurringRule: try context.fetchCount(FetchDescriptor<RecurringRule>()),
            .rentalUnit: try context.fetchCount(FetchDescriptor<RentalUnit>()),
            .rentalLease: try context.fetchCount(FetchDescriptor<RentalLease>()),
        ]
    }

    private func notifyLocalStoreChanged() {
        for hook in changeHooks { hook() }
        NotificationCenter.default.post(
            name: .financeSyncLocalStoreChanged, object: nil)
    }
}
