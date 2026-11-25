import FinanceCore
import Foundation
import SwiftData
import Testing
@testable import AMFinance

/// `FinanceSyncEngine` end-to-end against the in-memory fake server in
/// `FinanceSyncTestSupport.swift` — it implements the sync contract
/// faithfully: per-user monotonic seq, rows with seq + tombstones, `409`
/// when a touched row's seq > `base_seq`, deferred per-batch FK
/// validation → `422` `index`, idempotent replay by key + body, pull
/// paging with `limit`. Serialized — the URLProtocol seam is one static
/// and engine tests share the process.
@Suite(.serialized)
struct FinanceSyncEngineTests {

    private func makeDevice(
        server: FakeSyncServer, pullLimit: Int = 500
    ) throws -> SyncTestDevice {
        try makeSyncDevice(server: server, pullLimit: pullLimit)
    }

    private func transaction(
        _ context: ModelContext, id: UUID
    ) throws -> LedgerTransaction {
        try #require(try context.fetch(FetchDescriptor<LedgerTransaction>(
            predicate: #Predicate { $0.id == id })).first)
    }

    private func account(
        _ context: ModelContext, id: UUID
    ) throws -> Account {
        try #require(try context.fetch(FetchDescriptor<Account>(
            predicate: #Predicate { $0.id == id })).first)
    }

    /// A minimal ledger — account + category + expense tx — returning ids.
    @discardableResult
    private func seedLedger(
        in context: ModelContext, note: String = "cà phê"
    ) throws -> (accountID: UUID, txID: UUID, categoryID: UUID) {
        let account = Account(name: "Tiền mặt", kind: .cash, openingBalance: 100_000)
        let category = LedgerCategory(name: "Ăn uống", kind: .expense)
        let tx = LedgerTransaction(kind: .expense, amount: 45_000, note: note)
        tx.account = account
        tx.category = category
        context.insert(account)
        context.insert(category)
        context.insert(tx)
        try context.save()
        return (account.id, tx.id, category.id)
    }

    /// One string field out of a row's stored DTO on the fake server.
    private func serverField(
        _ server: FakeSyncServer, entity: String, id: UUID, field: String
    ) -> SyncJSONValue? {
        guard case .object(let fields)? = server.row(entity: entity, id: id)?.data
        else { return nil }
        return fields[field]
    }

    // MARK: - Push from empty

    @Test func emptyStorePushesAllRowsThenOwnWritesAreNoOps() async throws {
        let server = FakeSyncServer()
        let device = try makeDevice(server: server)
        let (accountID, txID, _) = try seedLedger(in: device.context)

        let first = try await device.engine.syncOnce()
        #expect(first.pulled == 0)
        #expect(first.pushedUpserts == 3)
        #expect(first.pushedDeletes == 0)
        #expect(first.conflictsKeptLocal == 0)
        #expect(server.liveRowCount == 3)
        #expect(server.row(entity: "account", id: accountID)?.deleted == false)
        #expect(server.row(entity: "transaction", id: txID)?.deleted == false)

        // The pull cursor never jumps on push — the next cycle pulls our
        // own writes back and they apply as no-ops (hash equal → only
        // serverSeq is refreshed).
        let second = try await device.engine.syncOnce()
        #expect(second.pulled == 3)
        #expect(second.applied == 0)
        #expect(second.deletedLocally == 0)
        #expect(second.pushedUpserts == 0)
        #expect(second.pushedDeletes == 0)
        #expect(server.committedPushCount == 1)
        let entries = try await device.shadow.allEntries()
        #expect(entries.count == 3)
        #expect(entries.allSatisfy { $0.serverSeq > 0 })
    }

    // MARK: - Two devices

