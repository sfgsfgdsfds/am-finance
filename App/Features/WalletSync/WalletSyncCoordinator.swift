import Foundation
import SwiftData
import SwiftUI
import Combine

/// Runs wallet sync on demand or on a staleness timer. Never runs two
/// syncs at once — callers arriving mid-run piggyback on the in-flight
/// task. No-ops when signed out or when nothing is linked.
@MainActor
@Observable
final class WalletSyncCoordinator {
    enum SyncState: Equatable {
        case idle
        case syncing
        case failed(String)
    }

    private(set) var syncState: SyncState = .idle
    /// Seeded from the state store at init, refreshed on each success.
    private(set) var lastSyncAt: Date?
    private(set) var pendingReviewCount: Int
    private(set) var lastSummary: WalletSyncSummary?

    private let isSignedIn: @Sendable () async -> Bool
    private let hasLinkedAccounts: @MainActor () -> Bool
    private let runSync: @MainActor (Bool) async throws -> WalletSyncSummary
    private let countPendingReview: @MainActor () -> Int
    private var inFlight: Task<Bool, Never>?

    init(
        isSignedIn: @escaping @Sendable () async -> Bool,
        hasLinkedAccounts: @escaping @MainActor () -> Bool,
        runSync: @escaping @MainActor (Bool) async throws -> WalletSyncSummary,
        countPendingReview: @escaping @MainActor () -> Int,
        lastSyncAt: Date? = nil
    ) {
        self.isSignedIn = isSignedIn
        self.hasLinkedAccounts = hasLinkedAccounts
        self.runSync = runSync
        self.countPendingReview = countPendingReview
        self.lastSyncAt = lastSyncAt
        self.pendingReviewCount = countPendingReview()
    }

    var isSyncing: Bool { syncState == .syncing }

    /// Vietnamese message of the last failure, if any.
    var errorMessage: String? {
        if case .failed(let message) = syncState { return message }
        return nil
    }

    /// Re-read the inbox count — cheap; views call it after local edits.
    func refreshPendingCount() {
        pendingReviewCount = countPendingReview()
    }

    /// Starts a sync unless one is already running; concurrent callers get
    /// the in-flight run's result. Returns false without side effects when
    /// signed out or nothing is linked. `fullRescan` re-reads every linked
    /// account from the start cursor — the manual "Đồng bộ lại toàn bộ".
    @discardableResult
    func syncNow(fullRescan: Bool = false) async -> Bool {
        if let inFlight { return await inFlight.value }
        let task = Task { await performSync(fullRescan: fullRescan) }
        inFlight = task
        defer { inFlight = nil }
        return await task.value
    }

    /// Sync only when the last successful sync is older than `maxAge`
    /// seconds (or never happened).
    @discardableResult
    func syncIfStale(maxAge: TimeInterval = 60) async -> Bool {
        if let lastSyncAt, Date.now.timeIntervalSince(lastSyncAt) < maxAge {
            return false
        }
        return await syncNow()
    }

    private func performSync(fullRescan: Bool) async -> Bool {
        guard await isSignedIn(), hasLinkedAccounts() else { return false }
        syncState = .syncing
        do {
            let summary = try await runSync(fullRescan)
            lastSummary = summary
            lastSyncAt = .now
            syncState = .idle
        } catch {
            syncState = .failed(error.localizedDescription)
        }
        refreshPendingCount()
        return syncState == .idle
    }
}

extension WalletSyncCoordinator {
    /// The app's coordinator: the shared session, UserDefaults stores, the
    /// app's model context, and the live API. `api` injects a fake for
    /// previews and tests.
    static func live(
        context: ModelContext,
        session: WalletLinkSession = .shared,
        defaults: UserDefaults = .standard,
        api: (any WalletSyncAPI)? = nil
    ) -> WalletSyncCoordinator {
        let stateStore = WalletSyncStateStore(defaults: defaults)
        let ruleStore = WalletSyncRuleStore(defaults: defaults)
        return WalletSyncCoordinator(
            isSignedIn: {
                if case .signedIn = await session.status { return true }
                return false
            },
            hasLinkedAccounts: {
                !WalletSyncEngine.linkedAccounts(context: context).isEmpty
            },
            runSync: { fullRescan in
                let client: any WalletSyncAPI
                if let api {
                    client = api
                } else {
                    let resolved = try WalletLinkConfigStore(defaults: defaults)
                        .load().resolved()
                    client = WalletAPIClient(
                        baseURL: resolved.walletBaseURL, tokenProvider: session)
                }
                return try await WalletSyncEngine(
                    api: client,
                    stateStore: stateStore,
                    ruleStore: ruleStore,
                    context: context
                ).syncAll(fullRescan: fullRescan)
            },
            countPendingReview: {
                WalletSyncEngine.pendingReviewCount(context: context)
            },
            lastSyncAt: stateStore.lastSyncAt
        )
    }
}

/// Auto-sync attached to a view: `syncIfStale` on appear, whenever the
/// scene becomes active, and every 60 seconds while it stays active.
/// With no explicit coordinator it builds the live one from the
/// environment's model context — the integration job only has to attach
/// `.walletSyncAutoRefresh()` to the root view.
private struct WalletSyncAutoRefreshModifier: ViewModifier {
    let coordinator: WalletSyncCoordinator?

    @Environment(\.modelContext) private var context
    @Environment(\.scenePhase) private var scenePhase
    @State private var own: WalletSyncCoordinator?

    private let timer = Timer.publish(every: 60, on: .main, in: .common)
        .autoconnect()

    private var resolved: WalletSyncCoordinator? {
        coordinator ?? own
    }

    func body(content: Content) -> some View {
        content
            .task {
                if resolved == nil {
                    own = .live(context: context)
                }
                await resolved?.syncIfStale()
            }
            .onChange(of: scenePhase) { _, phase in
                guard phase == .active else { return }
                Task { await resolved?.syncIfStale() }
            }
            .onReceive(timer) { _ in
                guard scenePhase == .active else { return }
                Task { await resolved?.syncIfStale() }
            }
    }
}

extension View {
    /// Auto-sync linked wallet accounts while this view is on screen —
    /// see `WalletSyncCoordinator.syncIfStale`.
    func walletSyncAutoRefresh(
        _ coordinator: WalletSyncCoordinator? = nil
    ) -> some View {
        modifier(WalletSyncAutoRefreshModifier(coordinator: coordinator))
    }
}
