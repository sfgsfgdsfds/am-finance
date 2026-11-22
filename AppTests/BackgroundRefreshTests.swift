import Testing
import Foundation
import SwiftData
import FinanceCore
@testable import AMFinance

/// Tests for the background-refresh feature: the pure notification plan
/// (per-transaction vs summary, signs, totals, stable identifiers) and
/// the runner's step isolation + notification gating. All dependencies
/// are fakes — no network, no SwiftData, no real notification center.
@Suite(.serialized)
@MainActor
struct BackgroundRefreshTests {

    // MARK: - Fakes

    private struct FakeError: LocalizedError, Equatable {
        var message: String
        var errorDescription: String? { message }
    }

    private final class FakeSync: BackgroundRefreshSyncing, @unchecked Sendable {
        var result = BackgroundRefreshSyncResult()
        var calls = 0

        func sync(now: Date) async -> BackgroundRefreshSyncResult {
            calls += 1
            return result
        }
    }

    private final class FakeGenerator:
        BackgroundRefreshRecurringGenerating, @unchecked Sendable {
        var created = 0
        var error: (any Error)?
        var calls = 0

        func generateDue(now: Date) throws -> Int {
            calls += 1
            if let error { throw error }
            return created
        }
    }

    private final class FakeReminders:
        BackgroundRefreshReminderScheduling, @unchecked Sendable {
        var planned = 0
        var error: (any Error)?
        var calls = 0

        func reschedule(now: Date) async throws -> Int {
            calls += 1
            if let error { throw error }
            return planned
        }
    }

    private final class FakeCenter:
        BackgroundRefreshNotificationCentering, @unchecked Sendable {
        var status: ReminderAuthorizationStatus = .authorized
        var delivered: [BackgroundRefreshNotificationPlan.Item] = []
        var failOn: Set<String> = []

        func authorizationStatus() async -> ReminderAuthorizationStatus {
            status
        }

        func deliver(
            _ item: BackgroundRefreshNotificationPlan.Item
        ) async throws {
            if failOn.contains(item.identifier) {
                throw FakeError(message: "deliver failed")
            }
            delivered.append(item)
        }
    }

    // MARK: - Scaffolding

    private let baseDate = Date(timeIntervalSince1970: 1_763_900_000)

    private func row(
        _ externalID: String,
        account: String = "VPBank *1234",
        amount: Int64,
        note: String = ""
    ) -> WalletSyncInsertedTransaction {
        WalletSyncInsertedTransaction(
            externalID: externalID, sessionID: "session-1",
            accountName: account, signedAmount: amount,
            date: baseDate, note: note)
    }

    private func makeDefaults() -> UserDefaults {
        UserDefaults(suiteName: "BackgroundRefreshTests.\(UUID().uuidString)")!
    }

    private func makeRunner(
        sync: FakeSync = FakeSync(),
        generator: FakeGenerator = FakeGenerator(),
        reminders: FakeReminders = FakeReminders(),
        center: FakeCenter = FakeCenter(),
        bankTransactions: Bool = true,
        foregrounded: Bool = false
    ) -> BackgroundRefreshRunner {
        let store = ReminderSettingsStore(defaults: makeDefaults())
        store.save(ReminderSettings(bankTransactions: bankTransactions))
        return BackgroundRefreshRunner(
            sync: sync, generator: generator, reminders: reminders,
            settingsStore: store, center: center,
            isForegrounded: { foregrounded })
    }

    // MARK: - Notification plan

    /// One row → one notification: "VPBank *1234: -150.000 ₫" title,
    /// bank note as body.
    @Test func planOneTransactionIsPerRow() {
        let items = BackgroundRefreshNotificationPlan.plan(inserted: [
            row("tx-1", amount: -150_000, note: "GRAB BIKE")
        ])
        #expect(items.count == 1)
        #expect(items[0].identifier == "amfinance.banksync.tx.tx-1")
        #expect(items[0].title == "VPBank *1234: -150.000 ₫")
        #expect(items[0].body == "GRAB BIKE")
    }

