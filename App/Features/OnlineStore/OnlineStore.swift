import Foundation
import Observation
import SwiftData

/// The online-only launch pipeline. The web server is the app's backend:
/// the app container is an in-memory store filled from
/// `GET /v1/backup/export` at launch, and nothing is persisted locally.
///
/// Phases: `starting` (checking the session) → `signedOut` →
/// `migratingLegacy` (only when an on-disk legacy store exists) →
/// `loading` → `ready` | `failed(text)` ("Thử lại" re-runs the whole
/// pipeline; every step is re-runnable). The root tabs — and with them
/// the recurring/reminder/wallet-sync activation hooks — exist ONLY in
/// `ready`; `BackgroundRefreshRunner` consults `isReady` too, so a
/// background launch never touches the empty store.
@MainActor
@Observable
final class OnlineStore {
    enum Phase: Equatable {
        case starting
        case signedOut
        case migratingLegacy
        case loading
        case ready
        case failed(String)
    }

    private(set) var phase: Phase = .starting
    /// Vietnamese text of the last failed sign-in attempt.
    private(set) var signInError: String?
    /// One-time notice about the legacy migration, shown once ready.
    private(set) var legacyNotice: String?
    /// False while a wait/push/pull cannot reach the server. The gate
    /// draws a blocking overlay until a request succeeds again.
    private(set) var isOnline = true
    /// "Máy chủ từ chối thay đổi: …" after a rejected push, once the
    /// store has been reloaded to server truth. Nil when there is
    /// nothing to tell the user.
    private(set) var rejectionMessage: String?

    var isReady: Bool { phase == .ready }

    private let container: ModelContainer
    private let api: FinanceSyncAPIClient
    private let bootstrap: FinanceSyncBootstrap
    private let migrator: LegacyStoreMigrator?
    private let coordinator: FinanceSyncCoordinator?
    private let isSignedIn: @Sendable () async -> Bool
    private let performSignIn: @MainActor () async throws -> Void
    private let performSignOut: @MainActor () async -> Void
    private let afterLoad: @MainActor () async -> Void
    private var started = false
    private var running = false
    private var reloading = false
    /// The scene is in the foreground. Updated by the gate; assumed true
    /// until the first scene-phase callback so a launch starts the loop.
    private var foreground = true

    init(
        container: ModelContainer,
        api: FinanceSyncAPIClient,
        bootstrap: FinanceSyncBootstrap,
        migrator: LegacyStoreMigrator? = nil,
        coordinator: FinanceSyncCoordinator? = nil,
        isSignedIn: @escaping @Sendable () async -> Bool,
        signIn: @escaping @MainActor () async throws -> Void,
        signOut: @escaping @MainActor () async -> Void = {},
        afterLoad: @escaping @MainActor () async -> Void = {}
    ) {
        self.container = container
        self.api = api
        self.bootstrap = bootstrap
        self.migrator = migrator
        self.coordinator = coordinator
        self.isSignedIn = isSignedIn
        self.performSignIn = signIn
        self.performSignOut = signOut
        self.afterLoad = afterLoad
        if let coordinator {
            bind(coordinator)
        }
    }

    /// Entry point of the gate view — idempotent.
    func start() async {
        guard !started else { return }
        started = true
        await holdLoadingGateForUITest()
        await evaluate()
    }

    /// `-uiTestOnline` only. The in-app fake answers the export before
    /// XCUITest has attached, so the loading gate would already be gone
    /// when the test looks. Holding here — with the spinner suppressed,
    /// see `OnlineGateProgressView` — lets the app go idle while the
    /// gate is still up.
    private func holdLoadingGateForUITest() async {
        #if DEBUG
        guard FinanceSyncUITestSupport.onlineEnabled(
            arguments: ProcessInfo.processInfo.arguments) else { return }
        try? await Task.sleep(for: .seconds(8))
        #endif
    }

    /// "Đăng nhập" on the sign-in screen.
    func signIn() async {
        guard !running, phase == .signedOut else { return }
        signInError = nil
        do {
            try await performSignIn()
        } catch {
            signInError = Self.text(for: error)
            return
        }
        await run()
    }

    /// "Thử lại" on the failure screen.
    func retry() async {
        guard !running else { return }
        if case .failed = phase { await evaluate() }
    }

    func dismissLegacyNotice() {
        legacyNotice = nil
        migrator?.dismissNotice()
    }

    func dismissRejection() {
        rejectionMessage = nil
    }

    /// The gate reports scene activity. Leaving the foreground cancels
    /// the long-poll; returning starts it again and runs a cycle
    /// immediately so edits made on the web while backgrounded show up
    /// without waiting out the previous hold.
    func setForeground(_ active: Bool) {
        let returning = active && !foreground
        foreground = active
        guard coordinator?.instantWrites == true else { return }
        if active, isReady {
            coordinator?.startLiveUpdates()
            if returning {
                Task { await self.coordinator?.syncNow() }
            }
        } else if !active {
            coordinator?.stopLiveUpdates()
        }
    }

    func setOnline(_ online: Bool) {
        if isOnline != online { isOnline = online }
    }

    // MARK: - Online session

    /// Instant pushes and the rejection/connectivity callbacks. Called
    /// from `init` once every stored property exists.
    private func bind(_ coordinator: FinanceSyncCoordinator) {
        coordinator.instantWrites = true
        coordinator.onOnlineChange = { [weak self] online in
            self?.setOnline(online)
        }
        coordinator.onRejectedPush = { [weak self] reason in
            await self?.handleRejection(reason)
        }
    }

