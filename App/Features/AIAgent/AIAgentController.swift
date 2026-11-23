import SwiftUI
import SwiftData
import UIKit

/// ONE app-level Agent conversation shared by every entry point — the
/// dashboard sparkles button, the Giao dịch toolbar button and
/// Cài đặt → "Agent". `AIAgentControllers.shared(for:)` keeps exactly
/// one controller per model container for the app's lifetime, so the
/// `AIAgentChatSession` it owns survives pushes, pops and tab
/// switches: an in-flight turn keeps running while the user is
/// elsewhere, and leaving + returning shows the finished reply.
///
/// Session lifetime — the conversation is replaced ONLY when:
/// - the user taps "Cuộc trò chuyện mới" (`newConversation`);
/// - the provider DESTINATION really changes: the decoded active
///   `AIProviderProfile` differs from the one the session belongs to
///   (a transient `makeClient` failure or an identical re-read keeps
///   the chat — the screen shows "Chưa cấu hình AI" while the session
///   waits);
/// - `.dataResetCompleted` fires — the session's `R…`/`A…`/`C…` row
///   handles point at deleted data.
///
/// It is NOT replaced when the screen disappears (pop, tab switch,
/// app-lock overlay, scene-phase changes), when the access level
/// changes (the session's `accessProvider` re-reads the grant on every
/// turn; with access off the view shows the no-permission state and
/// sending is blocked, but the conversation stays), or when
/// `aiAgent.includeNotes` flips (`syncSettings` writes the new value
/// into the live session).
@MainActor @Observable
final class AIAgentController {
    /// The persisted grant — the AppStorage key `AMFinanceApp` clears on
    /// UI-test launches so every run starts at the real default, `.off`.
    nonisolated static let accessDefaultsKey = "aiAgent.access"
    /// Whether transaction notes ride the agent's tool results —
    /// `AMFinanceApp` clears it on UI-test launches too.
    nonisolated static let includeNotesDefaultsKey = "aiAgent.includeNotes"

    /// The container the session's reads and confirmed writes run on.
    let container: ModelContainer
    /// The active-provider source — also handed to `AISettingsView`.
    let providerStore: AIProviderStore

    /// Defaults the grant + notes keys live in — the session's
    /// `accessProvider` captures the instance itself so the grant is
    /// re-read live on every turn.
    let defaults: UserDefaults
    private let notificationCenter: NotificationCenter
    private let injectedClient: (any AIChatClientProtocol)?
    /// Builds a client from a profile — `providerStore.makeClient` in
    /// the app, a throwing/toggling seam in tests.
    private let clientFactory:
        (AIProviderStore, AIProviderProfile) throws -> any AIChatClientProtocol
    /// Background-grace plumbing — `UIApplication` in the app, counters
    /// in tests.
    private let beginTask:
        @MainActor (@escaping () -> Void) -> UIBackgroundTaskIdentifier
    private let endTask: @MainActor (UIBackgroundTaskIdentifier) -> Void
    private var resetObserver: (any NSObjectProtocol)?

    /// The shared conversation — nil until a client + a usable grant
    /// allow one, or after a drop that could not be restarted.
    private(set) var session: AIAgentChatSession?
    /// The working client — nil while the provider is unconfigured or
    /// its build fails transiently (the session is kept either way).
    private(set) var client: (any AIChatClientProtocol)?
    /// The exact non-secret snapshot `client` was built from — compared
    /// whole, so an in-place edit of the same profile counts as
    /// "provider changed". API keys never appear in it.
    private(set) var providerProfile: AIProviderProfile?
    private(set) var providerName = ""
    /// nil→checked flip avoids flashing an empty state while the store
    /// is first read.
    private(set) var providerChecked = false
    /// The fixed retry hint after a stale send.
    var providerNotice: String?
    /// A reply, proposal or error landed while no Agent screen was
    /// visible — cleared by the next `noteScreenAppeared`.
    private(set) var hasUnreadActivity = false

