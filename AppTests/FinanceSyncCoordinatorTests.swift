import FinanceCore
import Foundation
import SwiftData
import Testing
@testable import AMFinance

/// `FinanceSyncCoordinator` against the `FinanceSyncTestSupport` fake
/// server: the sync gating (disabled/signed out), single-flight, the
/// Vietnamese error mapping, pause/resume/disconnect, both first-sync
/// modes, the local-save debounce and the post-reset full scan.
/// Serialized like every suite that uses the shared URLProtocol stub.
@Suite(.serialized)
@MainActor
struct FinanceSyncCoordinatorTests {

    /// Rows `seedFullLedger` inserts across all nine entities.
    private static let seededRowCount = 22

    /// A token source that always fails — drives the mapped
    /// `.unauthorized` error path through the real API client.
    private struct DeniedTokenProvider: WalletLinkAccessTokenProviding {
        func accessToken() async throws -> String {
            throw WalletLinkError.notSignedIn
        }
        func forceRefreshedAccessToken() async throws -> String {
            throw WalletLinkError.notSignedIn
        }
    }

    private func makeCoordinator(
        server: FakeSyncServer,
        isSignedIn: @escaping @Sendable () async -> Bool = { true },
        api: FinanceSyncAPIClient? = nil,
        pullLimit: Int = 500
    ) throws -> (coordinator: FinanceSyncCoordinator, device: SyncTestDevice) {
        let device = try makeSyncDevice(
            api: api ?? syncTestClient(for: server), pullLimit: pullLimit)
        let coordinator = FinanceSyncCoordinator(
            engine: device.engine,
            bootstrap: device.bootstrap,
            shadow: device.shadow,
            isSignedIn: isSignedIn,
            serverDisplay: "test.local")
        return (coordinator, device)
    }

    // MARK: - Gating

    @Test func disabledSyncDoesNothing() async throws {
        let server = FakeSyncServer()
        let (coordinator, _) = try makeCoordinator(server: server)
        #expect(await coordinator.syncNow() == false)
        #expect(server.pullCount == 0)
        #expect(coordinator.enabled == false)
        #expect(coordinator.configured == false)
    }

    @Test func signedOutSyncIsSkipped() async throws {
        let server = FakeSyncServer()
        let (coordinator, device) = try makeCoordinator(
            server: server, isSignedIn: { false })
        // Reach the enabled state without the signed-in bootstrap.
        try await device.shadow.setEnabled(true)
        await coordinator.refreshState()
        #expect(coordinator.enabled)
        #expect(await coordinator.syncNow() == false)
        #expect(server.pullCount == 0)
        // A signed-out skip is not a failure — no error is shown.
        #expect(coordinator.lastError == nil)
    }

    @Test func enableRequiresSignIn() async throws {
        let server = FakeSyncServer()
        let (coordinator, _) = try makeCoordinator(
            server: server, isSignedIn: { false })
        #expect(await coordinator.enable(mode: .upload) == false)
        #expect(coordinator.enabled == false)
        #expect(coordinator.lastError?.contains("đăng nhập") == true)
        #expect(server.importBodies.isEmpty)
    }

    // MARK: - First sync modes

    @Test func enableUploadThenSyncPushesLocalChanges() async throws {
        let server = FakeSyncServer()
        let (coordinator, device) = try makeCoordinator(server: server)
        let ids = try seedFullLedger(in: device.context)
        #expect(await coordinator.enable(mode: .upload))
        #expect(coordinator.enabled)
        #expect(coordinator.configured)
        #expect(coordinator.lastBootstrapReport != nil)
        #expect(coordinator.lastError == nil)
        #expect(server.liveRowCount == Self.seededRowCount)

        // A local write after enable surfaces on the next sync. (Hoist
        // the ids — #Predicate cannot key-path into a captured struct.)
        let cashID = ids.cashAccount
        let foodID = ids.expenseCategory
        let cash = try #require(try device.context.fetch(
            FetchDescriptor<Account>(
                predicate: #Predicate { $0.id == cashID })).first)
        let food = try #require(try device.context.fetch(
            FetchDescriptor<LedgerCategory>(
                predicate: #Predicate { $0.id == foodID })).first)
        device.context.insert(LedgerTransaction(
            kind: .expense, amount: 45_000, date: .now,
            note: "auto-synced", account: cash, category: food))
        try device.context.save()

        #expect(await coordinator.syncNow(fullScan: true))
        #expect(coordinator.lastReport?.pushedUpserts == 1)
        #expect(server.row(
            entity: "transaction", id: ids.expenseTx)?.deleted == false)
    }

