import CoreData
import FinanceCore
import Foundation
import SwiftData
import Testing
@testable import AMFinance

/// Server-authoritative pull-apply: a pulled upsert must overwrite the
/// local row whenever the row has no unpushed local change — regardless of
/// `updatedAt` or any merge-restore rule — for every entity, relationship
/// fields included; the shadow must end at the applied hash; the main
/// context must see the change right after the cycle; and the engine's own
/// saves must never schedule another sync cycle.
///
/// Evidence behind it (production, owner's phone): after an upload-replace
/// the web edited one expense (seq 198/199, amount changed, `updatedAt`
/// not stamped). The phone pulled both records (HTTP 200) and never
/// pushed, yet kept the old amount — `BackupRestorer.upsertRow` for
/// transactions skips a copy whose `updatedAt` is not strictly newer —
/// and then pulled `cursor=198` every ~3 s: the engine's own saves (app
/// store + `FinanceSync.store` shadow) fired the global save
/// notifications the debounced local-save trigger listened to.
@Suite(.serialized)
@MainActor
struct FinanceSyncPullApplyTests {

    // MARK: - Fixtures

    private struct Pair {
        let server: FakeSyncServer
        let a: SyncTestDevice
        let b: SyncTestDevice
        let ids: FullLedgerIDs
    }

    /// Device A uploads a full ledger through the real push path, device
    /// B pulls it — both converged, nothing pending anywhere.
    private func makePair() async throws -> Pair {
        let server = FakeSyncServer()
        let a = try makeSyncDevice(server: server)
        let ids = try seedFullLedger(in: a.context)
        _ = try await a.engine.syncOnce()
        let b = try makeSyncDevice(server: server)
        let initial = try await b.engine.syncOnce()
        #expect(initial.pushedUpserts == 0)
        return Pair(server: server, a: a, b: b, ids: ids)
    }

    /// Rewrites one server record in place (a "web edit") with a fresh
    /// seq — fields in `set` replaced, keys in `remove` dropped.
    @discardableResult
    private func editOnServer(
        _ server: FakeSyncServer, entity: SyncEntity, id: UUID,
        set: [String: SyncJSONValue] = [:], remove: [String] = []
    ) throws -> (seq: Int64, dto: SyncBackupDTO) {
        guard case .object(var fields)? = server.row(
            entity: entity.rawValue, id: id)?.data
        else { throw EditError.missingRow }
        for (key, value) in set { fields[key] = value }
        for key in remove { fields.removeValue(forKey: key) }
        let data = SyncJSONValue.object(fields)
        let seq = server.putRecord(
            entity: entity.rawValue, id: id, data: data)
        return (seq, try SyncRecordMapper.decode(entity: entity, from: data))
    }

    private enum EditError: Error { case missingRow }

    private final class ObservationFlag: @unchecked Sendable {
        private let lock = NSLock()
        private var flag = false
        func set() { lock.lock(); flag = true; lock.unlock() }
        var value: Bool { lock.lock(); defer { lock.unlock() }; return flag }
    }

    private func tx(_ context: ModelContext, _ id: UUID) throws -> LedgerTransaction {
        try #require(try context.fetch(FetchDescriptor<LedgerTransaction>(
            predicate: #Predicate { $0.id == id })).first)
    }

    private func uuid(_ id: UUID) -> SyncJSONValue { .string(id.uuidString) }