    /// The active profile the current session belongs to — the
    /// "destination" whose change is the only provider-driven reason to
    /// drop the conversation. Tracked separately from `providerProfile`
    /// so a `makeClient` failure does not fake a destination change.
    private var destination: AIProviderProfile?
    /// Agent screens currently visible — the unread flag only sets
    /// while this is zero.
    private var visibleScreens = 0
    private var backgroundTask: UIBackgroundTaskIdentifier = .invalid
    private var watchTask: Task<Void, Never>?

    init(
        container: ModelContainer,
        providerStore: AIProviderStore = AIProviderStore(),
        client: (any AIChatClientProtocol)? = nil,
        clientFactory: @escaping (AIProviderStore, AIProviderProfile)
            throws -> any AIChatClientProtocol = {
                try $0.makeClient(profile: $1)
            },
        defaults: UserDefaults = .standard,
        notificationCenter: NotificationCenter = .default,
        beginBackgroundTask: (
            @MainActor (@escaping () -> Void) -> UIBackgroundTaskIdentifier
        )? = nil,
        endBackgroundTask: (
            @MainActor (UIBackgroundTaskIdentifier) -> Void
        )? = nil
    ) {
        self.container = container
        self.providerStore = providerStore
        self.clientFactory = clientFactory
        self.defaults = defaults
        self.notificationCenter = notificationCenter
        self.beginTask = beginBackgroundTask ?? { expiration in
            UIApplication.shared.beginBackgroundTask(
                withName: "vn.amx.finance.agentTurn",
                expirationHandler: expiration)
        }
        self.endTask = endBackgroundTask ?? {
            UIApplication.shared.endBackgroundTask($0)
        }
        #if DEBUG
        // `-uiTestAgentScript` (honoured only beside the in-memory
        // UI-test store) replaces the provider: the screen counts as
        // configured and the deterministic script answers.
        self.injectedClient = client
            ?? (AIAgentUITestScript.isEnabled
                ? AIAgentUITestScript.Client() : nil)
        #else
        self.injectedClient = client
        #endif
        resetObserver = notificationCenter.addObserver(
            forName: .dataResetCompleted, object: nil, queue: nil
        ) { [weak self] _ in
            Task { @MainActor in self?.resetAfterDataWipe() }
        }
    }

    // MARK: - Persisted switches (live reads)

    /// The current grant — read LIVE from persisted defaults every
    /// time, so the session's per-turn re-check sees a mid-turn
    /// revocation. The `accessProvider` given to the session captures
    /// `defaults` directly, keeping the closure a plain non-Sendable
    /// `() -> AIAgentAccess` with no `self` in the cycle.
    var access: AIAgentAccess {
        Self.accessValue(in: defaults)
    }

    /// The notes switch — same live read; `syncSettings` copies it into
    /// the live session so a flip never costs the conversation.
    var includeNotes: Bool {
        (defaults.object(forKey: Self.includeNotesDefaultsKey) as? Bool)
            ?? true
    }

    /// Reads the persisted grant straight from the defaults the
    /// `aiAgent.access` AppStorage wraps.
    nonisolated static func accessValue(
        in defaults: UserDefaults
    ) -> AIAgentAccess {
        AIAgentAccess(
            rawValue: defaults.string(forKey: accessDefaultsKey)
                ?? AIAgentAccess.off.rawValue) ?? .off
    }

    /// Re-reads the persisted switches into the live session — the
    /// grant needs no sync (the session re-reads it per turn) but
    /// `includeNotes` is a stored property that must be written. The
    /// view calls this on every appear and on its AppStorage change.
    func syncSettings() {
        session?.includeNotes = includeNotes
    }

    // MARK: - Screen visibility & the entry dot

    /// An Agent screen appeared — the conversation it shows is by
    /// definition seen, so the unread flag clears.
    func noteScreenAppeared() {
        visibleScreens += 1
        hasUnreadActivity = false
    }

    /// An Agent screen left the top — pops and covered pushes both land
    /// here; a turn ending past this point may mark
    /// `hasUnreadActivity`.
    func noteScreenDisappeared() {
        visibleScreens = max(0, visibleScreens - 1)
    }