    @Test func enableDownloadRestoresServerData() async throws {
        let server = FakeSyncServer()
        // Another device seeds the server first.
        let (uploader, uploadDevice) = try makeCoordinator(server: server)
        _ = try seedFullLedger(in: uploadDevice.context)
        #expect(await uploader.enable(mode: .upload))

        // A fresh device downloads instead.
        let (coordinator, _) = try makeCoordinator(server: server)
        #expect(await coordinator.enable(mode: .download))
        #expect(coordinator.enabled)
        #expect(coordinator.configured)
        let probe = try await coordinator.probe()
        #expect(probe.localTotal == Self.seededRowCount)
    }

    // MARK: - Single-flight

    @Test func concurrentSyncsRunOnce() async throws {
        let server = FakeSyncServer()
        let (coordinator, device) = try makeCoordinator(server: server)
        _ = try seedFullLedger(in: device.context)
        #expect(await coordinator.enable(mode: .upload))
        let baseline = server.pullCount

        server.holdPulls = true
        async let first = coordinator.syncNow()
        // The second caller must piggyback on the in-flight run, not
        // start its own cycle.
        let second = Task { await coordinator.syncNow() }
        #expect(await waitForTrue { server.heldPullCount >= 1 })
        server.releaseHeldPulls()
        #expect(await first)
        #expect(await second.value)
        // One cycle = one pull page for this seed size — a second
        // engine run would have pulled again.
        #expect(server.pullCount == baseline + 1)
    }

    // MARK: - Pause / resume / disconnect

    @Test func pauseResumeDisconnect() async throws {
        let server = FakeSyncServer()
        let (coordinator, device) = try makeCoordinator(server: server)
        _ = try seedFullLedger(in: device.context)
        #expect(await coordinator.enable(mode: .upload))

        // Pause: sync off, shadow kept — nothing reaches the server.
        await coordinator.pause()
        #expect(coordinator.enabled == false)
        #expect(coordinator.configured)
        #expect(await coordinator.syncNow() == false)

        // Resume: incremental — the old cursor and hashes still apply;
        // the resumed cycle reaches the server on its own.
        let pullBaseline = server.pullCount
        await coordinator.resume()
        #expect(coordinator.enabled)
        #expect(await waitForTrue { server.pullCount > pullBaseline })

        // Disconnect: shadow + quarantine wiped — back to the
        // first-sync choice; the server keeps its copy.
        await coordinator.disconnect()
        #expect(coordinator.enabled == false)
        #expect(coordinator.configured == false)
        #expect((try? await device.shadow.entryCount()) == 0)
        #expect(server.liveRowCount == Self.seededRowCount)

        // Re-enabling needs the bootstrap again — and works.
        #expect(await coordinator.enable(mode: .upload))
        #expect(coordinator.enabled)
    }

    // MARK: - Errors

    @Test func syncFailureSurfacesMappedError() async throws {
        let server = FakeSyncServer()
        let api = FinanceSyncAPIClient(
            baseURL: server.baseURL,
            tokenProvider: DeniedTokenProvider(),
            urlSession: server.session)
        // Signed-in per the probe, but every request dies at the token
        // step — the unauthorized mapping must surface.
        let (coordinator, device) = try makeCoordinator(
            server: server, isSignedIn: { true }, api: api)
        try await device.shadow.setEnabled(true)
        await coordinator.refreshState()
        #expect(await coordinator.syncNow() == false)
        #expect(coordinator.lastError?.contains("đăng nhập") == true)
    }

    @Test func enableFailureLeavesSyncOff() async throws {
        let server = FakeSyncServer()
        server.failNextImport = URLError(.networkConnectionLost)
        let (coordinator, device) = try makeCoordinator(server: server)
        _ = try seedFullLedger(in: device.context)
        #expect(await coordinator.enable(mode: .upload) == false)
        #expect(coordinator.enabled == false)
        #expect(coordinator.lastError != nil)
        // The failure is resumable — retrying succeeds.
        #expect(await coordinator.enable(mode: .upload))
        #expect(coordinator.enabled)
    }

