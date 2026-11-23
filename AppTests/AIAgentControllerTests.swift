import Testing
import SwiftData
import Foundation
import UIKit
@testable import AMFinance

/// Tests for `AIAgentController` — the app-level, per-container owner of
/// the shared `AIAgentChatSession`. Verifies the session's lifetime
/// rules: it survives appear/disappear cycles, transient client
/// failures and access/notes flips, and is replaced ONLY on "Cuộc trò
/// chuyện mới", a real destination change or a data reset. Plus the
/// unseen-completion marker and the background-task grace — all through
/// a scripted fake client, no network.
@MainActor
struct AIAgentControllerTests {

    // MARK: - Scaffolding

    /// Scriptable client: one canned answer, an optional artificial
    /// delay so a test can observe the in-flight stretch.
    private final class FakeAIClient: AIChatClientProtocol,
                                    @unchecked Sendable {
        var response = #"{"type":"answer","text":"Được rồi."}"#
        var delayMilliseconds: UInt64 = 0

        func complete(_ request: AIRequest) async throws -> AIResponse {
            if delayMilliseconds > 0 {
                try await Task.sleep(for: .milliseconds(delayMilliseconds))
            }
            return AIResponse(text: response)
        }

        func stream(
            _ request: AIRequest
        ) -> AsyncThrowingStream<String, Error> {
            AsyncThrowingStream { $0.finish() }
        }
    }

    /// Toggleable `clientFactory` stand-in — `makeClient` in the app.
    private final class FactoryGate {
        var shouldThrow = false
        var builtClients = 0
        let client: FakeAIClient
        init(_ client: FakeAIClient) { self.client = client }
    }

    /// Records `beginBackgroundTask`/`endBackgroundTask` calls.
    private final class BackgroundTaskLog {
        var began = 0
        var ended = 0
        var expirationHandlers: [() -> Void] = []
    }

    private struct Fixture {
        var controller: AIAgentController
        var defaults: UserDefaults
        var suiteName: String
        var center: NotificationCenter
        var fake: FakeAIClient
        var store: AIProviderStore
        var keyStore: AIInMemoryAPIKeyStore
        var gate: FactoryGate
        var bg: BackgroundTaskLog
    }