    /// Three rows still get one notification each, signs preserved —
    /// income positive, expense negative.
    @Test func planThreeTransactionsIsPerRowWithSigns() {
        let items = BackgroundRefreshNotificationPlan.plan(inserted: [
            row("tx-1", amount: -150_000, note: "chi"),
            row("tx-2", amount: 500_000, note: "thu"),
            row("tx-3", account: "Techcombank *99", amount: -1, note: ""),
        ])
        #expect(items.count == 3)
        #expect(items.map(\.title) == [
            "VPBank *1234: -150.000 ₫",
            "VPBank *1234: 500.000 ₫",
            "Techcombank *99: -1 ₫",
        ])
        #expect(items.map(\.identifier) == [
            "amfinance.banksync.tx.tx-1",
            "amfinance.banksync.tx.tx-2",
            "amfinance.banksync.tx.tx-3",
        ])
    }

    /// More than three rows collapse into one summary with the totals.
    @Test func planManyTransactionsIsOneSummary() {
        // Zero-amount rows count toward the total but not chi/thu.
        let rows = [
            row("tx-1", amount: -1_000_000),
            row("tx-2", amount: -250_000),
            row("tx-3", amount: 3_000_000),
            row("tx-4", amount: 0), row("tx-5", amount: 0),
            row("tx-6", amount: 0), row("tx-7", amount: 0),
        ]
        let items = BackgroundRefreshNotificationPlan.plan(inserted: rows)
        #expect(items.count == 1)
        #expect(items[0].title == "Giao dịch ngân hàng mới")
        #expect(items[0].body ==
            "7 giao dịch mới, tổng chi 1.250.000 ₫, tổng thu 3.000.000 ₫")
        #expect(items[0].identifier.hasPrefix("amfinance.banksync.summary."))
    }

    /// A summary with only expenses mentions chi, not thu.
    @Test func planSummaryOmitsZeroSide() {
        let rows = (1...5).map { row("tx-\($0)", amount: -100_000) }
        let items = BackgroundRefreshNotificationPlan.plan(inserted: rows)
        #expect(items.count == 1)
        #expect(items[0].body == "5 giao dịch mới, tổng chi 500.000 ₫")
    }

    /// The same set produces the same identifiers across runs — a re-run
    /// replaces, never duplicates.
    @Test func planIdentifiersAreStableAcrossRuns() {
        let rows = [
            row("tx-1", amount: -10), row("tx-2", amount: 20),
            row("tx-3", amount: 30), row("tx-4", amount: -40),
        ]
        let first = BackgroundRefreshNotificationPlan.plan(inserted: rows)
        let second = BackgroundRefreshNotificationPlan.plan(inserted: rows)
        #expect(first.map(\.identifier) == second.map(\.identifier))
        // Order of input doesn't matter for the summary id either.
        let shuffled = BackgroundRefreshNotificationPlan.plan(
            inserted: rows.reversed())
        #expect(first.map(\.identifier) == shuffled.map(\.identifier))

        let perRow = BackgroundRefreshNotificationPlan.plan(
            inserted: [rows[0]])
        let perRowAgain = BackgroundRefreshNotificationPlan.plan(
            inserted: [rows[0]])
        #expect(perRow.map(\.identifier) == perRowAgain.map(\.identifier))
    }

    /// Nothing inserted → nothing planned.
    @Test func planZeroRowsIsEmpty() {
        #expect(BackgroundRefreshNotificationPlan.plan(inserted: []).isEmpty)
    }

    // MARK: - Runner: steps + summary

    /// A happy-path run: all three steps run in order, the two new rows
    /// each produce a notification, and the summary reports it all.
    @Test func runCompletesAllStepsAndNotifies() async {
        let sync = FakeSync()
        let rows = [row("tx-1", amount: -150_000, note: "A"),
                    row("tx-2", amount: 40_000, note: "B")]
        sync.result = BackgroundRefreshSyncResult(
            status: .synced, insertedRows: rows)
        let generator = FakeGenerator()
        generator.created = 2
        let reminders = FakeReminders()
        reminders.planned = 4
        let center = FakeCenter()
        let runner = makeRunner(
            sync: sync, generator: generator, reminders: reminders,
            center: center)

        let summary = await runner.run(now: baseDate)

        #expect(summary.sync == .ok)
        #expect(summary.newBankTransactions == 2)
        #expect(summary.recurring == .ok)
        #expect(summary.recurringCreated == 2)
        #expect(summary.reminders == .ok)
        #expect(summary.remindersPlanned == 4)
        #expect(summary.notificationsSent == 2)
        #expect(!summary.cancelled)
        #expect(sync.calls == 1 && generator.calls == 1 && reminders.calls == 1)
        #expect(center.delivered.map(\.identifier) ==
            ["amfinance.banksync.tx.tx-1", "amfinance.banksync.tx.tx-2"])
    }

    /// A failing sync must not stop the generator and the scheduler —
    /// steps are isolated.
    @Test func failingSyncStillRunsOtherSteps() async {
        let sync = FakeSync()
        sync.result = BackgroundRefreshSyncResult(
            status: .failed, errorDescription: "mạng lỗi")
        let generator = FakeGenerator()
        generator.created = 1
        let reminders = FakeReminders()
        reminders.planned = 2
        let runner = makeRunner(
            sync: sync, generator: generator, reminders: reminders)

        let summary = await runner.run()

        #expect(summary.sync == .failed("mạng lỗi"))
        #expect(summary.recurring == .ok && summary.recurringCreated == 1)
        #expect(summary.reminders == .ok && summary.remindersPlanned == 2)
        #expect(generator.calls == 1 && reminders.calls == 1)
        #expect(summary.notificationsSent == 0)
    }

    /// A failed sync can still have committed pages — those rows are new
    /// and still notify.
    @Test func failedSyncStillNotifiesCommittedRows() async {
        let sync = FakeSync()
        sync.result = BackgroundRefreshSyncResult(
            status: .failed,
            insertedRows: [row("tx-9", amount: -10_000)],
            errorDescription: "page 2 failed")
        let center = FakeCenter()
        let runner = makeRunner(sync: sync, center: center)

        let summary = await runner.run()

        #expect(summary.sync == .failed("page 2 failed"))
        #expect(summary.newBankTransactions == 1)
        #expect(summary.notificationsSent == 1)
        #expect(center.delivered[0].identifier == "amfinance.banksync.tx.tx-9")
    }

    /// A failing generator leaves sync and reminders untouched.
    @Test func failingGeneratorIsIsolated() async {
        let sync = FakeSync()
        sync.result = BackgroundRefreshSyncResult(status: .synced)
        let generator = FakeGenerator()
        generator.error = FakeError(message: "save failed")
        let reminders = FakeReminders()
        let runner = makeRunner(
            sync: sync, generator: generator, reminders: reminders)

        let summary = await runner.run()

        #expect(summary.sync == .ok)
        #expect(summary.recurring == .failed("save failed"))
        #expect(summary.reminders == .ok)
        #expect(reminders.calls == 1)
    }

    /// Signed out / nothing linked → sync reports skipped; nothing else
    /// changes behaviour.
    @Test func skippedSyncRunsOtherSteps() async {
        let sync = FakeSync()   // default result is .skipped
        let generator = FakeGenerator()
        let reminders = FakeReminders()
        let center = FakeCenter()
        let runner = makeRunner(
            sync: sync, generator: generator, reminders: reminders,
            center: center)

        let summary = await runner.run()

        #expect(summary.sync == .skipped)
        #expect(generator.calls == 1 && reminders.calls == 1)
        #expect(center.delivered.isEmpty)
        #expect(summary.notificationsSent == 0)
    }

    // MARK: - Runner: notification gating

    /// The "Thông báo giao dịch ngân hàng mới" switch off → silence.
    @Test func switchOffSendsNoNotifications() async {
        let sync = FakeSync()
        sync.result = BackgroundRefreshSyncResult(
            status: .synced, insertedRows: [row("tx-1", amount: -5_000)])
        let center = FakeCenter()
        let runner = makeRunner(
            sync: sync, center: center, bankTransactions: false)

        let summary = await runner.run()

        #expect(summary.newBankTransactions == 1)
        #expect(summary.notificationsSent == 0)
        #expect(center.delivered.isEmpty)
    }

    /// Denied notification permission → silence.
    @Test func deniedPermissionSendsNoNotifications() async {
        let sync = FakeSync()
        sync.result = BackgroundRefreshSyncResult(
            status: .synced, insertedRows: [row("tx-1", amount: -5_000)])
        let center = FakeCenter()
        center.status = .denied
        let runner = makeRunner(sync: sync, center: center)

        let summary = await runner.run()

        #expect(summary.notificationsSent == 0)
        #expect(center.delivered.isEmpty)
    }

    /// Foreground app → no notifications even with rows + permission.
    @Test func foregroundSendsNoNotifications() async {
        let sync = FakeSync()
        sync.result = BackgroundRefreshSyncResult(
            status: .synced, insertedRows: [row("tx-1", amount: -5_000)])
        let center = FakeCenter()
        let runner = makeRunner(
            sync: sync, center: center, foregrounded: true)

        let summary = await runner.run()

        #expect(summary.notificationsSent == 0)
        #expect(center.delivered.isEmpty)
    }

    /// Two runs inserting the same row deliver the same identifier —
    /// the center replaces, so the owner is never notified twice.
    @Test func rerunsDeliverStableIdentifiers() async {
        let sync = FakeSync()
        sync.result = BackgroundRefreshSyncResult(
            status: .synced, insertedRows: [row("tx-1", amount: -5_000)])
        let center = FakeCenter()
        let runner = makeRunner(sync: sync, center: center)

        _ = await runner.run()
        _ = await runner.run()

        #expect(center.delivered.count == 2)
        #expect(center.delivered[0].identifier == center.delivered[1].identifier)
    }

    /// A sync that inserts nothing sends nothing.
    @Test func emptySyncSendsNoNotifications() async {
        let sync = FakeSync()
        sync.result = BackgroundRefreshSyncResult(status: .synced)
        let center = FakeCenter()
        let runner = makeRunner(sync: sync, center: center)

        let summary = await runner.run()

        #expect(summary.sync == .ok)
        #expect(summary.newBankTransactions == 0)
        #expect(summary.notificationsSent == 0)
        #expect(center.delivered.isEmpty)
    }

    /// Many rows → the single summary item is what gets delivered.
    @Test func manyRowsDeliverOneSummary() async {
        let sync = FakeSync()
        let rows = (1...7).map { row("tx-\($0)", amount: -100_000) }
        sync.result = BackgroundRefreshSyncResult(
            status: .synced, insertedRows: rows)
        let center = FakeCenter()
        let runner = makeRunner(sync: sync, center: center)

        let summary = await runner.run()

        #expect(summary.notificationsSent == 1)
        #expect(center.delivered.count == 1)
        #expect(center.delivered[0].body
            == "7 giao dịch mới, tổng chi 700.000 ₫")
    }
}
