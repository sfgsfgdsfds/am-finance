import Foundation
import SwiftData
import UIKit

/// What the wallet-sync step produced: skipped when there is nothing to
/// do (signed out or no linked account), synced, or failed. Even a failed
/// sync reports the rows it already committed — page-by-page saves mean a
/// late failure still landed new imports.
struct BackgroundRefreshSyncResult: Equatable, Sendable {
    enum Status: String, Equatable, Sendable {
        case skipped
        case synced
        case failed
    }

    var status: Status = .skipped
    var insertedRows: [WalletSyncInsertedTransaction] = []
    var errorDescription: String?

    static let skipped = BackgroundRefreshSyncResult()
}

/// The wallet-sync step — the live wrapper drives `WalletSyncEngine`,
/// tests feed canned outcomes.
protocol BackgroundRefreshSyncing: Sendable {
    /// One sync pass; never throws — outcomes ride in the result.
    @MainActor func sync(now: Date) async -> BackgroundRefreshSyncResult
}

/// `RecurringGenerator` behind a seam.
protocol BackgroundRefreshRecurringGenerating: Sendable {
    /// Rows the generator posted; throws on store errors.
    @MainActor func generateDue(now: Date) throws -> Int
}

/// `ReminderScheduler.reschedule` behind a seam.
protocol BackgroundRefreshReminderScheduling: Sendable {
    /// Rebuilt reminder queue size.
    @MainActor func reschedule(now: Date) async throws -> Int
}

/// Runs the app's keep-fresh work inside a background refresh, on its own
/// `ModelContext`: (1) wallet sync, (2) two-way web sync,
/// (3) due recurring transactions, (4) reminder-queue rebuild — then a
/// local notification per new bank row. Every step is isolated so one
/// failure does not stop the others, and `Task.isCancelled` is honoured
/// between steps so a task expiration winds down cleanly instead of
/// being killed mid-write.
@MainActor
struct BackgroundRefreshRunner {
    /// Outcome of one runner step.
    enum StepOutcome: Equatable, Sendable {
        case skipped
        case ok
        case failed(String)
    }

    /// What one `run` did — returned to the BG task handler and asserted
    /// in tests.
    struct Summary: Equatable, Sendable {
        var sync: StepOutcome = .skipped
        /// Two-way web sync — skipped when the coordinator is absent,
        /// disabled or signed out. Never surfaces UI or notifications.
        var financeSync: StepOutcome = .skipped
        var recurring: StepOutcome = .skipped
        var reminders: StepOutcome = .skipped
        /// Bank rows the sync committed this run (even on a late failure).
        var newBankTransactions = 0
        var recurringCreated = 0
        var remindersPlanned = 0
        /// Local notifications actually posted to the center.
        var notificationsSent = 0
        /// The run saw task cancellation and stopped early.
        var cancelled = false
    }

    let sync: any BackgroundRefreshSyncing
    /// The two-way web-sync step — same `BackgroundRefreshSyncing` seam
    /// as the wallet step, nil when the app has no coordinator.
    let financeSync: (any BackgroundRefreshSyncing)?
    let generator: any BackgroundRefreshRecurringGenerating
    let reminders: any BackgroundRefreshReminderScheduling
    let settingsStore: ReminderSettingsStore
    let center: any BackgroundRefreshNotificationCentering
    /// True while the app is in the foreground — no notifications then.
    let isForegrounded: () -> Bool
    /// False while the online store has not loaded the server data (a
    /// background launch never reaches `ready`): the store is empty, so
    /// wallet sync would re-import, the recurring generator would post
    /// duplicate rows and the reminder rebuild would wipe the queue —
    /// every data step is skipped and only the re-arm remains.
    let isDataReady: () -> Bool

    init(
        sync: any BackgroundRefreshSyncing,
        generator: any BackgroundRefreshRecurringGenerating,
        reminders: any BackgroundRefreshReminderScheduling,
        financeSync: (any BackgroundRefreshSyncing)? = nil,
        settingsStore: ReminderSettingsStore,
        center: any BackgroundRefreshNotificationCentering,
        isForegrounded: @escaping () -> Bool = { false },
        isDataReady: @escaping () -> Bool = { true }
    ) {
        self.sync = sync
        self.generator = generator
        self.reminders = reminders
        self.financeSync = financeSync
        self.settingsStore = settingsStore
        self.center = center
        self.isForegrounded = isForegrounded
        self.isDataReady = isDataReady
    }

