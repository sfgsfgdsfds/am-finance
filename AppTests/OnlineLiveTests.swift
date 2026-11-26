import Foundation
import SwiftData
import Testing
@testable import AMFinance

/// Online-only stage 2: a user save pushes immediately, saves during a
/// cycle collapse into one follow-up, the engine's own apply does not
/// schedule another cycle, and the long-poll brings a server write onto
/// the main context. A transport failure marks the session offline and
/// backs off; a `422` reloads the store from the export.
@Suite(.serialized)
@MainActor
struct OnlineLiveTests {

    private final class SaveForwarder: @unchecked Sendable {
        private var observers: [NSObjectProtocol] = []

        init(to center: NotificationCenter) {
            for name in [ModelContext.didSave,
                         Notification.Name.NSManagedObjectContextDidSave] {
                observers.append(NotificationCenter.default.addObserver(
                    forName: name, object: nil, queue: nil
                ) { note in
                    center.post(note)
                })
            }
        }

        deinit {
            for observer in observers {
                NotificationCenter.default.removeObserver(observer)
            }
        }
    }

    private func serverWithLedger() async throws -> (FakeSyncServer, FullLedgerIDs) {
        let server = FakeSyncServer()
        let other = try makeSyncDevice(server: server)
        let ids = try seedFullLedger(in: other.context)
        try await other.bootstrap.uploadReplace()
        return (server, ids)
    }

    private func makeStack(
        server: FakeSyncServer
    ) throws -> (SyncTestDevice, FinanceSyncCoordinator, OnlineStore) {
        let device = try makeSyncDevice(server: server)
        let coordinator = FinanceSyncCoordinator(
            engine: device.engine, bootstrap: device.bootstrap,
            shadow: device.shadow, isSignedIn: { true },
            serverDisplay: "test.local")
        let store = OnlineStore(
            container: device.container,
            api: syncTestClient(for: server),
            bootstrap: device.bootstrap,
            coordinator: coordinator,
            isSignedIn: { true },
            signIn: {},
            afterLoad: { await coordinator.refreshState() })
        coordinator.liveWaitTimeout = 0.05
        coordinator.liveBackoffInitial = .milliseconds(40)
        coordinator.liveBackoffMaximum = .milliseconds(120)
        coordinator.liveEmptyPullDelay = .milliseconds(80)
        return (device, coordinator, store)
    }

    /// Main-actor poll. `waitForTrue` is `@Sendable` and cannot read a
    /// model or an `@Observable` property.
    private func waitUntil(
        timeout: Duration = .seconds(3),
        _ condition: () -> Bool
    ) async -> Bool {
        let deadline = ContinuousClock.now + timeout
        while ContinuousClock.now < deadline {
            if condition() { return true }
            try? await Task.sleep(for: .milliseconds(5))
        }
        return condition()
    }

    private func tx(_ context: ModelContext, _ id: UUID) throws -> LedgerTransaction {
        try #require(try context.fetch(FetchDescriptor<LedgerTransaction>(
            predicate: #Predicate { $0.id == id })).first)
    }

    // MARK: - Immediate push

