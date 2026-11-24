import Testing
import SwiftData
import Foundation
import os
import UIKit
@testable import AMFinance

/// Tests for `AIAgentController` — the app-level, per-container owner of
/// the shared `AIAgentChatSession`. Verifies the session's lifetime
/// rules: it survives appear/disappear cycles, transient client
/// failures and access/notes flips; a real destination change rebuilds
/// the session on the new client but keeps the conversation, while
/// "Cuộc trò chuyện mới", history opens/deletes and data resets are
/// the explicit conversation-switch points. Plus the history
/// auto-save/restore through a temp-directory
/// `AIAgentConversationStore`, the unseen-completion marker and the
/// background-task grace — all through a scripted fake client, no
/// network.
@MainActor
struct AIAgentControllerTests {

    // MARK: - Scaffolding

    /// Scriptable client: one canned answer, an optional artificial
    /// delay so a test can observe the in-flight stretch. Every
    /// request is recorded so a test can assert what the model saw.
    private final class FakeAIClient: AIChatClientProtocol,
                                    @unchecked Sendable {
        var response = #"{"type":"answer","text":"Được rồi."}"#
        var delayMilliseconds: UInt64 = 0
        private let recorded = OSAllocatedUnfairLock<[AIRequest]>(
            initialState: [])

        var requests: [AIRequest] { recorded.withLock { $0 } }

        func complete(_ request: AIRequest) async throws -> AIResponse {
            recorded.withLock { $0.append(request) }
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
    /// `client` is swappable so a destination change can be proven to
    /// run on the NEW build.
    private final class FactoryGate {
        var shouldThrow = false
        var builtClients = 0
        var client: FakeAIClient
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
        var conversationStore: AIAgentConversationStore
        var conversationDirectory: URL
    }

    /// A controller on a throwaway container + suite defaults, wired to
    /// a fake client either injected directly (constant "provider") or
    /// through the `clientFactory` seam (so tests can simulate a real
    /// profile destination and transient `makeClient` failures). The
    /// conversation store writes into a fresh temp directory.
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
        let conversationDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent(
                "AIAgentControllerTests-\(UUID().uuidString)",
                isDirectory: true)
        let conversationStore = AIAgentConversationStore(
            directory: conversationDirectory)
        let controller = AIAgentController(
            container: container,
            providerStore: store,
            client: injectedClient ? fake : nil,
            clientFactory: { _, _ in
                gate.builtClients += 1
                if gate.shouldThrow { throw AIError.notConfigured }
                return gate.client
            },
            conversationStore: conversationStore,
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
            store: store, keyStore: keyStore, gate: gate, bg: bg,
            conversationStore: conversationStore,
            conversationDirectory: conversationDirectory)
    }

    /// A second controller over the SAME conversation store — the
    /// "relaunch" that must reopen the latest conversation.
    private func makePeerController(
        in f: Fixture
    ) throws -> AIAgentController {
        AIAgentController(
            container: try AppModelContainer.make(inMemory: true),
            providerStore: f.store,
            client: f.fake,
            clientFactory: { _, _ in f.gate.client },
            conversationStore: f.conversationStore,
            defaults: f.defaults,
            notificationCenter: f.center,
            beginBackgroundTask: { _ in .invalid },
            endBackgroundTask: { _ in })
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
        try? FileManager.default.removeItem(at: f.conversationDirectory)
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
    /// in-place edit of the same id — rebuilds the session on the NEW
    /// client but keeps the conversation: same record id, same
    /// messages, the earlier turns still ride the next request.
    @Test func destinationChangeKeepsConversation() async throws {
        let f = try makeFixture(injectedClient: false)
        defer { tearDown(f) }
        saveProfile(in: f, name: "Test AI", model: "m1")
        f.controller.refreshProvider()
        let first = try #require(f.controller.session)
        let conversationID = f.controller.currentConversationID
        #expect(f.controller.send("chào"))
        #expect(await waitUntil { f.controller.session?.messages.count == 2 })
        let before = first.messages

        // Switching the active profile rebuilds the session on the
        // new client — same conversation, same record id.
        let newClient = FakeAIClient()
        f.gate.client = newClient
        saveProfile(in: f, name: "Khác", model: "m2")
        f.controller.refreshProvider()
        let second = try #require(f.controller.session)
        #expect(second !== first)
        #expect(second.messages == before)
        #expect(f.controller.currentConversationID == conversationID)
        #expect(f.controller.client as? FakeAIClient === newClient)

        // The rebuilt session really runs on the new client — the
        // request carries the earlier turns.
        #expect(f.controller.send("lại"))
        #expect(await waitUntil { newClient.requests.count == 1 })
        let request = try #require(newClient.requests.first)
        #expect(request.messages.contains { $0.text == "chào" })

        // An in-place edit of the same profile id counts too — the
        // conversation still survives under the same record id.
        let thirdClient = FakeAIClient()
        f.gate.client = thirdClient
        saveProfile(in: f, name: "Khác", model: "m3")
        f.controller.refreshProvider()
        let third = try #require(f.controller.session)
        #expect(third !== second)
        #expect(third.messages == second.messages)
        #expect(f.controller.currentConversationID == conversationID)
        #expect(f.controller.client as? FakeAIClient === thirdClient)
    }

    /// `.dataResetCompleted` drops the conversation — its row handles
    /// point at deleted data — and a fresh session is ensured on the
    /// reseeded store. The saved history is gone too.
    @Test func dataResetStartsFreshSession() async throws {
        let f = try makeFixture()
        defer { tearDown(f) }
        f.controller.refreshProvider()
        let first = try #require(f.controller.session)
        #expect(f.controller.send("đọc sổ"))
        #expect(await waitUntil { f.controller.session?.messages.count == 2 })
        #expect(await waitUntil { f.conversationStore.list().count == 1 })

        f.center.post(name: .dataResetCompleted, object: nil)
        #expect(await waitUntil {
            f.controller.session != nil && f.controller.session !== first
        })
        #expect(f.controller.session?.messages.isEmpty == true)
        #expect(f.conversationStore.list().isEmpty)
        #expect(f.controller.conversations.isEmpty)
    }