    /// Runs the four steps in order, isolated; then notifies about new
    /// bank rows. A cancelled task stops before the next step — whatever
    /// already committed stays committed. Not ready → all steps skipped.
    @discardableResult
    func run(now: Date = .now) async -> Summary {
        var summary = Summary()
        guard isDataReady() else { return summary }
        var newRows: [WalletSyncInsertedTransaction] = []

        if !Task.isCancelled {
            let result = await sync.sync(now: now)
            summary.sync = outcome(of: result)
            newRows = result.insertedRows
            summary.newBankTransactions = newRows.count
        }
        summary.cancelled = Task.isCancelled

        if !summary.cancelled, let financeSync {
            let result = await financeSync.sync(now: now)
            summary.financeSync = outcome(of: result)
            summary.cancelled = Task.isCancelled
        }

        if !summary.cancelled {
            do {
                summary.recurringCreated = try generator.generateDue(now: now)
                summary.recurring = .ok
            } catch {
                summary.recurring = .failed(error.localizedDescription)
            }
            summary.cancelled = Task.isCancelled
        }

        if !summary.cancelled {
            do {
                summary.remindersPlanned = try await reminders.reschedule(now: now)
                summary.reminders = .ok
            } catch {
                summary.reminders = .failed(error.localizedDescription)
            }
            summary.cancelled = Task.isCancelled
        }

        if !summary.cancelled, !newRows.isEmpty {
            summary.notificationsSent = await notify(newRows: newRows)
        }
        return summary
    }

    private func outcome(
        of result: BackgroundRefreshSyncResult
    ) -> StepOutcome {
        switch result.status {
        case .skipped: return .skipped
        case .synced: return .ok
        case .failed: return .failed(result.errorDescription ?? "")
        }
    }

    /// Delivers the planned notifications — gated on the app's own
    /// switch, the system permission, and the app really being in the
    /// background. One bad item never blocks the rest.
    private func notify(
        newRows: [WalletSyncInsertedTransaction]
    ) async -> Int {
        guard !isForegrounded() else { return 0 }
        guard settingsStore.load().bankTransactions else { return 0 }
        guard await center.authorizationStatus().canDeliver else { return 0 }
        var sent = 0
        for item in BackgroundRefreshNotificationPlan.plan(inserted: newRows) {
            if (try? await center.deliver(item)) != nil { sent += 1 }
        }
        return sent
    }
}

// MARK: - Live wiring

/// Lock-protected accumulator the engine's page callback fills from
/// whichever executor the sync ran on — read back on the caller's actor
/// once `syncAll` returns or throws.
private final class WalletSyncInsertedCollector: @unchecked Sendable {
    private var storage: [WalletSyncInsertedTransaction] = []
    private let lock = NSLock()

    var rows: [WalletSyncInsertedTransaction] {
        lock.lock()
        defer { lock.unlock() }
        return storage
    }

    func append(_ page: [WalletSyncInsertedTransaction]) {
        lock.lock()
        storage.append(contentsOf: page)
        lock.unlock()
    }
}