    /// The server refused a record. Drop the diverged local row by
    /// reloading the export — the same path as launch — and surface
    /// `reason` (already "Máy chủ từ chối thay đổi: …") once the screen
    /// is showing server truth again.
    func handleRejection(_ reason: String) async {
        await reload(message: reason)
    }

    /// Reloads the in-memory store from `GET /v1/backup/export`. Used by
    /// a rejected push, "Tải lại dữ liệu", a server data reset and a
    /// replace-restore. `message`, when non-nil, is the gate's alert
    /// once the store is ready again; nil clears any previous notice.
    /// Returns false when a reload is already running or the load failed
    /// (the phase is then `.failed` or `.signedOut`).
    @discardableResult
    func reload(message: String? = nil) async -> Bool {
        guard !reloading else { return false }
        reloading = true
        defer { reloading = false }
        coordinator?.stopLiveUpdates()
        phase = .loading
        do {
            let snapshot = try await api.exportSnapshot()
            try await bootstrap.loadOnline(snapshot: snapshot)
            LedgerBalanceStores.shared(for: container).invalidate()
            await afterLoad()
            rejectionMessage = message
            phase = .ready
            restartLiveUpdates()
            return true
        } catch FinanceSyncError.unauthorized {
            phase = .signedOut
            return false
        } catch {
            phase = .failed(Self.text(for: error))
            return false
        }
    }

    /// POST /v1/backup/import — REPLACE the server with `body` (a
    /// backup-v5 document). Callers reload afterwards so the in-memory
    /// store matches what the server just stored.
    func importBackup(_ body: Data) async throws {
        _ = try await api.importBackup(body)
    }

    /// "Đăng xuất": stop live updates, drop the in-memory ledger without
    /// pushing the wipe, revoke the WalletLink session, and return to
    /// the sign-in gate. Server data is left as it is.
    func signOut() async {
        guard !reloading else { return }
        coordinator?.stopLiveUpdates()
        await coordinator?.disconnect()
        let context = container.mainContext
        FinanceSyncSaveFilter.asEngine {
            try? BackupRestorer.deleteAllRows(in: context)
            try? context.save()
        }
        LedgerBalanceStores.shared(for: container).invalidate()
        await performSignOut()
        rejectionMessage = nil
        legacyNotice = nil
        signInError = nil
        phase = .signedOut
    }

    private func restartLiveUpdates() {
        guard let coordinator, coordinator.instantWrites, isReady, foreground else {
            return
        }
        coordinator.startLiveUpdates()
    }

    // MARK: - Pipeline

    private func evaluate() async {
        if await isSignedIn() {
            await run()
        } else {
            phase = .signedOut
        }
    }

    private func run() async {
        guard !running else { return }
        running = true
        defer { running = false }
        do {
            if let migrator, migrator.hasLegacyStore {
                phase = .migratingLegacy
                try await migrator.migrate()
            }
            phase = .loading
            let snapshot = try await api.exportSnapshot()
            try await bootstrap.loadOnline(snapshot: snapshot)
            LedgerBalanceStores.shared(for: container).invalidate()
            await afterLoad()
            legacyNotice = migrator?.pendingNotice
            phase = .ready
            restartLiveUpdates()
        } catch FinanceSyncError.unauthorized {
            phase = .signedOut
        } catch {
            phase = .failed(Self.text(for: error))
        }
    }

    static func text(for error: Error) -> String {
        FinanceSyncCoordinator.errorText(error)
    }
}

extension OnlineStore {
    /// The real launch pipeline over the coordinator's own stack: the
    /// shared WalletLink session signs in, an on-disk legacy store (if
    /// any) is migrated first. Under `-uiTestOnline` there is no real
    /// session and no on-disk store — the in-app fake serves everything.
    static func live(
        stack: FinanceSyncStack,
        container: ModelContainer,
        session: WalletLinkSession = .shared,
        fakeServer: Bool = false
    ) -> OnlineStore {
        let signIn: @MainActor () async throws -> Void
        let signOut: @MainActor () async -> Void
        if fakeServer {
            signIn = {}
            signOut = {}
        } else {
            signIn = { try await session.signIn() }
            signOut = { await session.signOut() }
        }
        return OnlineStore(
            container: container,
            api: stack.api,
            bootstrap: stack.bootstrap,
            migrator: fakeServer ? nil : LegacyStoreMigrator(api: stack.api),
            coordinator: stack.coordinator,
            isSignedIn: stack.isSignedIn,
            signIn: signIn,
            signOut: signOut,
            afterLoad: { await stack.coordinator.refreshState() })
    }

    /// Whether this launch runs the online pipeline: every real launch,
    /// plus the DEBUG `-uiTestOnline` flag beside
    /// `-uiTestInMemoryStore -uiTestFakeSyncServer`. Plain
    /// `-uiTestInMemoryStore` launches stay seeded and offline.
    static func usesOnlinePipeline(arguments: [String]) -> Bool {
        if !arguments.contains("-uiTestInMemoryStore") { return true }
        #if DEBUG
        return arguments.contains("-uiTestOnline")
            && arguments.contains("-uiTestFakeSyncServer")
        #else
        return false
        #endif
    }
}
