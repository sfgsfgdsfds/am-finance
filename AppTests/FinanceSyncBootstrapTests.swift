import FinanceCore
import Foundation
import SwiftData
import Testing
@testable import AMFinance

/// `FinanceSyncBootstrap` first-sync modes against the shared fake
/// server in `FinanceSyncTestSupport.swift`: probe, uploadReplace,
/// downloadReplace and the refusal/resume rules. Serialized — the
/// URLProtocol seam is one static.
@Suite(.serialized)
struct FinanceSyncBootstrapTests {

    /// Rows `seedFullLedger` inserts — kept explicit so counter
    /// assertions stay readable.
    private static let seededRowCount = 22

    // MARK: - Probe

    @Test func probeReportsServerAndLocalState() async throws {
        let server = FakeSyncServer()
        let device = try makeSyncDevice(server: server)
        _ = try seedFullLedger(in: device.context)

        let probe = try await device.bootstrap.probe()
        #expect(probe.serverEmpty)
        #expect(probe.shadowEmpty)
        #expect(probe.localTotal == Self.seededRowCount)
        #expect(probe.localCounts[.transaction] == 6)
        #expect(probe.localCounts[.account] == 5)
        #expect(probe.localCounts[.rentalLease] == 1)
        #expect(!probe.isEnabled)
        #expect(probe.pullCursor == 0)

        _ = try await device.bootstrap.uploadReplace()
        let after = try await device.bootstrap.probe()
        #expect(!after.serverEmpty)
        #expect(!after.shadowEmpty)
        #expect(after.isEnabled)
        #expect(after.pullCursor > 0)
    }

    // MARK: - Upload → download convergence

    @Test func uploadThenSecondDeviceDownloadConverges() async throws {
        let server = FakeSyncServer()
        let a = try makeSyncDevice(server: server)
        _ = try seedFullLedger(in: a.context)

        let up = try await a.bootstrap.uploadReplace()
        #expect(up.exportedRows == Self.seededRowCount)
        #expect(up.importUpserted == Self.seededRowCount)
        #expect(up.importTombstoned == 0)
        #expect(up.sync?.pushedUpserts == 0)
        #expect(up.sync?.pushedDeletes == 0)
        #expect(try await a.shadow.isEnabled())
        #expect(server.liveRowCount == Self.seededRowCount)
        #expect(server.importBodies.count == 1)
        // The reconcile pull stamped real server seqs into the shadow.
        #expect(try await a.shadow.allEntries().allSatisfy { $0.serverSeq > 0 })

        // A second device downloads — small page size exercises paging.
        let b = try makeSyncDevice(server: server, pullLimit: 4)
        let down = try await b.bootstrap.downloadReplace()
        #expect(down.pagesPulled == 6)   // 22 records, 4 per page
        #expect(down.recordsDownloaded == Self.seededRowCount)
        #expect(down.restoreInserted == Self.seededRowCount)
        #expect(down.sync?.pushedUpserts == 0)
        #expect(down.sync?.pushedDeletes == 0)
        #expect(try await b.shadow.isEnabled())

        #expect(try await a.engine.localContentHashes()
                == b.engine.localContentHashes())