    /// The shared contract after a server-side upsert: applied, nothing
    /// pushed, local hash == shadow hash == the pulled DTO's hash, the
    /// shadow carries the new seq, and a second cycle is a clean no-op.
    private func expectApplied(
        _ pair: Pair, entity: SyncEntity, id: UUID,
        edit: (seq: Int64, dto: SyncBackupDTO)
    ) async throws {
        let before = pair.server.committedPushCount
        let report = try await pair.b.engine.syncOnce()
        #expect(report.applied == 1)
        #expect(report.conflictsKeptLocal == 0)
        #expect(report.pushedUpserts == 0)
        #expect(report.pushedDeletes == 0)
        #expect(pair.server.committedPushCount == before)

        let key = SyncRecordKey(entity: entity, id: id)
        let expectedHash = SyncRecordMapper.contentHash(of: edit.dto)
        let local = try await pair.b.engine.localContentHashes()
        #expect(local[key] == expectedHash)
        let shadow = try await pair.b.shadow.allEntries()
            .first { $0.recordKey == key }
        #expect(shadow?.contentHash == expectedHash)
        #expect(shadow?.serverSeq == edit.seq)

        let again = try await pair.b.engine.syncOnce()
        #expect(again.applied == 0)
        #expect(again.pushedUpserts == 0)
        #expect(again.pushedDeletes == 0)
        #expect(pair.server.committedPushCount == before)
        #expect(pair.server.row(
            entity: entity.rawValue, id: id)?.seq == edit.seq)
    }

    // MARK: - Transactions: updatedAt must not gate the apply

    @Test func webEditWithSameUpdatedAtIsApplied() async throws {
        let pair = try await makePair()
        // Same `updatedAt` as the local row: the web did not stamp it.
        let edit = try editOnServer(
            pair.server, entity: .transaction, id: pair.ids.expenseTx,
            set: ["amount": .int(77_000)])
        try await expectApplied(
            pair, entity: .transaction, id: pair.ids.expenseTx, edit: edit)
        #expect(try tx(pair.b.context, pair.ids.expenseTx).amount == 77_000)
    }

    @Test func webEditWithOlderUpdatedAtIsApplied() async throws {
        let pair = try await makePair()
        let older = BackupDateCodec.string(
            from: Date(timeIntervalSince1970: 1_000_000))
        let edit = try editOnServer(
            pair.server, entity: .transaction, id: pair.ids.expenseTx,
            set: ["amount": .int(91_000), "updatedAt": .string(older)])
        try await expectApplied(
            pair, entity: .transaction, id: pair.ids.expenseTx, edit: edit)
        let row = try tx(pair.b.context, pair.ids.expenseTx)
        #expect(row.amount == 91_000)
        #expect(row.updatedAt == Date(timeIntervalSince1970: 1_000_000))
    }

    @Test func webEditOfNoteCategoryAccountAndDateIsApplied() async throws {
        let pair = try await makePair()
        let newDate = Date(timeIntervalSince1970: 1_764_500_000.25)
        let edit = try editOnServer(
            pair.server, entity: .transaction, id: pair.ids.expenseTx,
            set: [
                "note": .string("đã sửa trên web ✏️"),
                "categoryID": uuid(pair.ids.archivedCategory),
                "accountID": uuid(pair.ids.bankAccount),
                "date": .string(BackupDateCodec.string(from: newDate)),
                "needsReview": .bool(false),
            ])
        try await expectApplied(
            pair, entity: .transaction, id: pair.ids.expenseTx, edit: edit)
        let row = try tx(pair.b.context, pair.ids.expenseTx)
        #expect(row.note == "đã sửa trên web ✏️")
        #expect(row.category?.id == pair.ids.archivedCategory)
        #expect(row.account?.id == pair.ids.bankAccount)
        #expect(row.date == newDate)
        #expect(row.needsReview == false)
    }

    @Test func webEditClearingRelationshipsIsApplied() async throws {
        let pair = try await makePair()
        let edit = try editOnServer(
            pair.server, entity: .transaction, id: pair.ids.expenseTx,
            remove: ["categoryID", "businessID"])
        try await expectApplied(
            pair, entity: .transaction, id: pair.ids.expenseTx, edit: edit)
        let row = try tx(pair.b.context, pair.ids.expenseTx)
        #expect(row.category == nil)
        #expect(row.business == nil)
    }

    @Test func webTombstoneIsApplied() async throws {
        let pair = try await makePair()
        let id = pair.ids.expenseTx
        let seq = pair.server.putRecord(
            entity: "transaction", id: id, deleted: true, data: nil)
        let report = try await pair.b.engine.syncOnce()
        #expect(report.deletedLocally == 1)
        #expect(report.pushedDeletes == 0)
        #expect(report.pushedUpserts == 0)
        let remaining = try pair.b.context.fetch(
            FetchDescriptor<LedgerTransaction>(
                predicate: #Predicate { $0.id == id }))
        #expect(remaining.isEmpty)
        let key = SyncRecordKey(entity: .transaction, id: id)
        #expect(try await pair.b.shadow.allEntries()
            .contains { $0.recordKey == key } == false)
        #expect(pair.server.row(entity: "transaction", id: id)?.seq == seq)
        let again = try await pair.b.engine.syncOnce()
        #expect(again.pushedDeletes == 0 && again.deletedLocally == 0)
    }

    // MARK: - All nine entities

    struct EntityCase: Sendable, CustomTestStringConvertible {
        var entity: SyncEntity
        var id: @Sendable (FullLedgerIDs) -> UUID
        var set: @Sendable (FullLedgerIDs) -> [String: SyncJSONValue]
        var remove: [String] = []
        var testDescription: String { entity.rawValue }
    }

    nonisolated static let entityCases: [EntityCase] = [
        EntityCase(
            entity: .account, id: { $0.cashAccount },
            set: { ids in [
                "name": .string("Ví đổi tên"),
                "openingBalance": .int(5_000_000),
                "businessID": .string(ids.business.uuidString),
            ] }),
        EntityCase(
            entity: .category, id: { $0.expenseCategory },
            set: { _ in ["name": .string("Ăn ngoài"), "colorHex": .string("123456")] }),
        EntityCase(
            entity: .business, id: { $0.business },
            set: { _ in ["note": .string("ghi chú mới"), "sortOrder": .int(9)] }),
        EntityCase(
            entity: .transaction, id: { $0.transferTx },
            set: { ids in [
                "amount": .int(3_000_000),
                "toAccountID": .string(ids.bankAccount.uuidString),
            ] }),
        EntityCase(
            entity: .loanRateChange, id: { $0.rateChange },
            set: { _ in ["annualRatePercent": .double(11.25), "fromInstallment": .int(20)] }),
        EntityCase(
            entity: .budget, id: { $0.categoryBudget },
            set: { ids in [
                "monthlyLimit": .int(4_500_000),
                "categoryID": .string(ids.incomeCategory.uuidString),
            ] }),
        EntityCase(
            entity: .recurringRule, id: { $0.monthlyRule },
            set: { ids in [
                "amount": .int(8_500_000),
                "categoryID": .string(ids.archivedCategory.uuidString),
                "accountID": .string(ids.bankAccount.uuidString),
            ] }),
        EntityCase(
            entity: .rentalUnit, id: { $0.rentalUnit },
            set: { _ in ["listPrice": .int(4_000_000), "name": .string("Phòng 101A")] },
            remove: ["businessID"]),
        EntityCase(
            entity: .rentalLease, id: { $0.rentalLease },
            set: { _ in ["monthlyRent": .int(3_900_000), "tenantName": .string("Trần B")] },
            remove: ["unitID"]),
    ]

    @Test(arguments: entityCases)
    func serverEditIsAppliedForEveryEntity(_ entityCase: EntityCase) async throws {
        let pair = try await makePair()
        let id = entityCase.id(pair.ids)
        let edit = try editOnServer(
            pair.server, entity: entityCase.entity, id: id,
            set: entityCase.set(pair.ids), remove: entityCase.remove)
        try await expectApplied(
            pair, entity: entityCase.entity, id: id, edit: edit)
    }

    // MARK: - Conflict policy untouched

    @Test func unpushedLocalEditStillWinsOverServerEdit() async throws {
        let pair = try await makePair()
        let local = try tx(pair.b.context, pair.ids.expenseTx)
        local.amount = 11_111
        local.updatedAt = .now
        try pair.b.context.save()
        try editOnServer(
            pair.server, entity: .transaction, id: pair.ids.expenseTx,
            set: ["amount": .int(22_222)])
        let report = try await pair.b.engine.syncOnce()
        #expect(report.conflictsKeptLocal == 1)
        #expect(report.pushedUpserts == 1)
        #expect(try tx(pair.b.context, pair.ids.expenseTx).amount == 11_111)
    }

    // MARK: - Main-context visibility

    /// Measured: SwiftData does not push a background save's property
    /// updates into instances the main context already holds (only a later
    /// main-context fetch does). The coordinator wires
    /// `FinanceSyncMainContextRefresher` onto the engine; it runs before
    /// `syncOnce` returns, so the screen is current right after the cycle.
    @Test func mainContextSeesAppliedEditRightAfterTheCycle() async throws {
        let pair = try await makePair()
        await FinanceSyncMainContextRefresher.install(
            on: pair.b.engine, container: pair.b.container)
        let mainContext = pair.b.container.mainContext
        let id = pair.ids.expenseTx

        // A screen is already showing the row (loaded, observed).
        let shown = try #require(try mainContext.fetch(
            FetchDescriptor<LedgerTransaction>(
                predicate: #Predicate { $0.id == id })).first)
        #expect(shown.amount == 45_000)
        let observed = ObservationFlag()
        withObservationTracking {
            _ = shown.amount
        } onChange: {
            observed.set()
        }

        try editOnServer(
            pair.server, entity: .transaction, id: id,
            set: ["amount": .int(77_000), "note": .string("sửa trên web")])
        let report = try await pair.b.engine.syncOnce()
        #expect(report.applied == 1)

        // No fetch in between: the already-displayed object itself is
        // current, and its observers were told.
        #expect(shown.amount == 77_000)
        #expect(shown.note == "sửa trên web")
        #expect(observed.value)
        let fetched = try #require(try mainContext.fetch(
            FetchDescriptor<LedgerTransaction>(
                predicate: #Predicate { $0.id == id })).first)
        #expect(fetched.amount == 77_000)
    }

    @Test func mainContextRefreshCoversEveryRegisteredEntity() async throws {
        let pair = try await makePair()
        await FinanceSyncMainContextRefresher.install(
            on: pair.b.engine, container: pair.b.container)
        let mainContext = pair.b.container.mainContext
        let ids = pair.ids
        let account = try #require(try mainContext.fetch(
            FetchDescriptor<Account>(
                predicate: #Predicate { $0.id == ids.cashAccount })).first)
        let budget = try #require(try mainContext.fetch(
            FetchDescriptor<Budget>(
                predicate: #Predicate { $0.id == ids.categoryBudget })).first)
        let lease = try #require(try mainContext.fetch(
            FetchDescriptor<RentalLease>(
                predicate: #Predicate { $0.id == ids.rentalLease })).first)
        try editOnServer(
            pair.server, entity: .account, id: ids.cashAccount,
            set: ["name": .string("Ví web")])
        try editOnServer(
            pair.server, entity: .budget, id: ids.categoryBudget,
            set: ["monthlyLimit": .int(1_234_000)])
        try editOnServer(
            pair.server, entity: .rentalLease, id: ids.rentalLease,
            set: ["monthlyRent": .int(4_200_000)])
        _ = try await pair.b.engine.syncOnce()
        #expect(account.name == "Ví web")
        #expect(budget.monthlyLimit == 1_234_000)
        #expect(lease.monthlyRent == 4_200_000)
    }

    // MARK: - Self-triggered sync loop

    /// Re-posts real default-center save notifications onto a private
    /// center the coordinator listens to — scoped by `forward` so other
    /// suites' process-global saves can never leak into an assertion.
    private final class SaveForwarder: @unchecked Sendable {
        private let lock = NSLock()
        private var observers: [NSObjectProtocol] = []
        private(set) var engineForwarded = 0
        private(set) var shadowForwarded = 0
        private(set) var userForwarded = 0

        init(
            to center: NotificationCenter,
            forward: @escaping @Sendable (Notification) -> Bool
        ) {
            for name in [ModelContext.didSave,
                         Notification.Name.NSManagedObjectContextDidSave] {
                observers.append(NotificationCenter.default.addObserver(
                    forName: name, object: nil, queue: nil
                ) { [self] note in
                    guard forward(note) else { return }
                    let names = Self.entityNames(of: note)
                    lock.lock()
                    if FinanceSyncSaveFilter.isEngineSave {
                        engineForwarded += 1
                    } else if !names.isEmpty, names.allSatisfy(Self.isShadow) {
                        shadowForwarded += 1
                    } else {
                        userForwarded += 1
                    }
                    lock.unlock()
                    center.post(note)
                })
            }
        }

        deinit {
            for observer in observers {
                NotificationCenter.default.removeObserver(observer)
            }
        }

        static func isShadow(_ name: String) -> Bool {
            name.contains("SyncShadow") || name.contains("SyncQuarantine")
        }

        static func entityNames(of note: Notification) -> [String] {
            var names: [String] = []
            for key in [NSInsertedObjectsKey, NSUpdatedObjectsKey, NSDeletedObjectsKey] {
                let objects = note.userInfo?[key] as? Set<NSManagedObject> ?? []
                names += objects.compactMap(\.entity.name)
            }
            for key: ModelContext.NotificationKey in [
                .insertedIdentifiers, .updatedIdentifiers, .deletedIdentifiers,
            ] {
                let ids = note.userInfo?[key.rawValue] as? [PersistentIdentifier] ?? []
                names += ids.map(\.entityName)
            }
            return names
        }
    }

    private func makeWatchedCoordinator(
        server: FakeSyncServer, center: NotificationCenter
    ) async throws -> (FinanceSyncCoordinator, SyncTestDevice) {
        let device = try makeSyncDevice(server: server)
        let coordinator = FinanceSyncCoordinator(
            engine: device.engine, bootstrap: device.bootstrap,
            shadow: device.shadow, isSignedIn: { true },
            serverDisplay: "test.local", notificationCenter: center)
        try await device.shadow.setEnabled(true)
        await coordinator.refreshState()
        coordinator.localSaveDebounce = .milliseconds(40)
        coordinator.startObservingLocalSaves(center: center)
        return (coordinator, device)
    }

    @Test func syncCycleApplyingRecordsDoesNotScheduleAnotherCycle() async throws {
        let server = FakeSyncServer()
        let uploader = try makeSyncDevice(server: server)
        _ = try seedFullLedger(in: uploader.context)
        _ = try await uploader.engine.syncOnce()

        let center = NotificationCenter()
        let (coordinator, _) = try await makeWatchedCoordinator(
            server: server, center: center)
        // Everything the engine/shadow save (any thread) reaches the
        // coordinator exactly as in the app: engine-originated app-store
        // saves and shadow-store saves only — never a user save.
        let forwarder = SaveForwarder(to: center) { note in
            if FinanceSyncSaveFilter.isEngineSave { return true }
            let names = SaveForwarder.entityNames(of: note)
            return !names.isEmpty && names.allSatisfy(SaveForwarder.isShadow)
        }

        let baseline = server.pullCount
        #expect(await coordinator.syncNow())
        // The cycle pulled and APPLIED the whole ledger — plenty of
        // engine and shadow saves, all of which must stay silent.
        #expect(coordinator.lastReport?.applied == 22)
        #expect(forwarder.engineForwarded > 0)
        #expect(forwarder.shadowForwarded > 0)
        #expect(server.pullCount == baseline + 1)

        // The old loop re-pulled every debounce; give it room to show.
        try await Task.sleep(for: .milliseconds(400))
        #expect(server.pullCount == baseline + 1)
        withExtendedLifetime(forwarder) {}
    }

    @Test func userEditOnMainContextSchedulesDebouncedSync() async throws {
        let server = FakeSyncServer()
        let uploader = try makeSyncDevice(server: server)
        let ids = try seedFullLedger(in: uploader.context)
        _ = try await uploader.engine.syncOnce()

        let center = NotificationCenter()
        let (coordinator, device) = try await makeWatchedCoordinator(
            server: server, center: center)
        coordinator.localSaveDebounce = .milliseconds(250)
        #expect(await coordinator.syncNow())
        let forwarder = SaveForwarder(to: center) { _ in Thread.isMainThread }

        let baseline = server.pullCount
        let row = try tx(device.context, ids.expenseTx)
        row.amount = 12_345
        row.updatedAt = .now
        try device.context.save()
        #expect(forwarder.userForwarded > 0)
        // Debounced: nothing runs immediately…
        #expect(server.pullCount == baseline)
        // …then exactly the follow-up cycle pushes the edit.
        #expect(await waitForTrue { server.pullCount > baseline })
        #expect(await waitForTrue {
            server.committedPushCount >= 2
        })
        guard case .object(let fields)? = server.row(
            entity: "transaction", id: ids.expenseTx)?.data
        else { throw EditError.missingRow }
        #expect(fields["amount"] == SyncJSONValue.int(12_345))
        withExtendedLifetime(forwarder) {}
    }
}