    @Test func secondDevicePullsEverythingAndConverges() async throws {
        let server = FakeSyncServer()
        let a = try makeDevice(server: server)
        let business = Business(name: "Quán", icon: "cup", colorHex: "FF8800")
        let account = Account(name: "Khách nợ", kind: .receivable)
        account.business = business
        let category = LedgerCategory(name: "Ăn uống", kind: .expense)
        let tx = LedgerTransaction(kind: .expense, amount: 45_000, note: "cà phê")
        tx.account = account
        tx.category = category
        tx.business = business
        let unit = RentalUnit(name: "Phòng 1", listPrice: 3_500_000)
        let lease = RentalLease(
            tenantName: "Nguyễn A", monthlyRent: 3_500_000, paymentDay: 5)
        lease.unit = unit
        for row: any PersistentModel in
            [business, account, category, tx, unit, lease] {
            a.context.insert(row)
        }
        try a.context.save()
        _ = try await a.engine.syncOnce()

        let b = try makeDevice(server: server)
        let report = try await b.engine.syncOnce()
        #expect(report.applied == 6)
        #expect(report.pushedUpserts == 0)

        #expect(try await a.engine.localContentHashes()
                == b.engine.localContentHashes())
        let leases = try b.context.fetch(FetchDescriptor<RentalLease>())
        #expect(leases.first?.unit?.name == "Phòng 1")
        let txs = try b.context.fetch(FetchDescriptor<LedgerTransaction>())
        #expect(txs.first?.account?.name == "Khách nợ")
        #expect(txs.first?.business?.name == "Quán")
    }

    @Test func editOnOneDeviceDeleteOnAnotherConverge() async throws {
        let server = FakeSyncServer()
        let a = try makeDevice(server: server)
        let (accountID, txID, _) = try seedLedger(in: a.context)
        _ = try await a.engine.syncOnce()
        let b = try makeDevice(server: server)
        _ = try await b.engine.syncOnce()

        // A edits the account name.
        try account(a.context, id: accountID).name = "Ví mới"
        try a.context.save()
        _ = try await a.engine.syncOnce()

        // B deletes the transaction.
        b.context.delete(try transaction(b.context, id: txID))
        try b.context.save()
        let bReport = try await b.engine.syncOnce()
        // B pulled A's account edit, pushed its delete.
        #expect(bReport.applied == 1)
        #expect(bReport.pushedDeletes == 1)

        // A pulls the tombstone — the row goes away everywhere.
        _ = try await a.engine.syncOnce()
        #expect(try await a.engine.localContentHashes()
                == b.engine.localContentHashes())
        #expect(try a.context.fetch(FetchDescriptor<LedgerTransaction>()).isEmpty)
        #expect(try account(a.context, id: accountID).name == "Ví mới")
    }

    @Test func concurrentEditKeepsLocalPendingOnLaterDevice() async throws {
        let server = FakeSyncServer()
        let a = try makeDevice(server: server)
        let (_, txID, _) = try seedLedger(in: a.context)
        _ = try await a.engine.syncOnce()
        let b = try makeDevice(server: server)
        _ = try await b.engine.syncOnce()

        // Both edit the same transaction offline — A's stamp older, B's newer.
        let txA = try transaction(a.context, id: txID)
        txA.note = "bản A"
        txA.updatedAt = Date(timeIntervalSince1970: 1_800_000_000)
        try a.context.save()
        let txB = try transaction(b.context, id: txID)
        txB.note = "bản B"
        txB.updatedAt = Date(timeIntervalSince1970: 1_800_000_100)
        try b.context.save()

        // A syncs first — its version lands on the server.
        _ = try await a.engine.syncOnce()
        // B syncs later: the pulled A-version meets a pending local edit
        // → local wins, B's version pushes instead.
        let reportB = try await b.engine.syncOnce()
        #expect(reportB.conflictsKeptLocal == 1)
        #expect(reportB.pushedUpserts == 1)
        #expect(serverField(
            server, entity: "transaction", id: txID, field: "note")
            == .string("bản B"))

        // A pulls once more — B's version applies (the newer updatedAt
        // wins the merge rule) and nothing else moved.
        _ = try await a.engine.syncOnce()
        #expect(try transaction(a.context, id: txID).note == "bản B")
        #expect(try await a.engine.localContentHashes()
                == b.engine.localContentHashes())
    }

    // MARK: - 409

    @Test func pushConflictPullsAndRetries() async throws {
        let server = FakeSyncServer()
        let a = try makeDevice(server: server)
        let (_, txID, _) = try seedLedger(in: a.context)
        _ = try await a.engine.syncOnce()
        let b = try makeDevice(server: server)
        _ = try await b.engine.syncOnce()

        // B edits the transaction — a pending change.
        let txB = try transaction(b.context, id: txID)
        txB.note = "bản B"
        txB.updatedAt = Date(timeIntervalSince1970: 1_800_000_200)
        try b.context.save()

        // Between B's pull and B's push another device lands a newer
        // version of the SAME row → the batch's base_seq is stale → 409.
        guard case .transaction(var interjectedDTO)? =
                SyncRecordMapper.dto(of: txB)
        else { Issue.record("tx did not map"); return }
        interjectedDTO.note = "bản server"
        interjectedDTO.updatedAt = Date(timeIntervalSince1970: 1_800_000_100)
        server.interject(
            entity: "transaction", id: txID,
            data: try SyncRecordMapper.jsonValue(of: .transaction(interjectedDTO)))

        let report = try await b.engine.syncOnce()
        #expect(report.retries409 == 1)
        // The retried pull met B's pending edit → local kept, pushed.
        #expect(report.conflictsKeptLocal == 1)
        #expect(report.pushedUpserts == 1)
        #expect(serverField(
            server, entity: "transaction", id: txID, field: "note")
            == .string("bản B"))
    }

    // MARK: - Deferred parent resolution

    @Test func childBeforeParentAcrossPageBoundaryResolves() async throws {
        let server = FakeSyncServer()
        let accountID = UUID()
        let txID = UUID()
        // The child record precedes its parent in seq order.
        server.putRecord(
            entity: "transaction", id: txID,
            data: try SyncRecordMapper.jsonValue(of: .transaction(BackupTransaction(
                id: txID, kindRaw: "expense", amount: 45_000,
                date: .now, note: "con trước",
                accountID: accountID, toAccountID: nil,
                categoryID: nil, businessID: nil, needsReview: false,
                externalSource: nil, externalID: nil,
                createdAt: .now, updatedAt: .now,
                rentalLeaseID: nil, rentalPeriod: nil))))
        server.putRecord(
            entity: "account", id: accountID,
            data: try SyncRecordMapper.jsonValue(of: .account(BackupAccount(
                id: accountID, name: "Tiền mặt", kindRaw: "cash",
                openingBalance: 100_000, icon: "banknote", colorHex: "",
                note: "", sortOrder: 0, isArchived: false, createdAt: .now,
                businessID: nil))))

        // One record per page — the parent lands strictly after the child.
        let device = try makeDevice(server: server, pullLimit: 1)
        let report = try await device.engine.syncOnce()
        #expect(report.pulled == 2)
        #expect(report.applied == 2)
        let tx = try transaction(device.context, id: txID)
        #expect(tx.account?.id == accountID)
    }

    // MARK: - 422 quarantine

    @Test func validationQuarantinesOneRecordUntilEdited() async throws {
        let server = FakeSyncServer()
        server.validator = { change in
            guard change.entity == .transaction,
                  case .object(let fields)? = change.data,
                  case .string(let note)? = fields["note"],
                  note == "INVALID"
            else { return nil }
            return ("note", "chk_note", "note is invalid")
        }
        let device = try makeDevice(server: server)
        let account = Account(name: "Tiền mặt", kind: .cash)
        let good = LedgerTransaction(kind: .expense, amount: 20_000, note: "ok")
        let bad = LedgerTransaction(kind: .expense, amount: 13_000, note: "INVALID")
        good.account = account
        bad.account = account
        device.context.insert(account)
        device.context.insert(good)
        device.context.insert(bad)
        try device.context.save()

        // The batch's bad record is quarantined; the rest still lands.
        let first = try await device.engine.syncOnce()
        #expect(first.quarantined == 1)
        #expect(first.pushedUpserts == 2)
        #expect(server.liveRowCount == 2)

        // Same content → the quarantined row is not retried.
        let second = try await device.engine.syncOnce()
        #expect(second.pushedUpserts == 0)
        let quarantines = try await device.shadow.quarantines()
        #expect(quarantines.count == 1)
        #expect(quarantines.first?.constraint == "chk_note")

        // Editing the row moves its hash → it retries and lands; the
        // quarantine releases on the ack.
        bad.note = "đã sửa"
        bad.updatedAt = .now
        try device.context.save()
        let third = try await device.engine.syncOnce()
        #expect(third.pushedUpserts == 1)
        #expect(try await device.shadow.quarantines().isEmpty)
        #expect(server.liveRowCount == 3)
        #expect(serverField(
            server, entity: "transaction", id: bad.id, field: "note")
            == .string("đã sửa"))
    }

    // MARK: - Crash / idempotent replay

    @Test func crashedPushReplaysSameKeyAndBody() async throws {
        let server = FakeSyncServer()
        let device = try makeDevice(server: server)
        let accountID = UUID()
        device.context.insert(Account(
            id: accountID, name: "Tiền mặt", kind: .cash, openingBalance: 7))
        try device.context.save()
        server.dropResponsesAfterCommit = 1

        // The batch commits server-side but the response never arrives.
        do {
            _ = try await device.engine.syncOnce()
            Issue.record("expected a transport error")
        } catch let error as FinanceSyncError {
            guard case .transport = error else {
                Issue.record("expected .transport, got \(error)")
                return
            }
        }
        #expect(server.row(entity: "account", id: accountID)?.deleted == false)
        let pending = try #require(try await device.shadow.pendingPush())
        #expect(pending.body != nil)

        // "Relaunch": a new engine over the same stores replays the stored
        // bytes — the server de-dupes by key+body and returns the same 200.
        let engine2 = FinanceSyncEngine(
            modelContainer: device.container,
            api: syncTestClient(for: server), shadow: device.shadow)
        let report = try await engine2.syncOnce()
        #expect(report.pushedUpserts == 1)
        #expect(server.committedPushCount == 1)
        #expect(server.pushBodies.count == 2)
        #expect(server.pushBodies[0] == server.pushBodies[1])
        #expect(try await device.shadow.pendingPush() == nil)
        #expect(try await device.shadow.serverSeq(
            entity: .account, recordID: accountID) != nil)
    }

    // MARK: - FK-ordered deletes

    @Test func deletingParentPushesNullifiedChildFirst() async throws {
        let server = FakeSyncServer()
        let device = try makeDevice(server: server)
        let (accountID, txID, _) = try seedLedger(in: device.context)
        _ = try await device.engine.syncOnce()

        // Delete only the account — the child's reference nullifies, so
        // the batch is [upsert tx, delete account] and the server's FK
        // check stays satisfied.
        device.context.delete(try account(device.context, id: accountID))
        try device.context.save()
        let report = try await device.engine.syncOnce()
        #expect(report.pushedUpserts == 1)
        #expect(report.pushedDeletes == 1)

        let sent = try JSONDecoder().decode(
            SyncPushRequest.self, from: try #require(server.pushBodies.last))
        #expect(sent.changes.map(\.entity) == [.transaction, .account])
        #expect(sent.changes.map(\.op) == [.upsert, .delete])
        #expect(server.row(entity: "account", id: accountID)?.deleted == true)
        #expect(server.row(entity: "transaction", id: txID)?.deleted == false)
        #expect(serverField(
            server, entity: "transaction", id: txID, field: "accountID") == nil)
    }

    @Test func deletingParentAndChildOrdersDeletes() async throws {
        let server = FakeSyncServer()
        let device = try makeDevice(server: server)
        let (accountID, txID, _) = try seedLedger(in: device.context)
        _ = try await device.engine.syncOnce()

        // Delete both — the child delete travels first or the parent's
        // would violate the server's FK check.
        device.context.delete(try transaction(device.context, id: txID))
        device.context.delete(try account(device.context, id: accountID))
        try device.context.save()
        let report = try await device.engine.syncOnce()
        #expect(report.pushedDeletes == 2)

        let sent = try JSONDecoder().decode(
            SyncPushRequest.self, from: try #require(server.pushBodies.last))
        #expect(sent.changes.map(\.entity) == [.transaction, .account])
        #expect(sent.changes.map(\.op) == [.delete, .delete])
        #expect(server.row(entity: "transaction", id: txID)?.deleted == true)
        #expect(server.row(entity: "account", id: accountID)?.deleted == true)

        // Next pull returns our own tombstones as no-ops.
        let second = try await device.engine.syncOnce()
        #expect(second.pulled == 2)
        #expect(second.deletedLocally == 0)
        #expect(second.conflictsKeptLocal == 0)
    }

    // MARK: - Change hook

    @Test func localStoreChangeHookFiresOnPulledWrites() async throws {
        final class Counter: @unchecked Sendable {
            private var count = 0
            private let lock = NSLock()
            func bump() {
                lock.lock()
                count += 1
                lock.unlock()
            }
            var value: Int {
                lock.lock()
                defer { lock.unlock() }
                return count
            }
        }
        let server = FakeSyncServer()
        let a = try makeDevice(server: server)
        _ = try seedLedger(in: a.context)
        _ = try await a.engine.syncOnce()

        let b = try makeDevice(server: server)
        let counter = Counter()
        await b.engine.addLocalStoreChangeHook { counter.bump() }
        _ = try await b.engine.syncOnce()
        #expect(counter.value > 0)
    }

    // MARK: - Scan modes (quick/full)

    /// The first cycle of every engine is FULL; once markers persist the
    /// routine cycle is QUICK and only re-hashes what `updatedAt` flags.
    @Test func quickScanPicksUpEditedNewAndDeletedTransactions() async throws {
        let server = FakeSyncServer()
        let device = try makeDevice(server: server)
        let (_, txID, _) = try seedLedger(in: device.context)
        // Age the seeded row so it always sits outside the safety
        // margin — only the rows under test should ever be hashed.
        try transaction(device.context, id: txID).updatedAt =
            Date(timeIntervalSince1970: 1_700_000_000)
        try device.context.save()

        let first = try await device.engine.syncOnce()
        #expect(first.scanMode == .full)
        #expect(first.pushedUpserts == 3)
        // Cycle 2 absorbs the own-write echoes and moves the cursor.
        _ = try await device.engine.syncOnce()

        // A row pushed then deleted before its echo returns — its shadow
        // entry must make the QUICK id-set diff push the tombstone.
        let doomed = LedgerTransaction(kind: .expense, amount: 1, note: "x")
        device.context.insert(doomed)
        try device.context.save()
        let insertCycle = try await device.engine.syncOnce()
        #expect(insertCycle.scanMode == .quick)
        #expect(insertCycle.hashedTransactions == 1)
        #expect(insertCycle.pushedUpserts == 1)

        // Now a stamped edit, a brand-new row and the delete — one cycle.
        let edited = try transaction(device.context, id: txID)
        edited.note = "đã sửa"
        edited.updatedAt = .now
        let fresh = LedgerTransaction(kind: .income, amount: 99_000, note: "mới")
        device.context.insert(fresh)
        device.context.delete(doomed)
        try device.context.save()

        let report = try await device.engine.syncOnce()
        #expect(report.scanMode == .quick)
        // The pulled echo of the doomed upsert meets a local delete —
        // local wins and the tombstone pushes back out.
        #expect(report.pulled == 1)
        #expect(report.conflictsKeptLocal == 1)
        // Only the stamped row + the never-shadowed insert were hashed.
        #expect(report.hashedTransactions == 2)
        #expect(report.pushedUpserts == 2)
        #expect(report.pushedDeletes == 1)
        #expect(serverField(
            server, entity: "transaction", id: txID, field: "note")
            == .string("đã sửa"))
        #expect(server.row(entity: "transaction", id: fresh.id)?.deleted == false)
        #expect(server.row(entity: "transaction", id: doomed.id)?.deleted == true)
    }

    @Test func quickScanWithNoChangesHashesNoTransactions() async throws {
        let server = FakeSyncServer()
        let device = try makeDevice(server: server)
        let (_, txID, _) = try seedLedger(in: device.context)
        // Age the stamp so it sits outside the safety margin — QUICK
        // must then skip the row without hashing it.
        try transaction(device.context, id: txID).updatedAt =
            Date(timeIntervalSince1970: 1_700_000_000)
        try device.context.save()

        _ = try await device.engine.syncOnce()   // FULL — pushes the aged stamp
        let report = try await device.engine.syncOnce()
        #expect(report.scanMode == .quick)
        #expect(report.hashedTransactions == 0)
        #expect(report.pushedUpserts == 0)
        #expect(report.pushedDeletes == 0)
    }

    /// An edit that does NOT move `updatedAt` is invisible to QUICK —
    /// the documented trade-off — but the FULL backstop must catch it.
    @Test func fullScanCatchesEditThatDidNotBumpUpdatedAt() async throws {
        let server = FakeSyncServer()
        let device = try makeDevice(server: server)
        let (_, txID, _) = try seedLedger(in: device.context)
        _ = try await device.engine.syncOnce()
        _ = try await device.engine.syncOnce()

        // Stealth edit: new content, artificially old stamp.
        let tx = try transaction(device.context, id: txID)
        tx.note = "lén lút"
        tx.updatedAt = Date(timeIntervalSince1970: 1_700_000_000)
        try device.context.save()

        let quick = try await device.engine.syncOnce()
        #expect(quick.scanMode == .quick)
        #expect(quick.hashedTransactions == 0)
        #expect(quick.pushedUpserts == 0)
        #expect(serverField(
            server, entity: "transaction", id: txID, field: "note")
            == .string("cà phê"))

        let full = try await device.engine.syncOnce(fullScan: true)
        #expect(full.scanMode == .full)
        #expect(full.hashedTransactions == 1)
        #expect(full.pushedUpserts == 1)
        #expect(serverField(
            server, entity: "transaction", id: txID, field: "note")
            == .string("lén lút"))
    }

    /// A persisted `lastFullScanAt` older than the 6-hour interval makes
    /// the next routine cycle FULL again.
    @Test func staleLastFullScanForcesFullScan() async throws {
        let server = FakeSyncServer()
        let device = try makeDevice(server: server)
        _ = try seedLedger(in: device.context)
        _ = try await device.engine.syncOnce()
        let quick = try await device.engine.syncOnce()
        #expect(quick.scanMode == .quick)

        try await device.shadow.updateScanMarkers(
            lastScanStart: .now,
            lastFullScanAt: Date(timeIntervalSince1970: 1))
        let report = try await device.engine.syncOnce()
        #expect(report.scanMode == .full)
    }

    // MARK: - Perf smoke

    @Test func perfSmokeFiveThousandTransactionsPushAndPull() async throws {
        let server = FakeSyncServer()
        let a = try makeDevice(server: server)
        let account = Account(name: "Tiền mặt", kind: .cash)
        a.context.insert(account)
        for index in 0..<5_000 {
            let tx = LedgerTransaction(
                kind: .expense, amount: Int64(index + 1) * 1_000,
                note: "giao dịch \(index)")
            tx.account = account
            // Stamped long ago — the routine QUICK cycles below skip all
            // 5k without hashing, like a real store between syncs.
            tx.updatedAt = Date(timeIntervalSince1970: 1_700_000_000)
            a.context.insert(tx)
        }
        try a.context.save()

        var pushReport = FinanceSyncReport()
        let pushMs = await PerfClock.msAsync("sync5k.push") {
            pushReport = try await a.engine.syncOnce()
        }
        #expect(pushReport.scanMode == .full)
        #expect(pushReport.pushedUpserts == 5_001)

        let b = try makeDevice(server: server)
        var pullReport = FinanceSyncReport()
        let pullMs = await PerfClock.msAsync("sync5k.pull") {
            pullReport = try await b.engine.syncOnce()
        }
        #expect(pullReport.applied == 5_001)
        #expect(try await a.engine.localContentHashes()
                == b.engine.localContentHashes())
        // Generous bound: seconds, not minutes — a correctness gate, not
        // a benchmark. Debug-build SwiftData + contract JSON runs ~10x
        // slower than release; even so this must stay well under a
        // minute on a loaded machine (was ~77s before the hashing and
        // batched-fetch work landed).
        #expect(pushMs + pullMs < 60_000)

        // The steady-state numbers the task wants measured: a QUICK
        // cycle with nothing to do (absorbs the own-write echo first)
        // and a forced FULL re-hash.
        _ = try await a.engine.syncOnce()   // echo-absorb
        var quick = FinanceSyncReport()
        await PerfClock.msAsync("sync5k.quickNoChange") {
            quick = try await a.engine.syncOnce()
        }
        #expect(quick.scanMode == .quick)
        #expect(quick.hashedTransactions == 0)
        var full = FinanceSyncReport()
        await PerfClock.msAsync("sync5k.fullScan") {
            full = try await a.engine.syncOnce(fullScan: true)
        }
        #expect(full.scanMode == .full)
        #expect(full.hashedTransactions == 5_000)
    }

    // MARK: - 30k benchmark (gated)

    /// The 30k-transaction sync benchmark — same opt-in mechanism as
    /// `PerformanceBenchmark` (`amfinance-perf-big` marker in the test
    /// host's tmp, see its doc comment). Reports `PERF | sync30k.*`
    /// lines for: the first FULL push, the own-write echo pull, a
    /// routine QUICK cycle with nothing to do (the number a once-a-
    /// minute sync must keep small), a forced FULL scan, and the pull
    /// side applying all 30k records on a second device.
    @Test(
        .enabled(
            if: PerformanceBenchmarkGate.isEnabled,
            "30k sync benchmark: marker file in the test host's tmp"))
    func benchmarkThirtyThousandTransactions() async throws {
        let server = FakeSyncServer()
        let a = try makeDevice(server: server)
        let account = Account(name: "Tiền mặt", kind: .cash)
        a.context.insert(account)
        for index in 0..<30_000 {
            let tx = LedgerTransaction(
                kind: .expense, amount: Int64(index + 1) * 1_000,
                note: "giao dịch \(index)")
            tx.account = account
            // Stamped long ago — after the first FULL scan every QUICK
            // cycle skips all 30k without hashing.
            tx.updatedAt = Date(timeIntervalSince1970: 1_700_000_000)
            a.context.insert(tx)
        }
        try a.context.save()

        await PerfClock.msAsync("sync30k.push") {
            let report = try await a.engine.syncOnce()
            #expect(report.scanMode == .full)
            #expect(report.hashedTransactions == 30_000)
            #expect(report.pushedUpserts == 30_001)
        }
        await PerfClock.msAsync("sync30k.pullEcho") {
            _ = try await a.engine.syncOnce()
        }
        var quick = FinanceSyncReport()
        await PerfClock.msAsync("sync30k.quickNoChange") {
            quick = try await a.engine.syncOnce()
        }
        #expect(quick.scanMode == .quick)
        #expect(quick.hashedTransactions == 0)
        #expect(quick.pushedUpserts == 0)

        var full = FinanceSyncReport()
        await PerfClock.msAsync("sync30k.fullScan") {
            full = try await a.engine.syncOnce(fullScan: true)
        }
        #expect(full.scanMode == .full)
        #expect(full.hashedTransactions == 30_000)

        let b = try makeDevice(server: server)
        await PerfClock.msAsync("sync30k.pullApply") {
            let report = try await b.engine.syncOnce()
            #expect(report.applied == 30_001)
        }
        #expect(try await a.engine.localContentHashes()
                == b.engine.localContentHashes())
    }
}