        // Relationships survived the round trip — the rent row still
        // points at its lease and period, the transfer at both accounts.
        let rent = try #require(try b.context.fetch(FetchDescriptor<LedgerTransaction>(
            predicate: #Predicate { $0.rentalPeriod != nil })).first)
        #expect(rent.rentalLease != nil)
        let transfer = try #require(try b.context.fetch(FetchDescriptor<LedgerTransaction>(
            predicate: #Predicate { $0.kindRaw == "transfer" })).first)
        #expect(transfer.account != nil && transfer.toAccount != nil)
    }

    // MARK: - Download replaces different local data

    @Test func downloadReplaceOverDifferentLocalDataConverges() async throws {
        let server = FakeSyncServer()
        let a = try makeSyncDevice(server: server)
        _ = try seedFullLedger(in: a.context)
        _ = try await a.bootstrap.uploadReplace()

        // A record whose entity this build does not know, and a bare
        // tombstone — both are skipped, neither is fatal.
        server.putRecord(entity: "mystery", id: UUID(),
                         data: .object(["x": .int(1)]))
        server.putRecord(entity: "category", id: UUID(),
                         deleted: true, data: nil)

        let b = try makeSyncDevice(server: server)
        // B's own different local data — the replace wipes it all.
        let stranger = Account(
            name: "Tài khoản lạ", kind: .eWallet, openingBalance: 5)
        let stray = LedgerTransaction(
            kind: .expense, amount: 7, note: "sẽ bị xoá")
        stray.account = stranger
        b.context.insert(stranger)
        b.context.insert(stray)
        try b.context.save()

        let report = try await b.bootstrap.downloadReplace()
        #expect(report.recordsDownloaded == Self.seededRowCount)
        #expect(report.unknownSkipped == 1)
        #expect(report.tombstonesSkipped == 1)
        #expect(report.sync?.pushedUpserts == 0)
        #expect(report.sync?.pushedDeletes == 0)

        #expect(try b.context.fetchCount(FetchDescriptor<LedgerTransaction>(
            predicate: #Predicate { $0.note == "sẽ bị xoá" })) == 0)
        #expect(try b.context.fetchCount(FetchDescriptor<Account>(
            predicate: #Predicate { $0.name == "Tài khoản lạ" })) == 0)
        #expect(try await a.engine.localContentHashes()
                == b.engine.localContentHashes())
    }

    // MARK: - Upload tombstones server extras

    @Test func uploadReplaceTombstonesServerExtras() async throws {
        let server = FakeSyncServer()
        let ghostID = UUID()
        server.putRecord(
            entity: "category", id: ghostID,
            data: try SyncRecordMapper.jsonValue(of: .category(BackupCategory(
                id: ghostID, name: "Ma danh mục", kindRaw: "expense",
                icon: "", colorHex: "", sortOrder: 0, isArchived: false))))

        // B downloads first and owns the ghost row.
        let b = try makeSyncDevice(server: server)
        _ = try await b.bootstrap.downloadReplace()
        #expect(try b.context.fetchCount(FetchDescriptor<LedgerCategory>(
            predicate: #Predicate { $0.id == ghostID })) == 1)

        // A uploads different data — REPLACE tombstones the ghost.
        let a = try makeSyncDevice(server: server)
        _ = try seedFullLedger(in: a.context)
        let up = try await a.bootstrap.uploadReplace()
        #expect(up.importTombstoned == 1)
        #expect(server.row(entity: "category", id: ghostID)?.deleted == true)

        // B's next sync pulls the tombstone — gone there too.
        let bSync = try await b.engine.syncOnce()
        #expect(bSync.deletedLocally == 1)
        #expect(try b.context.fetchCount(FetchDescriptor<LedgerCategory>(
            predicate: #Predicate { $0.id == ghostID })) == 0)
        #expect(try await a.engine.localContentHashes()
                == b.engine.localContentHashes())
    }

    // MARK: - Refusals and resume

    @Test func bootstrapRefusesConcurrentBootstrap() async throws {
        let server = FakeSyncServer()
        server.holdPulls = true
        let device = try makeSyncDevice(server: server)
        _ = try seedFullLedger(in: device.context)

        // The first bootstrap reaches its reconcile pull — the delivery
        // parks, the load stays open asynchronously.
        // (capture the Sendable actor, not the whole device struct)
        let bootstrap = device.bootstrap
        let first = Task { try await bootstrap.uploadReplace() }
        #expect(await waitForTrue { server.heldPullCount > 0 })
        // Only that one pull stays parked; later ones pass through.
        server.holdPulls = false

        do {
            _ = try await device.bootstrap.uploadReplace()
            Issue.record("expected alreadyRunning")
        } catch let error as FinanceSyncBootstrapError {
            #expect(error == .alreadyRunning)
        }
        // A read-only probe is still allowed mid-bootstrap.
        _ = try await device.bootstrap.probe()

        server.releaseHeldPulls()
        let report = try await first.value
        #expect(report.importUpserted == Self.seededRowCount)
        #expect(try await device.shadow.isEnabled())
    }

    @Test func bootstrapRefusesWhileEngineSyncRuns() async throws {
        let server = FakeSyncServer()
        let a = try makeSyncDevice(server: server)
        _ = try seedFullLedger(in: a.context)
        _ = try await a.bootstrap.uploadReplace()

        let b = try makeSyncDevice(server: server)
        server.holdPulls = true

        // An engine cycle opens and parks inside its pull.
        let engine = b.engine
        let syncTask = Task { try await engine.syncOnce() }
        #expect(await waitForTrue { server.heldPullCount > 0 })
        // The engine's pull stays parked; the bootstrap's own pulls
        // below pass through so the run reaches its reconcile step.
        server.holdPulls = false

        do {
            _ = try await b.bootstrap.downloadReplace()
            Issue.record("expected syncInProgress")
        } catch let error as FinanceSyncBootstrapError {
            #expect(error == .syncInProgress)
        }
        #expect(try await b.shadow.isEnabled() == false)

        server.releaseHeldPulls()
        _ = try? await syncTask.value

        // With the engine idle again the retry completes and enables.
        let report = try await b.bootstrap.downloadReplace()
        #expect(report.recordsDownloaded == Self.seededRowCount)
        #expect(try await b.shadow.isEnabled())
        let bVerify = FinanceSyncEngine(
            modelContainer: b.container,
            api: syncTestClient(for: server), shadow: b.shadow)
        #expect(try await a.engine.localContentHashes()
                == bVerify.localContentHashes())
    }

    @Test func failedImportLeavesSyncDisabledAndRetrySucceeds() async throws {
        let server = FakeSyncServer()
        server.failNextImport = URLError(.networkConnectionLost)
        let device = try makeSyncDevice(server: server)
        _ = try seedFullLedger(in: device.context)

        do {
            _ = try await device.bootstrap.uploadReplace()
            Issue.record("expected a transport error")
        } catch let error as FinanceSyncError {
            guard case .transport = error else {
                Issue.record("expected .transport, got \(error)")
                return
            }
        }
        // Nothing half-enabled; the shadow is still untouched.
        #expect(try await device.shadow.isEnabled() == false)
        #expect(try await device.shadow.entryCount() == 0)
        #expect(server.importBodies.count == 1)

        // The same call retried completes the replace cleanly.
        let report = try await device.bootstrap.uploadReplace()
        #expect(report.importUpserted == Self.seededRowCount)
        #expect(try await device.shadow.isEnabled())
        #expect(server.importBodies.count == 2)
        #expect(server.liveRowCount == Self.seededRowCount)
    }
}
