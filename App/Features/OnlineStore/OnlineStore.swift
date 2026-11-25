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

    var isReady: Bool { phase == .ready }

    private let container: ModelContainer
    private let api: FinanceSyncAPIClient
    private let bootstrap: FinanceSyncBootstrap
    private let migrator: LegacyStoreMigrator?
    private let isSignedIn: @Sendable () async -> Bool
    private let performSignIn: @MainActor () async throws -> Void
    private let afterLoad: @MainActor () async -> Void
    private var started = false
    private var running = false

    init(
        container: ModelContainer,
        api: FinanceSyncAPIClient,
        bootstrap: FinanceSyncBootstrap,
        migrator: LegacyStoreMigrator? = nil,
        isSignedIn: @escaping @Sendable () async -> Bool,
        signIn: @escaping @MainActor () async throws -> Void,
        afterLoad: @escaping @MainActor () async -> Void = {}
    ) {
        self.container = container
        self.api = api
        self.bootstrap = bootstrap
        self.migrator = migrator
        self.isSignedIn = isSignedIn
        self.performSignIn = signIn
        self.afterLoad = afterLoad
    }

    /// Entry point of the gate view — idempotent.
    func start() async {
        guard !started else { return }
        started = true
        await evaluate()
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
        OnlineStore(
            container: container,
            api: stack.api,
            bootstrap: stack.bootstrap,
            migrator: fakeServer ? nil : LegacyStoreMigrator(api: stack.api),
            isSignedIn: stack.isSignedIn,
            signIn: fakeServer ? {} : { try await session.signIn() },
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