    /// What the three entry points badge: the agent is mid-turn, or a
    /// turn ended with something new while no screen was watching.
    var showsEntryIndicator: Bool {
        hasUnreadActivity || session?.isWorking == true
    }

    // MARK: - User actions

    /// One question leaves the device — the provider snapshot is
    /// re-checked first so a message never silently goes to a different
    /// destination than the one the session started on. Returns false
    /// when nothing was sent (blank text, no session, or a stale
    /// provider — which leaves the retry notice instead).
    @discardableResult
    func send(_ text: String) -> Bool {
        ensureSession()
        guard access.canLookup, let session,
              !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        else { return false }
        guard providerIsCurrent else { providerStale(); return false }
        providerNotice = nil
        session.send(text)
        watchTurn(session)
        return true
    }

    /// Resumes a failed turn — the same watch covers its background
    /// grace and the unseen-completion marker.
    func retry() {
        guard let session, session.canRetry else { return }
        session.retry()
        watchTurn(session)
    }

    /// "Cuộc trò chuyện mới" — a fresh session on the current provider
    /// and grant. Nothing is persisted, so this drops everything.
    func newConversation() {
        dropSession()
        providerNotice = nil
        ensureSession()
    }

    // MARK: - Session & provider

    /// Resolves the active provider into `client` + snapshot — runs on
    /// every Agent-screen appear, so a destination change made in
    /// settings is caught on return. The session is dropped ONLY when
    /// the decoded active profile differs from `destination`; a
    /// transient `makeClient` failure keeps the conversation while the
    /// screen shows "Chưa cấu hình AI".
    func refreshProvider() {
        let active = providerStore.activeProfile()
        let destinationChanged = active != destination
        destination = active
        if let injectedClient {
            client = injectedClient
            providerProfile = active
            providerName = active?.name ?? ""
        } else if let profile = active,
                  let made = try? clientFactory(providerStore, profile) {
            client = made
            providerProfile = profile
            let name = profile.name.trimmingCharacters(
                in: .whitespacesAndNewlines)
            providerName = name.isEmpty ? profile.trimmedModel : name
        } else {
            // No active profile or a transient build failure —
            // `destination` still tracks the profile, so the session
            // survives the gap.
            client = nil
            providerProfile = nil
            providerName = ""
        }
        providerChecked = true
        if destinationChanged {
            dropSession()
        }
        ensureSession()
    }

    /// Stops the in-flight turn and drops the session — destination
    /// changes, "Cuộc trò chuyện mới" and data wipes all land here.
    private func dropSession() {
        session?.stop()
        session = nil
    }

    /// Builds the session when inputs allow one (a client + a usable
    /// grant). The read tools' grant is re-read live from the defaults
    /// so a mid-turn revocation still stops the loop.
    private func ensureSession() {
        guard session == nil, let client, access.canLookup else { return }
        let defaults = defaults
        session = AIAgentChatSession(
            client: client,
            context: container.mainContext,
            accessProvider: { Self.accessValue(in: defaults) },
            includeNotes: includeNotes,
            defaults: defaults)
    }

    /// True only while the store's ACTIVE profile still equals, field
    /// by field, the non-secret snapshot `client` was built from.
    private var providerIsCurrent: Bool {
        if injectedClient != nil { return true }
        guard let providerProfile else { return false }
        return providerStore.activeProfile() == providerProfile
    }

    /// A send caught the active profile no longer matching the client's
    /// snapshot: rebind to whatever is active now (which drops the
    /// session when the destination really changed) and leave a retry
    /// hint. Nothing profile-shaped is ever shown or logged — the
    /// notice is a fixed string.
    private func providerStale() {
        refreshProvider()
        providerNotice =
            "Cấu hình nhà cung cấp AI đã đổi — hãy gửi lại để đúng nơi nhận."
    }

    /// `.dataResetCompleted` — the wiped store leaves every row handle
    /// pointing at deleted objects, so the conversation starts over on
    /// the reseeded ledger (the container itself is unchanged, hence a
    /// reset inside the controller rather than a new instance).
    private func resetAfterDataWipe() {
        dropSession()
        hasUnreadActivity = false
        endBackgroundGrace()
        ensureSession()
    }

