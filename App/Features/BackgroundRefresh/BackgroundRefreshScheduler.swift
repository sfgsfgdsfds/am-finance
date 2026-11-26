import BackgroundTasks
import Foundation
import SwiftData

/// Owns the app's single `BGAppRefreshTask` — the "vn.amx.finance.refresh"
/// identifier declared in the Info.plist. Registers the handler once at
/// launch, and keeps one refresh request outstanding at all times: a new
/// request is submitted whenever the app enters the background and at the
/// end of every run, so the chain never dies.
///
/// iOS alone decides when the task actually fires — the earliest-begin
/// date is a lower bound, not a timer. Everything here is inert under
/// `-uiTestInMemoryStore` and submission errors are swallowed (the
/// simulator cannot run refresh tasks).
enum BackgroundRefreshScheduler {
    /// Must match `BGTaskSchedulerPermittedIdentifiers` in the plist.
    static let taskIdentifier = "vn.amx.finance.refresh"
    /// How far out each request's earliest-begin date sits — ~15 minutes.
    static let earliestBeginDelay: TimeInterval = 15 * 60

    @MainActor private static var didRegister = false

    /// True under `-uiTestInMemoryStore` — UI tests must never touch the
    /// system scheduler.
    private static var isDisabled: Bool {
        AppLockSettingsStore.isUITestLaunch()
    }

    /// Registers the refresh handler once. Call at launch, before the
    /// first scene — `BGTaskScheduler` requires registration to complete
    /// before the launch sequence finishes. There is no web-sync step:
    /// the in-memory store is not loaded in the background.
    @MainActor
    static func registerHandler(
        container: ModelContainer,
        onlineStore: OnlineStore? = nil
    ) {
        guard !didRegister, !isDisabled else { return }
        didRegister = true
        BGTaskScheduler.shared.register(
            forTaskWithIdentifier: taskIdentifier, using: nil
        ) { task in
            guard let refresh = task as? BGAppRefreshTask else {
                task.setTaskCompleted(success: false)
                return
            }
            handle(
                task: refresh, container: container,
                onlineStore: onlineStore)
        }
    }

    /// Submits the next refresh, ~15 minutes out. Called on every
    /// background transition and after each run — a new request replaces
    /// the pending one for the same identifier. Callable from anywhere.
    static func scheduleNext(now: Date = .now) {
        guard !isDisabled else { return }
        let request = BGAppRefreshTaskRequest(identifier: taskIdentifier)
        request.earliestBeginDate = now.addingTimeInterval(earliestBeginDelay)
        // Submission can fail where refresh is unavailable (simulator,
        // restrictions, Low Power Mode) — the next call simply retries.
        try? BGTaskScheduler.shared.submit(request)
    }

    /// The refresh handler: run the housekeeping on the main actor,
    /// re-arm, then report. On expiration the work task is cancelled —
    /// the engine's page-by-page saves plus the runner's per-step
    /// cancellation checks unwind quickly and never strand a half-saved
    /// import.
    private static func handle(
        task: BGAppRefreshTask, container: ModelContainer,
        onlineStore: OnlineStore?
    ) {
        let box = BackgroundTaskBox(task)
        let work = Task { @MainActor in
            let runner = BackgroundRefreshRunner.live(
                container: container, onlineStore: onlineStore)
            let summary = await runner.run()
            scheduleNext()
            box.task.setTaskCompleted(success: !summary.cancelled)
        }
        task.expirationHandler = { work.cancel() }
    }
}

/// `BGTask` predates strict concurrency — the system object's completion
/// call is safe from any queue (the expiration handler itself runs
/// off-main), so boxing it for the runner task is honest.
private final class BackgroundTaskBox: @unchecked Sendable {
    let task: BGTask
    init(_ task: BGTask) { self.task = task }
}
