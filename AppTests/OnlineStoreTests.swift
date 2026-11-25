import FinanceCore
import Foundation
import SwiftData
import Testing
@testable import AMFinance

/// The online-only launch: export → in-memory restore → shadow = local
/// hashes at `syncSeq` → one engine cycle, the `OnlineStore` phases, and
/// the one-time legacy on-disk migration. Server = the shared
/// `FakeSyncServer` (export + syncSeq, head, outage seam).
@Suite(.serialized)
@MainActor
struct OnlineStoreTests {

    /// Rows `seedFullLedger` inserts.
    private static let seededRowCount = 22

    // MARK: - Scaffolding

    private final class SignInFlag: @unchecked Sendable {
        var value: Bool
        init(_ value: Bool) { self.value = value }
    }

    private func makeStore(
        server: FakeSyncServer,
        device: SyncTestDevice,
        migrator: LegacyStoreMigrator? = nil,
        signedIn: SignInFlag = SignInFlag(true)
    ) -> OnlineStore {
        OnlineStore(
            container: device.container,
            api: syncTestClient(for: server),
            bootstrap: device.bootstrap,
            migrator: migrator,
            isSignedIn: { signedIn.value },
            signIn: { signedIn.value = true })
    }

    /// A server already holding the full seeded ledger, uploaded by
    /// another device.
    private func serverWithLedger() async throws -> (FakeSyncServer, FullLedgerIDs) {
        let server = FakeSyncServer()
        let other = try makeSyncDevice(server: server)
        let ids = try seedFullLedger(in: other.context)
        try await other.bootstrap.uploadReplace()
        return (server, ids)
    }