    // MARK: - Turn watch & background grace

    /// Starts following a turn: holds a `beginBackgroundTask` for the
    /// in-flight stretch so a reply still lands if the user leaves the
    /// app, and marks `hasUnreadActivity` when the turn ends with no
    /// Agent screen watching. The task ends when the turn does or when
    /// the system expires it — nothing is ever auto-applied.
    private func watchTurn(_ session: AIAgentChatSession) {
        guard session.isWorking else { return }
        holdBackgroundTask()
        guard watchTask == nil else { return }
        watchTask = Task { [weak self, weak session] in
            while let session, session.isWorking, !Task.isCancelled {
                try? await Task.sleep(for: .milliseconds(120))
            }
            guard let self else { return }
            self.watchTask = nil
            self.endBackgroundGrace()
            if let session { self.markUnreadIfUnseen(session) }
        }
    }

    /// A turn ended with nobody watching: flag the conversation when it
    /// finished with something new (reply, proposal or error). A
    /// replaced session's turn never marks the fresh conversation
    /// unread.
    private func markUnreadIfUnseen(_ session: AIAgentChatSession) {
        guard self.session === session, visibleScreens == 0 else { return }
        let landed = session.pendingProposal != nil
            || session.error != nil
            || session.messages.last.map { $0.kind != .user } == true
        if landed { hasUnreadActivity = true }
    }

    /// `beginBackgroundTask` while a turn is in flight — the app may
    /// then finish the model round-trip after the user leaves. Ended by
    /// the turn watcher or by the system expiration handler, never
    /// twice.
    private func holdBackgroundTask() {
        guard backgroundTask == .invalid else { return }
        backgroundTask = beginTask { [weak self] in
            Task { @MainActor in self?.endBackgroundGrace() }
        }
    }

    private func endBackgroundGrace() {
        let task = backgroundTask
        backgroundTask = .invalid
        if task != .invalid { endTask(task) }
    }

    /// The `AIAgentControllers.remove` hook — stops the turn, drops the
    /// session and unsubscribes the reset observer. The app never calls
    /// it: controllers live for the container's lifetime.
    func shutdown() {
        watchTask?.cancel()
        watchTask = nil
        dropSession()
        endBackgroundGrace()
        if let resetObserver {
            notificationCenter.removeObserver(resetObserver)
            self.resetObserver = nil
        }
    }
}

/// One `AIAgentController` per `ModelContainer` so every Agent entry
/// point shares the same conversation without environment plumbing —
/// the same pattern `LedgerBalanceStores` uses for balances.
@MainActor
enum AIAgentControllers {
    private static var controllers: [ObjectIdentifier: AIAgentController] = [:]

    static func shared(for container: ModelContainer) -> AIAgentController {
        let key = ObjectIdentifier(container)
        if let controller = controllers[key] { return controller }
        let controller = AIAgentController(container: container)
        controllers[key] = controller
        return controller
    }

    /// Removes the cached controller for a container — tests use it to
    /// reset.
    static func remove(_ container: ModelContainer) {
        controllers.removeValue(forKey: ObjectIdentifier(container))?
            .shutdown()
    }
}

/// The small accent dot on the three Agent entry points — visible
/// while the shared session is mid-turn or a reply/proposal landed
/// unseen. Accessibility-hidden by construction so the buttons keep
/// their own labels ("Agent") for the UI tests.
struct AgentActivityDot: View {
    @Environment(\.modelContext) private var context

    var body: some View {
        if AIAgentControllers.shared(for: context.container)
            .showsEntryIndicator {
            Circle()
                .fill(Color.accentColor)
                .frame(width: 7, height: 7)
                .accessibilityHidden(true)
        }
    }
}

extension View {
    /// Badges a toolbar icon with the shared Agent activity dot —
    /// offset just outside the glyph; hit-testing stays on the button.
    func agentActivityBadge() -> some View {
        overlay(alignment: .topTrailing) {
            AgentActivityDot()
                .offset(x: 4, y: -4)
                .allowsHitTesting(false)
        }
    }
}