/// The real sync step: shared session, UserDefaults stores, the runner's
/// own model context, the live wallet API — the same pieces the
/// foreground coordinator wires, minus its UI state. Only ever touched on
/// the main actor (the protocol's method is `@MainActor`), hence
/// `@unchecked Sendable` — same reasoning as `ReminderScheduler`.
private struct LiveBackgroundRefreshSync:
    BackgroundRefreshSyncing, @unchecked Sendable {
    let session: WalletLinkSession
    let defaults: UserDefaults
    let context: ModelContext

    @MainActor
    func sync(now: Date) async -> BackgroundRefreshSyncResult {
        guard case .signedIn = await session.status else { return .skipped }
        guard !WalletSyncEngine.linkedAccounts(context: context).isEmpty
        else { return .skipped }
        let committed = WalletSyncInsertedCollector()
        do {
            let resolved = try WalletLinkConfigStore(defaults: defaults)
                .load().resolved()
            var engine = WalletSyncEngine(
                api: WalletAPIClient(
                    baseURL: resolved.walletBaseURL, tokenProvider: session),
                stateStore: WalletSyncStateStore(defaults: defaults),
                ruleStore: WalletSyncRuleStore(defaults: defaults),
                context: context
            )
            // Pages the run commits before a failure are still new rows
            // worth notifying about.
            engine.onPageCommitted = { committed.append($0) }
            _ = try await engine.syncAll(now: now)
            return BackgroundRefreshSyncResult(
                status: .synced, insertedRows: committed.rows)
        } catch {
            return BackgroundRefreshSyncResult(
                status: .failed,
                insertedRows: committed.rows,
                errorDescription: error.localizedDescription)
        }
    }
}

/// The real two-way web-sync step — just the shared coordinator: it
/// already knows the shadow, API client and sign-in probe, and it
/// decides "nothing to do" itself (disabled or signed out → `skipped`).
/// Pulled rows are the user's own data landing on another device, so
/// nothing here ever notifies — `insertedRows` stays empty.
private struct LiveFinanceSyncStep:
    BackgroundRefreshSyncing, @unchecked Sendable {
    let coordinator: FinanceSyncCoordinator

    @MainActor
    func sync(now: Date) async -> BackgroundRefreshSyncResult {
        guard coordinator.enabled else { return .skipped }
        guard await coordinator.checkSignedIn() else { return .skipped }
        let ok = await coordinator.syncNow()
        if ok {
            return BackgroundRefreshSyncResult(status: .synced)
        }
        // syncNow leaves either a mapped error (failed) or none
        // (the gate above raced a disable/sign-out → skipped).
        if let error = coordinator.lastError {
            return BackgroundRefreshSyncResult(
                status: .failed, errorDescription: error)
        }
        return .skipped
    }
}

/// Posts due recurring transactions on the runner's context.
private struct LiveRecurringGenerator:
    BackgroundRefreshRecurringGenerating, @unchecked Sendable {
    let context: ModelContext

    @MainActor
    func generateDue(now: Date) throws -> Int {
        try RecurringGenerator.generateDueTransactions(in: context, now: now)
    }
}

/// Rebuilds the reminder queue on the runner's context.
private struct LiveReminderRescheduler:
    BackgroundRefreshReminderScheduling, @unchecked Sendable {
    let context: ModelContext
    let scheduler: ReminderScheduler

    @MainActor
    func reschedule(now: Date) async throws -> Int {
        await scheduler.reschedule(context: context, now: now).count
    }
}

extension BackgroundRefreshRunner {
    /// The app's runner: own `ModelContext` on the shared store's
    /// container, the standard stores and the real notification center.
    /// `financeSync` is the app-level coordinator — nil disables the
    /// web-sync step entirely.
    static func live(
        container: ModelContainer,
        defaults: UserDefaults = .standard,
        session: WalletLinkSession = .shared,
        financeSync: FinanceSyncCoordinator? = nil,
        onlineStore: OnlineStore? = nil
    ) -> BackgroundRefreshRunner {
        let context = ModelContext(container)
        let settingsStore = ReminderSettingsStore(defaults: defaults)
        return BackgroundRefreshRunner(
            sync: LiveBackgroundRefreshSync(
                session: session, defaults: defaults, context: context),
            generator: LiveRecurringGenerator(context: context),
            reminders: LiveReminderRescheduler(
                context: context,
                scheduler: ReminderScheduler(settingsStore: settingsStore)),
            financeSync: financeSync.map {
                LiveFinanceSyncStep(coordinator: $0)
            },
            settingsStore: settingsStore,
            center: BackgroundRefreshUserNotificationCenter(),
            isForegrounded: {
                UIApplication.shared.applicationState != .background
            },
            isDataReady: { onlineStore?.isReady ?? true }
        )
    }
}
