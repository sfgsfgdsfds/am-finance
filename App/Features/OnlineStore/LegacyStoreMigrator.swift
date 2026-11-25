import FinanceCore
import Foundation
import SwiftData

/// What the one-time legacy migration decided and did — persisted as
/// `LegacyMigration.json` next to the stores so every step is resumable
/// after a crash and the one-time notice survives a relaunch.
struct LegacyStoreMigrationRecord: Codable, Equatable, Sendable {
    /// `LegacyStore-<yyyyMMdd-HHmmss>` — reused by every retry.
    var folderName: String
    /// `legacy-backup.json` is on disk (never rewritten once true).
    var backupWritten = false
    /// The old shadow showed a device that had synced with the server
    /// (enabled, paused, or any shadow entry / pull cursor).
    var wasSyncConfigured: Bool?
    /// A `POST /v1/backup/import` of the legacy export was started — a
    /// retry never re-imports once the server is no longer empty.
    var importAttempted = false
    /// The legacy export became the server's data.
    var importedLegacy = false
    /// Never-synced phone + non-empty server: the server's data won.
    var serverWon = false
    /// Records still quarantined by a `422` — only the backup JSON
    /// holds them.
    var quarantinedCount = 0
    /// Push/import is finished — only the file move is left.
    var pushDone = false
    /// Files are moved into `folderName`.
    var completed = false
    var noticeDismissed = false
}

enum LegacyStoreMigrationError: LocalizedError, Equatable {
    /// The second full cycle still had changes to push.
    case notConverged
    case moveFailed(String)

    var errorDescription: String? {
        switch self {
        case .notConverged:
            return "Không đưa hết dữ liệu cũ trên iPhone lên máy chủ — hãy thử lại."
        case .moveFailed(let name):
            return "Không chuyển được tệp dữ liệu cũ (\(name)) vào thư mục sao lưu."
        }
    }
}

/// Moves a pre-online-only install onto the server. The owner's iPhone
/// has a real on-disk store (`default.store`) with two-way sync enabled,
/// so this path never discards anything:
///
/// 1. open the on-disk app store + `FinanceSync.store` shadow;
/// 2. ALWAYS write a backup-v5 export to
///    `LegacyStore-<ts>/legacy-backup.json` first;
/// 3. sync was configured → `syncOnce(fullScan: true)` pushes pending
///    local edits, a second full cycle must push 0 (records still
///    quarantined by a `422` live only in the backup — counted for a
///    one-time notice); never synced → server empty (`head == 0`):
///    import the legacy export, otherwise server wins, nothing imported,
///    one-time notice;
/// 4. release every reference to the on-disk containers, then MOVE
///    (never delete) `default.store*` and `FinanceSync.store*` into the
///    folder — `default.store` last, so it stays the "migration not
///    finished" marker;
/// 5. any failure → nothing is moved, the caller shows "Thử lại".
///
/// Idempotent: the record file remembers the folder, the backup, the
/// decision and the finished push, so a retry after a crash at any
/// point resumes instead of repeating destructive steps.
struct LegacyStoreMigrator: Sendable {
    static let recordFileName = "LegacyMigration.json"
    static let backupFileName = "legacy-backup.json"
    static let folderPrefix = "LegacyStore-"

    /// Application Support — injectable so tests use a temp directory.
    let supportDirectory: URL
    let api: FinanceSyncAPIClient
    var pullLimit = 500
    var now: @Sendable () -> Date = { .now }

    init(
        supportDirectory: URL = FileManager.default
            .urls(for: .applicationSupportDirectory, in: .userDomainMask)[0],
        api: FinanceSyncAPIClient,
        pullLimit: Int = 500,
        now: @escaping @Sendable () -> Date = { .now }
    ) {
        self.supportDirectory = supportDirectory
        self.api = api
        self.pullLimit = pullLimit
        self.now = now
    }

    // MARK: - State

    private var recordURL: URL {
        supportDirectory.appendingPathComponent(Self.recordFileName)
    }

    func loadRecord() -> LegacyStoreMigrationRecord? {
        guard let data = try? Data(contentsOf: recordURL) else { return nil }
        return try? JSONDecoder().decode(LegacyStoreMigrationRecord.self, from: data)
    }

    private func save(_ record: LegacyStoreMigrationRecord) throws {
        try JSONEncoder().encode(record).write(to: recordURL, options: .atomic)
    }

    /// Files of the on-disk stores (`-wal`/`-shm`/`-journal` included).
    private func storeFiles(prefix: String) -> [URL] {
        let names = (try? FileManager.default
            .contentsOfDirectory(atPath: supportDirectory.path)) ?? []
        return names.filter { $0.hasPrefix(prefix) }.sorted()
            .map { supportDirectory.appendingPathComponent($0) }
    }

    /// An on-disk app store is still in place, or a previous attempt
    /// stopped before its move finished.
    var hasLegacyStore: Bool {
        if FileManager.default.fileExists(atPath: supportDirectory
            .appendingPathComponent(AppModelContainer.legacyStoreFileName).path) {
            return true
        }
        if let record = loadRecord(), !record.completed { return true }
        return false
    }

