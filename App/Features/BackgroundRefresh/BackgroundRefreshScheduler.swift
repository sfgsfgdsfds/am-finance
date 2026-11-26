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
    ///
    /// The closure handed to `BGTaskScheduler` is built in
    /// `installLaunchHandler`, which is `nonisolated`. A closure literal
    /// written in this `@MainActor` function is inferred `@MainActor`
    /// (Swift 6), and the scheduler invokes it on a background queue
    /// (`using: nil`) — the runtime isolation check then traps
    /// (`swift_task_isCurrentExecutor` / `SIGTRAP`).
    @MainActor
    static func registerHandler(
        container: ModelContainer,
        onlineStore: OnlineStore? = nil
    ) {
        guard !didRegister, !isDisabled else { return }
        didRegister = true
        installLaunchHandler(BackgroundRefreshLaunchDependencies(
            container: container, onlineStore: onlineStore))
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

    /// Body of the launch handler. `nonisolated` and synchronous so a
    /// background queue — and unit tests, via `Task.detached` — can call
    /// it without hopping. The runner itself runs inside
    /// `Task { @MainActor in }`. `setTaskCompleted` fires exactly once,
    /// from whichever of the work task and the expiration handler wins;
    /// both are safe to call off the main thread.
    nonisolated static func handleLaunch(
        task: any BackgroundRefreshTaskHandling,
        run: @escaping @MainActor () async -> BackgroundRefreshRunner.Summary,
        scheduleNext: @escaping @Sendable () -> Void
    ) {
        let gate = BackgroundRefreshCompletionGate { success in
            task.setTaskCompleted(success: success)
        }
        guard task.isAppRefresh else {
            gate.complete(success: false)
            return
        }
        let work = Task { @MainActor in
            let summary = await run()
            scheduleNext()
            gate.complete(success: !summary.cancelled)
        }
        // `@Sendable` so this closure is not inferred `@MainActor`.
        // The system calls it on a background queue, and it must call
        // `setTaskCompleted` before returning — iOS kills the app
        // otherwise. The gate drops the work task's later attempt.
        task.setExpirationHandler { @Sendable in
            work.cancel()
            gate.complete(success: false)
        }
    }

    /// Forms the system launch handler outside any actor. Do not move
    /// this closure into `registerHandler` — see that method.
    private nonisolated static func installLaunchHandler(
        _ dependencies: BackgroundRefreshLaunchDependencies
    ) {
        BGTaskScheduler.shared.register(
            forTaskWithIdentifier: taskIdentifier, using: nil
        ) { task in
            handleLaunch(
                task: SystemBackgroundRefreshTask(task),
                run: { @MainActor in
                    let runner = BackgroundRefreshRunner.live(
                        container: dependencies.container,
                        onlineStore: dependencies.onlineStore)
                    return await runner.run()
                },
                scheduleNext: { @Sendable in scheduleNext() }
            )
        }
    }
}

/// The slice of `BGTask` the launch handler uses. The system object is
/// not `Sendable` and cannot be constructed in tests.
protocol BackgroundRefreshTaskHandling: AnyObject, Sendable {
    var isAppRefresh: Bool { get }
    func setExpirationHandler(_ handler: @escaping @Sendable () -> Void)
    func setTaskCompleted(success: Bool)
}

/// Captured at registration. `OnlineStore` is main-actor isolated and is
/// read only after the handler hops to the main actor.
private final class BackgroundRefreshLaunchDependencies: @unchecked Sendable {
    let container: ModelContainer
    let onlineStore: OnlineStore?
    init(container: ModelContainer, onlineStore: OnlineStore?) {
        self.container = container
        self.onlineStore = onlineStore
    }
}

/// `BGTask` predates strict concurrency. Completion and the expiration
/// handler are safe from any queue; the class opts out of `Sendable`
/// checking so the nonisolated launch handler can hold the system object.
private final class SystemBackgroundRefreshTask: BackgroundRefreshTaskHandling,
    @unchecked Sendable {
    private let task: BGTask
    let isAppRefresh: Bool

    init(_ task: BGTask) {
        self.task = task
        self.isAppRefresh = task is BGAppRefreshTask
    }

    func setExpirationHandler(_ handler: @escaping @Sendable () -> Void) {
        task.expirationHandler = handler
    }

    func setTaskCompleted(success: Bool) {
        task.setTaskCompleted(success: success)
    }
}

/// Calls the finish closure at most once. The work task and the
/// expiration handler race; `BGTask` asserts on a second
/// `setTaskCompleted`.
private final class BackgroundRefreshCompletionGate: @unchecked Sendable {
    private let lock = NSLock()
    private var didComplete = false
    private let finish: @Sendable (Bool) -> Void

    init(_ finish: @escaping @Sendable (Bool) -> Void) {
        self.finish = finish
    }

    func complete(success: Bool) {
        lock.lock()
        let first = !didComplete
        if first { didComplete = true }
        lock.unlock()
        // Outside the lock: `finish` calls into the system object, which
        // must not re-enter `complete` on the same thread and deadlock.
        if first { finish(success) }
    }
}