    @Test func userSavePushesWithoutWaitingForTheDebounce() async throws {
        let (server, ids) = try await serverWithLedger()
        let (device, coordinator, store) = try makeStack(server: server)
        // Long enough that a debounced trigger would still be waiting
        // when the assertion below gives up.
        coordinator.localSaveDebounce = .seconds(60)
        await store.start()
        #expect(store.phase == .ready)
        let center = NotificationCenter()
        let forwarder = SaveForwarder(to: center)
        coordinator.startObservingLocalSaves(center: center)

        let row = try tx(device.context, ids.expenseTx)
        row.amount = 12_345
        row.updatedAt = .now
        try device.context.save()

        // The pull count moves when the request starts, before the push
        // lands — wait until the server row itself shows the edit.
        // The debounce is 60s, so this only passes if the save skipped it.
        #expect(await waitUntil(timeout: .seconds(2)) {
            if case .object(let fields)? = server.row(
                entity: "transaction", id: ids.expenseTx)?.data {
                return fields["amount"] == .int(12_345)
            }
            return false
        })
        withExtendedLifetime(forwarder) {}
    }

    @Test func savesDuringACycleCoalesceIntoOneFollowUp() async throws {
        let (server, _) = try await serverWithLedger()
        let (_, coordinator, store) = try makeStack(server: server)
        await store.start()
        #expect(store.phase == .ready)
        let baseline = server.pullCount

        server.holdPulls = true
        async let done = coordinator.syncNow()
        #expect(await waitForTrue { server.heldPullCount >= 1 })
        coordinator.noteLocalSave()
        coordinator.noteLocalSave()
        server.releaseHeldPulls()
        #expect(await done)
        // The held cycle plus exactly one follow-up — not one per save.
        #expect(server.pullCount == baseline + 2)
        try await Task.sleep(for: .milliseconds(200))
        #expect(server.pullCount == baseline + 2)
    }

    @Test func engineApplyDoesNotScheduleAnotherCycle() async throws {
        let (server, ids) = try await serverWithLedger()
        let (device, coordinator, store) = try makeStack(server: server)
        coordinator.localSaveDebounce = .milliseconds(30)
        await store.start()
        coordinator.stopLiveUpdates()
        await FinanceSyncMainContextRefresher.install(
            on: device.engine, container: device.container)
        let center = NotificationCenter()
        let forwarder = SaveForwarder(to: center)
        coordinator.startObservingLocalSaves(center: center)

        guard case .object(var fields)? = server.row(
            entity: "transaction", id: ids.expenseTx)?.data
        else {
            Issue.record("row missing")
            return
        }
        fields["amount"] = .int(77_000)
        server.putRecord(
            entity: "transaction", id: ids.expenseTx, data: .object(fields))

        let baseline = server.pullCount
        #expect(await coordinator.syncNow())
        #expect(coordinator.lastReport?.applied == 1)
        #expect(coordinator.lastReport?.pushedUpserts == 0)
        try await Task.sleep(for: .milliseconds(250))
        #expect(server.pullCount == baseline + 1)
        withExtendedLifetime(forwarder) {}
    }

    // MARK: - Long-poll

    @Test func serverWriteIsPulledAndVisibleOnTheMainContext() async throws {
        let (server, ids) = try await serverWithLedger()
        let (device, coordinator, store) = try makeStack(server: server)
        await FinanceSyncMainContextRefresher.install(
            on: device.engine, container: device.container)
        await store.start()
        #expect(store.phase == .ready)
        coordinator.startLiveUpdates()

        let main = device.container.mainContext
        let id = ids.expenseTx
        let shown = try #require(try main.fetch(FetchDescriptor<LedgerTransaction>(
            predicate: #Predicate { $0.id == id })).first)
        #expect(shown.amount == 45_000)
        let observed = ObservationBox()
        withObservationTracking {
            _ = shown.amount
        } onChange: {
            observed.set()
        }

        guard case .object(var fields)? = server.row(
            entity: "transaction", id: id)?.data
        else {
            Issue.record("row missing")
            return
        }
        fields["amount"] = .int(77_000)
        fields["note"] = .string("sửa trên web")
        server.putRecord(entity: "transaction", id: id, data: .object(fields))

        #expect(await waitUntil {
            shown.amount == 77_000 && shown.note == "sửa trên web"
        })
        try await Task.sleep(for: .milliseconds(200))
        #expect(observed.value)
        coordinator.stopLiveUpdates()
    }

    @Test func quietWaitRetries() async throws {
        let server = FakeSyncServer()
        let (_, coordinator, store) = try makeStack(server: server)
        await store.start()
        coordinator.liveWaitTimeout = 0.05
        coordinator.startLiveUpdates()
        #expect(await waitForTrue(timeout: .seconds(3)) {
            server.waitCount >= 2
        })
        coordinator.stopLiveUpdates()
    }

    @Test func instantEmptyPullDoesNotSpin() async throws {
        let server = FakeSyncServer()
        let (_, coordinator, store) = try makeStack(server: server)
        await store.start()
        coordinator.stopLiveUpdates()
        // Catch the cursor up so the measured cycles pull nothing.
        #expect(await coordinator.syncNow())
        try await Task.sleep(for: .milliseconds(80))
        let baseline = server.waitCount
        coordinator.liveWaitTimeout = 0.01
        coordinator.liveEmptyPullDelay = .milliseconds(150)
        // 200 even though the cursor is already caught up.
        server.waitSeqOffset = 1
        let started = ContinuousClock.now
        coordinator.startLiveUpdates()
        #expect(await waitForTrue(timeout: .seconds(3)) {
            server.waitCount >= baseline + 3
        })
        let elapsed = ContinuousClock.now - started
        // Two empty-pull gaps at 150 ms. Three instant 200s without the
        // guard would finish in a few milliseconds.
        #expect(elapsed >= .milliseconds(280))
        coordinator.stopLiveUpdates()
    }

    @Test func networkErrorGoesOfflineThenRecovers() async throws {
        let (server, ids) = try await serverWithLedger()
        let (device, coordinator, store) = try makeStack(server: server)
        await store.start()
        #expect(store.isOnline)
        coordinator.liveBackoffInitial = .milliseconds(30)
        coordinator.liveBackoffMaximum = .milliseconds(80)
        server.setTransportFailure(pathSuffix: "/v1/sync/wait", enabled: true)
        coordinator.startLiveUpdates()
        #expect(await waitUntil { store.isOnline == false })
        #expect(coordinator.isOnline == false)

        // An edit made while offline stays local and pushes on recovery.
        let row = try tx(device.context, ids.expenseTx)
        row.amount = 54_321
        row.updatedAt = .now
        try device.context.save()
        coordinator.noteLocalSave()

        server.setTransportFailure(pathSuffix: "/v1/sync/wait", enabled: false)
        #expect(await waitUntil { store.isOnline })
        #expect(await waitUntil {
            if case .object(let fields)? = server.row(
                entity: "transaction", id: ids.expenseTx)?.data {
                return fields["amount"] == .int(54_321)
            }
            return false
        })
        coordinator.stopLiveUpdates()
    }

    @Test func pushTransportFailureMarksOffline() async throws {
        let (server, ids) = try await serverWithLedger()
        let (device, coordinator, store) = try makeStack(server: server)
        await store.start()
        server.setTransportFailure(pathSuffix: "/v1/sync/push", enabled: true)
        let row = try tx(device.context, ids.expenseTx)
        row.amount = 8_888
        row.updatedAt = .now
        try device.context.save()
        #expect(await coordinator.syncNow() == false)
        #expect(store.isOnline == false)
        #expect(coordinator.lastError?.contains("mạng") == true
            || coordinator.lastError?.contains("kết nối") == true)

        server.setTransportFailure(pathSuffix: "/v1/sync/push", enabled: false)
        #expect(await coordinator.syncNow())
        #expect(store.isOnline)
        guard case .object(let fields)? = server.row(
            entity: "transaction", id: ids.expenseTx)?.data
        else {
            Issue.record("row missing")
            return
        }
        #expect(fields["amount"] == .int(8_888))
    }

    // MARK: - Rejected push

    @Test func rejectedPushReloadsServerTruth() async throws {
        let (server, ids) = try await serverWithLedger()
        let (device, coordinator, store) = try makeStack(server: server)
        await store.start()
        #expect(store.phase == .ready)
        let expenseID = ids.expenseTx
        server.validator = { change in
            if change.op == .upsert && change.id == expenseID {
                return ("amount", "rejected", "số tiền không hợp lệ")
            }
            return nil
        }
        let row = try tx(device.context, expenseID)
        row.amount = 111
        row.updatedAt = .now
        try device.context.save()
        #expect(await coordinator.syncNow() == true)
        #expect(await waitUntil {
            store.rejectionMessage?.contains("Máy chủ từ chối thay đổi") == true
                && store.rejectionMessage?.contains("số tiền không hợp lệ") == true
                && store.phase == .ready
        })
        // A fresh context: the one that edited still holds the refused
        // object, and the reload inserted the server's row beside it.
        let restored = try tx(ModelContext(device.container), expenseID)
        #expect(restored.amount == 45_000)
        // The refused edit is not on the server either.
        guard case .object(let fields)? = server.row(
            entity: "transaction", id: expenseID)?.data
        else {
            Issue.record("row missing")
            return
        }
        #expect(fields["amount"] == .int(45_000))
    }

    // MARK: - wait() contract

    @Test func waitReturnsHighWaterWhenAhead() async throws {
        let server = FakeSyncServer()
        let api = syncTestClient(for: server)
        #expect(try await api.wait(cursor: 0, timeout: 1) == nil)
        server.putRecord(entity: "category", id: UUID(), deleted: true, data: nil)
        #expect(try await api.wait(cursor: 0, timeout: 1) == 1)
        #expect(try await api.head() == 1)
    }

    @Test func waitTimeoutIsNilAndClientTimeoutOutlastsTheHold() async throws {
        let server = FakeSyncServer()
        let api = syncTestClient(for: server)
        let started = ContinuousClock.now
        let seq = try await api.wait(cursor: 0, timeout: 0.05)
        #expect(seq == nil)
        #expect(ContinuousClock.now - started >= .milliseconds(40))
        #expect(ContinuousClock.now - started < .seconds(5))
    }

    @Test func waitMapsStatusErrors() async throws {
        let server = FakeSyncServer()
        let api = syncTestClient(for: server)
        server.setFailure(pathSuffix: "/v1/sync/wait", status: 400)
        do {
            _ = try await api.wait(cursor: 0, timeout: 1)
            Issue.record("expected 400")
        } catch let error as FinanceSyncError {
            guard case .http(let status, _) = error else {
                Issue.record("unexpected \(error)")
                return
            }
            #expect(status == 400)
        }
        server.setFailure(pathSuffix: "/v1/sync/wait", status: 401)
        do {
            _ = try await api.wait(cursor: 0, timeout: 1)
            Issue.record("expected 401")
        } catch let error as FinanceSyncError {
            guard case .unauthorized = error else {
                Issue.record("unexpected \(error)")
                return
            }
        }
    }
}

/// `withObservationTracking`'s callback can arrive off the main actor.
private final class ObservationBox: @unchecked Sendable {
    private let lock = NSLock()
    private var flag = false
    func set() { lock.lock(); flag = true; lock.unlock() }
    var value: Bool { lock.lock(); defer { lock.unlock() }; return flag }
}