    /// The one-time Vietnamese notice, nil when nothing needs saying or
    /// the user already saw it.
    var pendingNotice: String? {
        guard let record = loadRecord(), record.completed,
              !record.noticeDismissed else { return nil }
        let location = "\(record.folderName)/\(Self.backupFileName)"
        var parts: [String] = []
        if record.serverWon {
            parts.append("Dữ liệu cũ trên iPhone chưa từng đồng bộ, còn máy chủ đã có dữ liệu nên ứng dụng dùng dữ liệu của máy chủ. Dữ liệu iPhone cũ được lưu thành tệp sao lưu (\(location)).")
        }
        if record.quarantinedCount > 0 {
            parts.append("\(record.quarantinedCount) bản ghi cũ bị máy chủ từ chối nên không được đưa lên; chúng chỉ còn trong tệp sao lưu (\(location)).")
        }
        return parts.isEmpty ? nil : parts.joined(separator: "\n\n")
    }

    func dismissNotice() {
        guard var record = loadRecord() else { return }
        record.noticeDismissed = true
        try? save(record)
    }

    // MARK: - Migration

    /// Runs (or resumes) the migration; returns once the legacy files
    /// are moved. Throws on any failure with nothing moved.
    func migrate() async throws {
        guard hasLegacyStore else { return }
        let fm = FileManager.default
        var record = loadRecord() ?? LegacyStoreMigrationRecord(
            folderName: Self.folderPrefix + Self.timestamp(now()))
        let folder = supportDirectory.appendingPathComponent(record.folderName)
        try fm.createDirectory(at: folder, withIntermediateDirectories: true)
        try save(record)

        if !record.pushDone {
            // Containers live only inside this call so every reference
            // is gone before the files move.
            record = try await pushLegacyData(record: record, folder: folder)
        }
        try moveStores(into: folder)
        record.completed = true
        try save(record)
    }

    private func pushLegacyData(
        record start: LegacyStoreMigrationRecord, folder: URL
    ) async throws -> LegacyStoreMigrationRecord {
        var record = start
        let appContainer = try AppModelContainer.makeLegacyOnDisk(
            directory: supportDirectory)
        let shadowContainer = try FinanceSyncSchema.makeContainer(
            directory: supportDirectory)
        let backupURL = folder.appendingPathComponent(Self.backupFileName)

        if !record.backupWritten
            || !FileManager.default.fileExists(atPath: backupURL.path) {
            let data = try BackupCodec.encode(context: ModelContext(appContainer))
            try data.write(to: backupURL, options: .atomic)
            record.backupWritten = true
            try save(record)
        }

        let shadow = SyncShadowStore(modelContainer: shadowContainer)
        var configured = record.wasSyncConfigured ?? false
        if record.wasSyncConfigured == nil {
            let state = try await shadow.state()
            let entries = try await shadow.entryCount()
            configured = state.isEnabled || state.pullCursor > 0 || entries > 0
        }
        record.wasSyncConfigured = configured
        try save(record)

        if configured {
            let engine = FinanceSyncEngine(
                modelContainer: appContainer, api: api, shadow: shadow,
                pullLimit: pullLimit)
            try await engine.syncOnce(fullScan: true)
            let verify = try await engine.syncOnce(fullScan: true)
            guard verify.pushedUpserts + verify.pushedDeletes == 0 else {
                throw LegacyStoreMigrationError.notConverged
            }
            record.quarantinedCount = try await shadow.quarantines().count
        } else {
            let head = try await api.head()
            if head == 0 {
                record.importAttempted = true
                try save(record)
                _ = try await api.importBackup(Data(contentsOf: backupURL))
                record.importedLegacy = true
            } else if record.importAttempted {
                // A previous attempt's import committed before the
                // crash — the server already holds the legacy data.
                record.importedLegacy = true
            } else {
                record.serverWon = true
            }
        }
        record.pushDone = true
        try save(record)
        return record
    }

    /// Moves `default.store*` and `FinanceSync.store*` into `folder` —
    /// never deletes. The shadow goes first and the bare `default.store`
    /// last, so a crash in between still reads as "legacy present".
    private func moveStores(into folder: URL) throws {
        let fm = FileManager.default
        let appName = AppModelContainer.legacyStoreFileName
        let shadowFiles = storeFiles(prefix: FinanceSyncSchema.storeFileName)
        let appFiles = storeFiles(prefix: appName)
        let ordered = shadowFiles
            + appFiles.filter { $0.lastPathComponent != appName }
            + appFiles.filter { $0.lastPathComponent == appName }
        for source in ordered {
            let destination = folder.appendingPathComponent(source.lastPathComponent)
            do {
                try fm.moveItem(at: source, to: destination)
            } catch {
                throw LegacyStoreMigrationError.moveFailed(source.lastPathComponent)
            }
        }
    }

    private static func timestamp(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.dateFormat = "yyyyMMdd-HHmmss"
        return formatter.string(from: date)
    }
}