    @Test func errorTextMapping() {
        #expect(FinanceSyncCoordinator.errorText(FinanceSyncError.unauthorized)
            .contains("đăng nhập"))
        #expect(FinanceSyncCoordinator.errorText(
            FinanceSyncError.transport("offline")).contains("mạng"))
        #expect(FinanceSyncCoordinator.errorText(FinanceSyncError.validation(
            SyncValidationDetail(
                index: 0, field: "accountID",
                constraint: "foreign_key", message: "missing")))
            .contains("từ chối"))
        #expect(FinanceSyncCoordinator.errorText(
            FinanceSyncError.http(status: 500, body: "boom")).contains("500"))
    }

    // MARK: - Triggers

    @Test func noteLocalSaveTriggersDebouncedSync() async throws {
        let server = FakeSyncServer()
        let (coordinator, device) = try makeCoordinator(server: server)
        _ = try seedFullLedger(in: device.context)
        #expect(await coordinator.enable(mode: .upload))
        coordinator.localSaveDebounce = .milliseconds(30)

        let baseline = server.pullCount
        coordinator.noteLocalSave()
        #expect(await waitForTrue { server.pullCount > baseline })
    }

    @Test func noteLocalSaveIsInertWhenDisabled() async throws {
        let server = FakeSyncServer()
        let (coordinator, _) = try makeCoordinator(server: server)
        coordinator.localSaveDebounce = .milliseconds(30)
        coordinator.noteLocalSave()
        try await Task.sleep(for: .milliseconds(120))
        #expect(server.pullCount == 0)
    }

    @Test func syncIfStaleSkipsWithinWindow() async throws {
        let server = FakeSyncServer()
        let (coordinator, device) = try makeCoordinator(server: server)
        _ = try seedFullLedger(in: device.context)
        #expect(await coordinator.enable(mode: .upload))

        let baseline = server.pullCount
        #expect(await coordinator.syncIfStale() == false)
        #expect(server.pullCount == baseline)
        // A zero window always runs.
        #expect(await coordinator.syncIfStale(maxAge: 0))
        #expect(server.pullCount > baseline)
    }

    @Test func dataResetForcesFullScan() async throws {
        let server = FakeSyncServer()
        let center = NotificationCenter()
        let device = try makeSyncDevice(api: syncTestClient(for: server))
        let coordinator = FinanceSyncCoordinator(
            engine: device.engine, bootstrap: device.bootstrap,
            shadow: device.shadow,
            isSignedIn: { true }, serverDisplay: "test.local",
            notificationCenter: center)
        _ = try seedFullLedger(in: device.context)
        #expect(await coordinator.enable(mode: .upload))

        // After the bootstrap's full reconcile the routine cycle is
        // QUICK; a data reset must flip the next one back to FULL.
        #expect(await coordinator.syncNow())
        #expect(coordinator.lastReport?.scanMode == .quick)
        center.post(name: .dataResetCompleted, object: nil)
        // The observer hops onto the main actor before the flag is set.
        try await Task.sleep(for: .milliseconds(50))
        #expect(await coordinator.syncNow())
        #expect(coordinator.lastReport?.scanMode == .full)
    }

    // MARK: - Probe recommendations

    @Test func probeRecommendation() async throws {
        // A probe shaped like a seed-only phone talking to a holding
        // server recommends the download; an empty server flips it.
        var probe = FinanceSyncProbe(
            serverEmpty: true,
            localCounts: [.account: 1, .category: 21, .business: 3],
            localTotal: 25,
            shadowEmpty: true, isEnabled: false, pullCursor: 0)
        #expect(probe.seedOnly)
        #expect(probe.recommendedMode == .upload)

        probe = FinanceSyncProbe(
            serverEmpty: false,
            localCounts: [.account: 1, .category: 21, .business: 3],
            localTotal: 25,
            shadowEmpty: true, isEnabled: false, pullCursor: 0)
        #expect(probe.seedOnly)
        #expect(probe.recommendedMode == .download)

        probe = FinanceSyncProbe(
            serverEmpty: false,
            localCounts: [.account: 1, .transaction: 5],
            localTotal: 6,
            shadowEmpty: true, isEnabled: false, pullCursor: 0)
        #expect(!probe.seedOnly)
        #expect(probe.recommendedMode == nil)
    }
}