    /// A controller on a throwaway container + suite defaults, wired to
    /// a fake client either injected directly (constant "provider") or
    /// through the `clientFactory` seam (so tests can simulate a real
    /// profile destination and transient `makeClient` failures).
    private func makeFixture(
        injectedClient: Bool = true,
        grant: AIAgentAccess = .scopedRead
    ) throws -> Fixture {
        let suiteName = "AIAgentControllerTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defaults.set(grant.rawValue,
                     forKey: AIAgentController.accessDefaultsKey)
        let container = try AppModelContainer.make(inMemory: true)
        let keyStore = AIInMemoryAPIKeyStore()
        let store = AIProviderStore(defaults: defaults, keyStore: keyStore)
        let center = NotificationCenter()
        let fake = FakeAIClient()
        let gate = FactoryGate(fake)
        let bg = BackgroundTaskLog()
        let controller = AIAgentController(
            container: container,
            providerStore: store,
            client: injectedClient ? fake : nil,
            clientFactory: { _, _ in
                gate.builtClients += 1
                if gate.shouldThrow { throw AIError.notConfigured }
                return gate.client
            },
            defaults: defaults,
            notificationCenter: center,
            beginBackgroundTask: { expiration in
                bg.began += 1
                bg.expirationHandlers.append(expiration)
                return UIBackgroundTaskIdentifier(rawValue: bg.began)
            },
            endBackgroundTask: { _ in
                bg.ended += 1
            })
        return Fixture(
            controller: controller, defaults: defaults,
            suiteName: suiteName, center: center, fake: fake,
            store: store, keyStore: keyStore, gate: gate, bg: bg)
    }

    /// Saves an active profile with a key — the `clientFactory` path
    /// then resolves a real destination.
    @discardableResult
    private func saveProfile(
        in f: Fixture, name: String, model: String
    ) -> AIProviderProfile {
        let profile = AIProviderProfile(
            name: name, baseURL: "https://api.example.com/v1", model: model)
        f.store.save(profile)
        f.keyStore.setKey("k-\(model)", for: profile.id)
        f.store.setActive(profile.id)
        return profile
    }

    private func tearDown(_ f: Fixture) {
        f.controller.shutdown()
        f.defaults.removePersistentDomain(forName: f.suiteName)
    }

    /// Polls a condition — the session task updates state off the call
    /// stack, so assertions wait deterministically.
    private func waitUntil(
        _ condition: @escaping @MainActor () -> Bool
    ) async -> Bool {
        let deadline = ContinuousClock.now + .seconds(10)
        while ContinuousClock.now < deadline {
            if condition() { return true }
            try? await Task.sleep(for: .milliseconds(10))
        }
        return condition()
    }

    // MARK: - Registry

    /// The registry hands out exactly one controller per container —
    /// what makes all three entry points share the conversation.
    @Test func sharedControllerIsOnePerContainer() throws {
        let container = try AppModelContainer.make(inMemory: true)
        defer { AIAgentControllers.remove(container) }
        let other = try AppModelContainer.make(inMemory: true)
        defer { AIAgentControllers.remove(other) }

        #expect(AIAgentControllers.shared(for: container)
            === AIAgentControllers.shared(for: container))
        #expect(AIAgentControllers.shared(for: other)
            !== AIAgentControllers.shared(for: container))
    }

    // MARK: - Lifetime rules

    /// Repeated screen appear/disappear with an identical profile keeps
    /// the same session — the bug this PR fixes.
    @Test func sessionSurvivesAppearDisappearWithIdenticalProfile() throws {
        let f = try makeFixture()
        defer { tearDown(f) }
        f.controller.refreshProvider()
        let first = try #require(f.controller.session)

        for _ in 0..<3 {
            f.controller.noteScreenAppeared()
            f.controller.noteScreenDisappeared()
            f.controller.refreshProvider()
            f.controller.syncSettings()
        }
        #expect(f.controller.session === first)
    }

    /// A transient `makeClient` failure drops the client (the screen
    /// shows "Chưa cấu hình AI") but NOT the conversation.
    @Test func transientClientFailureKeepsConversation() async throws {
        let f = try makeFixture(injectedClient: false)
        defer { tearDown(f) }
        saveProfile(in: f, name: "Test AI", model: "m1")
        f.controller.refreshProvider()
        let first = try #require(f.controller.session)

        #expect(f.controller.send("chào"))
        #expect(await waitUntil { f.controller.session?.messages.count == 2 })

        // The build fails — destination unchanged: session and its
        // messages stay put while the screen reads "Chưa cấu hình AI".
        f.gate.shouldThrow = true
        f.controller.refreshProvider()
        #expect(f.controller.client == nil)
        #expect(f.controller.session === first)
        #expect(f.controller.session?.messages.count == 2)

        // Recovered — still the same conversation on a working client.
        f.gate.shouldThrow = false
        f.controller.refreshProvider()
        #expect(f.controller.client != nil)
        #expect(f.controller.session === first)
        #expect(f.controller.send("lại"))
        #expect(await waitUntil { f.controller.session?.messages.count == 4 })
    }

    /// Grant and notes-switch flips never cost the conversation: the
    /// grant is re-read live per turn; `includeNotes` is copied into the
    /// live session by `syncSettings`.
    @Test func accessAndIncludeNotesChangesKeepMessages() async throws {
        let f = try makeFixture()
        defer { tearDown(f) }
        f.controller.refreshProvider()
        let first = try #require(f.controller.session)

        #expect(f.controller.send("tháng này"))
        #expect(await waitUntil { f.controller.session?.messages.count == 2 })

        // Revoke → re-grant: same session, messages intact.
        f.defaults.set(AIAgentAccess.off.rawValue,
                       forKey: AIAgentController.accessDefaultsKey)
        f.controller.syncSettings()
        #expect(f.controller.access == .off)
        #expect(f.controller.session === first)
        f.defaults.set(AIAgentAccess.scopedRead.rawValue,
                       forKey: AIAgentController.accessDefaultsKey)
        f.controller.syncSettings()
        #expect(f.controller.session === first)
        #expect(f.controller.session?.messages.count == 2)

        // Notes flip — written into the live session, no rebuild.
        #expect(first.includeNotes)
        f.defaults.set(false, forKey: AIAgentController.includeNotesDefaultsKey)
        f.controller.syncSettings()
        #expect(f.controller.session === first)
        #expect(first.includeNotes == false)
        #expect(first.messages.count == 2)
    }

    /// A real destination change — another active profile, or an
    /// in-place edit of the same id — starts a fresh session.
    @Test func destinationChangeStartsFreshSession() async throws {
        let f = try makeFixture(injectedClient: false)
        defer { tearDown(f) }
        saveProfile(in: f, name: "Test AI", model: "m1")
        f.controller.refreshProvider()
        let first = try #require(f.controller.session)
        #expect(f.controller.send("chào"))
        #expect(await waitUntil { f.controller.session?.messages.count == 2 })

        // Switching the active profile resets the conversation.
        saveProfile(in: f, name: "Khác", model: "m2")
        f.controller.refreshProvider()
        let second = try #require(f.controller.session)
        #expect(second !== first)
        #expect(second.messages.isEmpty)

        // An in-place edit of the same profile id counts too.
        saveProfile(in: f, name: "Khác", model: "m3")
        f.controller.refreshProvider()
        let third = try #require(f.controller.session)
        #expect(third !== second)
        #expect(third.messages.isEmpty)
    }

    /// `.dataResetCompleted` drops the conversation — its row handles
    /// point at deleted data — and a fresh session is ensured on the
    /// reseeded store.
    @Test func dataResetStartsFreshSession() async throws {
        let f = try makeFixture()
        defer { tearDown(f) }
        f.controller.refreshProvider()
        let first = try #require(f.controller.session)
        #expect(f.controller.send("đọc sổ"))
        #expect(await waitUntil { f.controller.session?.messages.count == 2 })

        f.center.post(name: .dataResetCompleted, object: nil)
        #expect(await waitUntil {
            f.controller.session != nil && f.controller.session !== first
        })
        #expect(f.controller.session?.messages.isEmpty == true)
    }

    /// "Cuộc trò chuyện mới" — an explicit fresh start.
    @Test func newConversationDropsMessages() async throws {
        let f = try makeFixture()
        defer { tearDown(f) }
        f.controller.refreshProvider()
        let first = try #require(f.controller.session)
        #expect(f.controller.send("ghi lại"))
        #expect(await waitUntil { f.controller.session?.messages.count == 2 })

        f.controller.newConversation()
        let second = try #require(f.controller.session)
        #expect(second !== first)
        #expect(second.messages.isEmpty)
    }

    // MARK: - Unread marker & background grace

    /// A turn finishing with no Agent screen watching marks the
    /// conversation unread; the next screen appearance clears it.
    @Test func turnEndingUnwatchedMarksUnread() async throws {
        let f = try makeFixture()
        defer { tearDown(f) }
        f.controller.refreshProvider()

        #expect(f.controller.send("tổng hợp"))
        #expect(f.controller.session?.isWorking == true)
        #expect(await waitUntil { f.controller.session?.messages.count == 2 })
        #expect(await waitUntil { f.controller.hasUnreadActivity })
        #expect(f.controller.showsEntryIndicator)

        f.controller.noteScreenAppeared()
        #expect(f.controller.hasUnreadActivity == false)
        f.controller.noteScreenDisappeared()
    }

    /// The same turn while a screen IS watching marks nothing.
    @Test func turnEndingWhileVisibleMarksNothing() async throws {
        let f = try makeFixture()
        defer { tearDown(f) }
        f.controller.refreshProvider()
        f.controller.noteScreenAppeared()

        #expect(f.controller.send("tổng hợp"))
        #expect(await waitUntil { f.controller.session?.messages.count == 2 })
        #expect(await waitUntil {
            f.controller.session?.isWorking == false
        })
        // Let the watcher's poll land, then the flag must still be clear.
        try? await Task.sleep(for: .milliseconds(300))
        #expect(f.controller.hasUnreadActivity == false)
        f.controller.noteScreenDisappeared()
    }

    /// The in-flight stretch holds a background task, ended when the
    /// turn ends — and a system expiry ends it too, exactly once.
    @Test func backgroundGraceHeldForTurnThenEnded() async throws {
        let f = try makeFixture()
        defer { tearDown(f) }
        f.controller.refreshProvider()
        f.fake.delayMilliseconds = 400

        #expect(f.controller.send("tổng hợp"))
        #expect(f.bg.began == 1)
        #expect(await waitUntil { f.bg.ended == 1 })

        // Second turn: the system expires the task — the expiration
        // handler ends it the same way.
        #expect(f.controller.send("nữa"))
        #expect(await waitUntil { f.bg.began == 2 })
        f.bg.expirationHandlers[1]()
        #expect(await waitUntil { f.bg.ended == 2 })
    }
}