    private func tempDirectory() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("online-store-\(UUID().uuidString)")
        try FileManager.default.createDirectory(
            at: url, withIntermediateDirectories: true)
        return url
    }

    // MARK: - Load

    @Test func loadRestoresAllEntitiesAndSeedsShadowAtSyncSeq() async throws {
        let (server, _) = try await serverWithLedger()
        let device = try makeSyncDevice(server: server)
        let api = syncTestClient(for: server)

        let snapshot = try await api.exportSnapshot()
        #expect(snapshot.syncSeq == server.highWaterSeq)
        #expect(snapshot.syncSeq > 0)

        let report = try await device.bootstrap.loadOnline(snapshot: snapshot)
        #expect(report.restoreInserted == Self.seededRowCount)
        #expect(report.sync?.pushedUpserts == 0)
        #expect(report.sync?.pushedDeletes == 0)
        #expect(report.sync?.applied == 0)

        let probe = try await device.bootstrap.probe()
        #expect(probe.localTotal == Self.seededRowCount)
        #expect(probe.localCounts[.account] == 5)
        #expect(probe.localCounts[.category] == 3)
        #expect(probe.localCounts[.business] == 1)
        #expect(probe.localCounts[.transaction] == 6)
        #expect(probe.localCounts[.loanRateChange] == 1)
        #expect(probe.localCounts[.budget] == 2)
        #expect(probe.localCounts[.recurringRule] == 2)
        #expect(probe.localCounts[.rentalUnit] == 1)
        #expect(probe.localCounts[.rentalLease] == 1)

        // Shadow == local content hashes, cursor == syncSeq, enabled.
        let local = try await device.engine.localContentHashes()
        #expect(try await device.shadow.snapshot() == local)
        #expect(try await device.shadow.pullCursor() == snapshot.syncSeq)
        #expect(try await device.shadow.isEnabled())
        // The server pushed nothing new and the pull started at syncSeq.
        #expect(server.committedPushCount == 1)   // the other device's seed
        #expect(server.pullCursors.first == snapshot.syncSeq)
    }

    @Test func firstCyclePullsOnlyRecordsNewerThanTheSnapshot() async throws {
        let (server, _) = try await serverWithLedger()
        let device = try makeSyncDevice(server: server)
        let snapshot = try await syncTestClient(for: server).exportSnapshot()

        // Another device writes between the export and the first cycle.
        let newCategory = LedgerCategory(name: "Mới 🆕", kind: .expense)
        let dto = BackupCategory(newCategory)
        let newSeq = server.putRecord(
            entity: "category", id: newCategory.id,
            data: try SyncRecordMapper.jsonValue(of: .category(dto)))
        #expect(newSeq > snapshot.syncSeq)

        let report = try await device.bootstrap.loadOnline(snapshot: snapshot)
        #expect(report.sync?.pulled == 1)
        #expect(report.sync?.applied == 1)
        #expect(report.sync?.pushedUpserts == 0)
        #expect(server.pullCursors.allSatisfy { $0 >= snapshot.syncSeq })
        #expect(try await device.shadow.pullCursor() == newSeq)
        #expect(try device.context.fetchCount(FetchDescriptor<LedgerCategory>(
            predicate: #Predicate { $0.name == "Mới 🆕" })) == 1)
    }

    @Test func syncSeqPrefersBodyAndFallsBackToHeader() async throws {
        let (server, _) = try await serverWithLedger()
        let api = syncTestClient(for: server)

        server.exportHeaderSeqOverride = 999
        #expect(try await api.exportSnapshot().syncSeq == server.highWaterSeq)

        server.exportOmitsBodySeq = true
        server.exportHeaderSeqOverride = nil
        #expect(try await api.exportSnapshot().syncSeq == server.highWaterSeq)
        server.exportHeaderSeqOverride = 77
        #expect(try await api.exportSnapshot().syncSeq == 77)
    }

    @Test func headReportsHighWater() async throws {
        let server = FakeSyncServer()
        let api = syncTestClient(for: server)
        #expect(try await api.head() == 0)
        server.putRecord(entity: "category", id: UUID(), deleted: true, data: nil)
        #expect(try await api.head() == 1)
    }

    @Test func emptyServerSeedsInMemoryAndPushesTheSeed() async throws {
        let server = FakeSyncServer()
        let device = try makeSyncDevice(server: server)
        let store = makeStore(server: server, device: device)

        await store.start()
        #expect(store.phase == .ready)

        let accounts = try device.context.fetchCount(FetchDescriptor<Account>())
        let businesses = try device.context.fetchCount(FetchDescriptor<Business>())
        let categories = try device.context.fetchCount(FetchDescriptor<LedgerCategory>())
        let seeded = accounts + businesses + categories
        #expect(seeded > 0)
        #expect(server.liveRowCount == seeded)
        #expect(try await device.shadow.isEnabled())
        let local = try await device.engine.localContentHashes()
        #expect(try await device.shadow.snapshot() == local)
        #expect(try await device.shadow.pullCursor() > 0)
    }

    @Test func nonEmptyServerIsNeverSeeded() async throws {
        let (server, _) = try await serverWithLedger()
        let device = try makeSyncDevice(server: server)
        let store = makeStore(server: server, device: device)

        await store.start()
        #expect(store.phase == .ready)
        #expect(try device.context.fetchCount(FetchDescriptor<Account>()) == 5)
        #expect(server.liveRowCount == Self.seededRowCount)
    }

    // MARK: - Phases

    @Test func signedOutThenSignInLoads() async throws {
        let (server, _) = try await serverWithLedger()
        let device = try makeSyncDevice(server: server)
        let flag = SignInFlag(false)
        let store = makeStore(server: server, device: device, signedIn: flag)

        #expect(store.phase == .starting)
        await store.start()
        #expect(store.phase == .signedOut)
        #expect(server.exportCount == 0)

        await store.signIn()
        #expect(store.phase == .ready)
        #expect(server.exportCount == 1)
    }

    @Test func serverFailureFailsThenRetrySucceeds() async throws {
        let (server, _) = try await serverWithLedger()
        let device = try makeSyncDevice(server: server)
        let store = makeStore(server: server, device: device)

        server.setFailure(pathSuffix: "/v1/backup/export", status: 500)
        await store.start()
        guard case .failed(let message) = store.phase else {
            Issue.record("expected failed, got \(store.phase)")
            return
        }
        #expect(!message.isEmpty)
        #expect(!store.isReady)

        server.setFailure(pathSuffix: "/v1/backup/export", status: nil)
        await store.retry()
        #expect(store.phase == .ready)
        #expect(try device.context.fetchCount(FetchDescriptor<Account>()) == 5)
    }

    @Test func rejectedSessionFallsBackToSignedOut() async throws {
        let (server, _) = try await serverWithLedger()
        let device = try makeSyncDevice(server: server)
        let store = makeStore(server: server, device: device)

        server.setFailure(pathSuffix: "/v1/backup/export", status: 401)
        await store.start()
        #expect(store.phase == .signedOut)
    }

    @Test func onlinePipelineLaunchGate() {
        #expect(OnlineStore.usesOnlinePipeline(arguments: []))
        #expect(!OnlineStore.usesOnlinePipeline(
            arguments: ["-uiTestInMemoryStore"]))
        #expect(!OnlineStore.usesOnlinePipeline(
            arguments: ["-uiTestInMemoryStore", "-uiTestOnline"]))
        #expect(!OnlineStore.usesOnlinePipeline(
            arguments: ["-uiTestInMemoryStore", "-uiTestFakeSyncServer"]))
        #expect(OnlineStore.usesOnlinePipeline(arguments: [
            "-uiTestInMemoryStore", "-uiTestFakeSyncServer", "-uiTestOnline",
        ]))
    }

    // MARK: - Legacy store location

    @Test func defaultStoreLocationIsDefaultStoreInApplicationSupport() {
        let configuration = ModelConfiguration(
            schema: Schema(AppSchema.allModels), cloudKitDatabase: .none)
        let support = FileManager.default
            .urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        #expect(configuration.url.lastPathComponent
                == AppModelContainer.legacyStoreFileName)
        #expect(configuration.url.deletingLastPathComponent().standardizedFileURL
                == support.standardizedFileURL)
    }

    // MARK: - Legacy migration

    /// An on-disk legacy install in `directory`: the seeded app store and
    /// its shadow. `syncEnabled` first uploads it to `server` the way the
    /// old first-sync did; `pendingEdit` then leaves one unpushed edit.
    /// Every container is released when this returns.
    private func makeLegacyInstall(
        in directory: URL, server: FakeSyncServer,
        syncEnabled: Bool, pendingEdit: String? = nil
    ) async throws -> FullLedgerIDs {
        let app = try AppModelContainer.makeLegacyOnDisk(directory: directory)
        let shadowContainer = try FinanceSyncSchema.makeContainer(
            directory: directory)
        let context = ModelContext(app)
        let ids = try seedFullLedger(in: context)
        let shadow = SyncShadowStore(modelContainer: shadowContainer)
        if syncEnabled {
            let api = syncTestClient(for: server)
            let engine = FinanceSyncEngine(
                modelContainer: app, api: api, shadow: shadow)
            let bootstrap = FinanceSyncBootstrap(
                modelContainer: app, api: api, engine: engine, shadow: shadow)
            try await bootstrap.uploadReplace()
        } else {
            _ = try await shadow.entryCount()
        }
        if let pendingEdit {
            let tx = try #require(try context.fetch(FetchDescriptor<LedgerTransaction>(
                predicate: #Predicate { $0.note == "cà phê sáng ☕️🥐 đặc biệt" })).first)
            tx.note = pendingEdit
            tx.updatedAt = .now
            try context.save()
        }
        return ids
    }

    private func names(in directory: URL, prefix: String) -> [String] {
        ((try? FileManager.default.contentsOfDirectory(atPath: directory.path)) ?? [])
            .filter { $0.hasPrefix(prefix) }.sorted()
    }

    private func legacyFolders(in directory: URL) -> [URL] {
        names(in: directory, prefix: LegacyStoreMigrator.folderPrefix)
            .map { directory.appendingPathComponent($0) }
    }

    private func noteOnServer(
        _ server: FakeSyncServer, id: UUID
    ) -> String? {
        guard case .object(let fields)? = server.row(
            entity: "transaction", id: id)?.data,
              case .string(let note)? = fields["note"] else { return nil }
        return note
    }

    private func assertMoved(_ directory: URL) throws -> URL {
        #expect(names(in: directory, prefix: "default.store").isEmpty)
        #expect(names(in: directory, prefix: "FinanceSync.store").isEmpty)
        let folder = try #require(legacyFolders(in: directory).first)
        #expect(legacyFolders(in: directory).count == 1)
        #expect(names(in: folder, prefix: "default.store")
            .contains("default.store"))
        #expect(names(in: folder, prefix: "FinanceSync.store")
            .contains("FinanceSync.store"))
        let backup = try Data(contentsOf: folder
            .appendingPathComponent(LegacyStoreMigrator.backupFileName))
        let document = try BackupCodec.decode(backup)
        #expect(document.transactions.count == 6)
        return folder
    }

    @Test func syncEnabledLegacyPushesPendingEditThenMovesFiles() async throws {
        let directory = try tempDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let server = FakeSyncServer()
        let ids = try await makeLegacyInstall(
            in: directory, server: server,
            syncEnabled: true, pendingEdit: "sửa trước khi chuyển")
        #expect(noteOnServer(server, id: ids.expenseTx)
                == "cà phê sáng ☕️🥐 đặc biệt")
        let migrator = LegacyStoreMigrator(
            supportDirectory: directory, api: syncTestClient(for: server))
        #expect(migrator.hasLegacyStore)

        try await migrator.migrate()

        #expect(noteOnServer(server, id: ids.expenseTx) == "sửa trước khi chuyển")
        let folder = try assertMoved(directory)
        // The backup was written BEFORE the push: it holds the edit.
        let document = try BackupCodec.decode(Data(contentsOf: folder
            .appendingPathComponent(LegacyStoreMigrator.backupFileName)))
        #expect(document.transactions.contains { $0.note == "sửa trước khi chuyển" })
        #expect(!migrator.hasLegacyStore)
        #expect(migrator.pendingNotice == nil)
        #expect(migrator.loadRecord()?.completed == true)

        // And the app then loads exactly that server state.
        let device = try makeSyncDevice(server: server)
        let store = makeStore(server: server, device: device, migrator: migrator)
        await store.start()
        #expect(store.phase == .ready)
        let loaded = try #require(try device.context.fetch(
            FetchDescriptor<LedgerTransaction>(predicate: #Predicate {
                $0.note == "sửa trước khi chuyển" })).first)
        #expect(loaded.amount == 45_000)
    }

    @Test func legacyServerFailureMovesNothingAndRetryResumes() async throws {
        let directory = try tempDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let server = FakeSyncServer()
        let ids = try await makeLegacyInstall(
            in: directory, server: server,
            syncEnabled: true, pendingEdit: "chưa đẩy được")
        let migrator = LegacyStoreMigrator(
            supportDirectory: directory, api: syncTestClient(for: server))
        let device = try makeSyncDevice(server: server)
        let store = makeStore(server: server, device: device, migrator: migrator)

        server.setFailure(pathSuffix: "/v1/sync/pull", status: 500)
        await store.start()

        guard case .failed(let message) = store.phase else {
            Issue.record("expected failed, got \(store.phase)")
            return
        }
        #expect(!message.isEmpty)
        // Nothing moved; the backup is already safe on disk.
        #expect(names(in: directory, prefix: "default.store")
            .contains("default.store"))
        #expect(names(in: directory, prefix: "FinanceSync.store")
            .contains("FinanceSync.store"))
        #expect(migrator.hasLegacyStore)
        let folders = legacyFolders(in: directory)
        #expect(folders.count == 1)
        #expect(FileManager.default.fileExists(atPath: folders[0]
            .appendingPathComponent(LegacyStoreMigrator.backupFileName).path))
        #expect(noteOnServer(server, id: ids.expenseTx)
                == "cà phê sáng ☕️🥐 đặc biệt")
        #expect(try device.context.fetchCount(FetchDescriptor<Account>()) == 0)

        // Retry after the outage: same folder, edit pushed, files moved.
        server.setFailure(pathSuffix: "/v1/sync/pull", status: nil)
        await store.retry()
        #expect(store.phase == .ready)
        _ = try assertMoved(directory)
        #expect(noteOnServer(server, id: ids.expenseTx) == "chưa đẩy được")
    }

    @Test func neverEnabledLegacyWithEmptyServerIsImported() async throws {
        let directory = try tempDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let server = FakeSyncServer()
        _ = try await makeLegacyInstall(
            in: directory, server: server, syncEnabled: false)
        let migrator = LegacyStoreMigrator(
            supportDirectory: directory, api: syncTestClient(for: server))

        // A failing head check aborts before anything moves or imports.
        server.setFailure(pathSuffix: "/v1/sync/head", status: 500)
        await #expect(throws: FinanceSyncError.self) {
            try await migrator.migrate()
        }
        #expect(server.importBodies.isEmpty)
        #expect(migrator.hasLegacyStore)
        #expect(names(in: directory, prefix: "default.store")
            .contains("default.store"))

        server.setFailure(pathSuffix: "/v1/sync/head", status: nil)
        try await migrator.migrate()

        #expect(server.importBodies.count == 1)
        #expect(server.liveRowCount == Self.seededRowCount)
        _ = try assertMoved(directory)
        #expect(migrator.loadRecord()?.importedLegacy == true)
        #expect(migrator.pendingNotice == nil)
    }

    @Test func neverEnabledLegacyWithNonEmptyServerIsNotImported() async throws {
        let directory = try tempDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let (server, _) = try await serverWithLedger()
        let importsBefore = server.importBodies.count
        let liveBefore = server.liveRowCount
        _ = try await makeLegacyInstall(
            in: directory, server: server, syncEnabled: false)
        let migrator = LegacyStoreMigrator(
            supportDirectory: directory, api: syncTestClient(for: server))

        try await migrator.migrate()

        #expect(server.importBodies.count == importsBefore)
        #expect(server.liveRowCount == liveBefore)
        _ = try assertMoved(directory)
        let record = try #require(migrator.loadRecord())
        #expect(record.serverWon && !record.importedLegacy)
        let notice = try #require(migrator.pendingNotice)
        #expect(notice.contains("chưa từng đồng bộ"))
        #expect(notice.contains("legacy-backup.json"))

        migrator.dismissNotice()
        #expect(migrator.pendingNotice == nil)
    }

    @Test func quarantinedLegacyRecordsAreCountedForTheNotice() async throws {
        let directory = try tempDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let server = FakeSyncServer()
        _ = try await makeLegacyInstall(
            in: directory, server: server,
            syncEnabled: true, pendingEdit: "reject-me")
        server.validator = { change in
            if case .object(let fields)? = change.data,
               fields["note"] == .string("reject-me") {
                return ("note", "test", "bị từ chối")
            }
            return nil
        }
        let migrator = LegacyStoreMigrator(
            supportDirectory: directory, api: syncTestClient(for: server))

        try await migrator.migrate()

        let folder = try assertMoved(directory)
        #expect(migrator.loadRecord()?.quarantinedCount == 1)
        let notice = try #require(migrator.pendingNotice)
        #expect(notice.contains("1 bản ghi"))
        // The rejected edit lives only in the backup file.
        let document = try BackupCodec.decode(Data(contentsOf: folder
            .appendingPathComponent(LegacyStoreMigrator.backupFileName)))
        #expect(document.transactions.contains { $0.note == "reject-me" })
    }

    @Test func installWithoutLegacyStoreSkipsMigration() async throws {
        let directory = try tempDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let server = FakeSyncServer()
        let migrator = LegacyStoreMigrator(
            supportDirectory: directory, api: syncTestClient(for: server))
        #expect(!migrator.hasLegacyStore)
        try await migrator.migrate()
        #expect(legacyFolders(in: directory).isEmpty)
        #expect(server.headCount == 0)
    }
}