    /// "Cuộc trò chuyện mới" — an explicit fresh start; the outgoing
    /// conversation stays saved in history under its old id.
    @Test func newConversationDropsMessages() async throws {
        let f = try makeFixture()
        defer { tearDown(f) }
        f.controller.refreshProvider()
        let first = try #require(f.controller.session)
        let oldID = f.controller.currentConversationID
        #expect(f.controller.send("ghi lại"))
        #expect(await waitUntil { f.controller.session?.messages.count == 2 })
        #expect(await waitUntil { f.conversationStore.list().count == 1 })

        f.controller.newConversation()
        let second = try #require(f.controller.session)
        #expect(second !== first)
        #expect(second.messages.isEmpty)
        #expect(f.controller.currentConversationID != oldID)
        // The old conversation was auto-saved and remains listed.
        #expect(f.controller.conversations.map(\.id) == [oldID])
        #expect(f.conversationStore.load(id: oldID)?
            .state.messages.count == 2)
    }

    // MARK: - History & auto-save

    /// A finished turn lands on disk: the record keeps the tracked
    /// conversation id, titles itself from the first user message and
    /// refreshes `conversations`.
    @Test func turnEndAutoSavesConversation() async throws {
        let f = try makeFixture()
        defer { tearDown(f) }
        f.controller.refreshProvider()
        let id = f.controller.currentConversationID

        #expect(f.controller.send("chi bao nhiêu tháng này?"))
        #expect(await waitUntil { f.conversationStore.list().count == 1 })

        let record = try #require(f.conversationStore.load(id: id))
        #expect(record.id == id)
        #expect(record.title == "chi bao nhiêu tháng này?")
        #expect(record.messageCount == 2)
        #expect(f.controller.conversations == [record.summary])
    }

    /// Nothing is saved before the user actually says something — an
    /// unused or blank-sent session leaves no file.
    @Test func nothingSavedWithoutUserMessage() async throws {
        let f = try makeFixture()
        defer { tearDown(f) }
        f.controller.refreshProvider()
        #expect(f.controller.session != nil)
        #expect(f.controller.send("   ") == false)
        // Let any (unexpected) save land before asserting.
        try? await Task.sleep(for: .milliseconds(200))
        #expect(f.conversationStore.list().isEmpty)
        #expect(f.controller.conversations.isEmpty)
    }

    /// The first session a launch creates reopens the most recently
    /// updated conversation — the "relaunch" controller over the same
    /// store comes back exactly where the user left off.
    @Test func firstSessionRestoresLatestConversation() async throws {
        let f = try makeFixture()
        defer { tearDown(f) }
        f.controller.refreshProvider()
        #expect(f.controller.send("câu hỏi đầu tiên"))
        #expect(await waitUntil { f.controller.session?.messages.count == 2 })
        #expect(await waitUntil { f.conversationStore.list().count == 1 })
        let oldID = f.controller.currentConversationID

        let peer = try makePeerController(in: f)
        defer { peer.shutdown() }
        peer.refreshProvider()
        let restored = try #require(peer.session)
        #expect(restored.messages == f.controller.session?.messages)
        #expect(peer.currentConversationID == oldID)
    }

    /// "Cuộc trò chuyện mới" keeps the old record in the list — and
    /// the next turn in the fresh session writes a second one.
    @Test func newConversationKeepsOldInList() async throws {
        let f = try makeFixture()
        defer { tearDown(f) }
        f.controller.refreshProvider()
        let firstID = f.controller.currentConversationID
        #expect(f.controller.send("đợt một"))
        #expect(await waitUntil { f.controller.session?.messages.count == 2 })
        #expect(await waitUntil { f.conversationStore.list().count == 1 })

        f.controller.newConversation()
        #expect(f.controller.send("đợt hai"))
        #expect(await waitUntil { f.controller.session?.messages.count == 2 })
        #expect(await waitUntil { f.conversationStore.list().count == 2 })

        let ids = Set(f.controller.conversations.map(\.id))
        #expect(ids.contains(firstID))
        #expect(ids.contains(f.controller.currentConversationID))
        #expect(f.conversationStore.load(id: firstID)?
            .state.messages.first?.text == "đợt một")
    }

    /// "Lịch sử" → open: messages come back exactly as saved, and the
    /// next request carries the earlier turns plus the restore note —
    /// the model sees the whole conversation again.
    @Test func openConversationRestoresAndCarriesTurns() async throws {
        let f = try makeFixture()
        defer { tearDown(f) }
        f.controller.refreshProvider()
        let firstID = f.controller.currentConversationID
        #expect(f.controller.send("câu hỏi cũ"))
        #expect(await waitUntil { f.controller.session?.messages.count == 2 })
        #expect(await waitUntil { f.conversationStore.list().count == 1 })
        let oldMessages = f.controller.session!.messages

        f.controller.newConversation()
        #expect(f.controller.send("câu hỏi mới"))
        #expect(await waitUntil { f.controller.session?.messages.count == 2 })

        f.controller.openConversation(firstID)
        let reopened = try #require(f.controller.session)
        #expect(f.controller.currentConversationID == firstID)
        #expect(reopened.messages == oldMessages)
        #expect(reopened.pendingProposal == nil)

        let sentBefore = f.fake.requests.count
        #expect(f.controller.send("tiếp tục nhé"))
        #expect(await waitUntil { f.fake.requests.count > sentBefore })
        let request = try #require(f.fake.requests.last)
        #expect(request.messages.contains { $0.text == "câu hỏi cũ" })
        #expect(request.messages.contains {
            $0.text == AIAgentChatSession.restoredTranscriptNote })
        #expect(request.messages.last?.text == "tiếp tục nhé")
    }

    /// An unknown id never replaces the current conversation — the
    /// notice is set and the session is untouched.
    @Test func openUnknownConversationShowsNotice() async throws {
        let f = try makeFixture()
        defer { tearDown(f) }
        f.controller.refreshProvider()
        let first = try #require(f.controller.session)
        #expect(f.controller.send("đang nói"))
        #expect(await waitUntil { f.controller.session?.messages.count == 2 })

        f.controller.openConversation(UUID())
        #expect(f.controller.providerNotice != nil)
        #expect(f.controller.session === first)
        #expect(f.controller.session?.messages.count == 2)
    }

    /// Deleting the live conversation drops its record and starts a
    /// fresh, empty conversation under a new id.
    @Test func deletingCurrentConversationStartsFresh() async throws {
        let f = try makeFixture()
        defer { tearDown(f) }
        f.controller.refreshProvider()
        let first = try #require(f.controller.session)
        let oldID = f.controller.currentConversationID
        #expect(f.controller.send("sắp bị xoá"))
        #expect(await waitUntil { f.controller.session?.messages.count == 2 })
        #expect(await waitUntil { f.conversationStore.list().count == 1 })

        f.controller.deleteConversation(oldID)
        let second = try #require(f.controller.session)
        #expect(second !== first)
        #expect(second.messages.isEmpty)
        #expect(f.controller.currentConversationID != oldID)
        #expect(f.conversationStore.list().isEmpty)
        #expect(f.controller.conversations.isEmpty)
    }

    /// Deleting a NON-current row leaves the live session saving
    /// normally — the next turn end still lands on disk.
    @Test func deletingOtherConversationKeepsLiveSession() async throws {
        let f = try makeFixture()
        defer { tearDown(f) }
        f.controller.refreshProvider()
        let firstID = f.controller.currentConversationID
        #expect(f.controller.send("đợt một"))
        #expect(await waitUntil { f.controller.session?.messages.count == 2 })
        #expect(await waitUntil { f.conversationStore.list().count == 1 })

        f.controller.newConversation()
        let second = try #require(f.controller.session)
        f.controller.deleteConversation(firstID)
        #expect(f.controller.session === second)
        #expect(f.controller.conversations.isEmpty)

        // The live session's next save still works.
        #expect(f.controller.send("đợt hai"))
        #expect(await waitUntil { f.conversationStore.list().count == 1 })
        #expect(f.conversationStore.list().first?.id
            == f.controller.currentConversationID)
    }

    /// "Xoá tất cả" wipes every record and starts a fresh conversation.
    @Test func deleteAllConversationsWipesAndStartsFresh() async throws {
        let f = try makeFixture()
        defer { tearDown(f) }
        f.controller.refreshProvider()
        let oldID = f.controller.currentConversationID
        #expect(f.controller.send("một"))
        #expect(await waitUntil { f.conversationStore.list().count == 1 })

        f.controller.newConversation()
        #expect(f.controller.send("hai"))
        #expect(await waitUntil { f.conversationStore.list().count == 2 })

        f.controller.deleteAllConversations()
        #expect(f.conversationStore.list().isEmpty)
        #expect(f.controller.conversations.isEmpty)
        #expect(f.controller.session?.messages.isEmpty == true)
        #expect(f.controller.currentConversationID != oldID)
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
