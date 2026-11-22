import Testing
import SwiftData
import Foundation
import FinanceCore
@testable import AMFinance

/// iOS 17 staleness gate for the balance cache. On iOS 17 SwiftData does
/// not post `ModelContext.didSave` reliably (fixed in iOS 18), and the
/// owner's phone runs 17.6.1 — these tests build stores with
/// `observesSaveNotifications: false` so the ONLY thing that can catch a
/// mutation is the `LedgerFingerprint` check, then prove every real
/// write path ends with the store serving the straightforward walk and
/// no read ever returns the old cached value.
///
/// The fixture works on `container.mainContext` — the context views use —
/// so the fingerprint's pending-changes semantics match the app.
@Suite(.serialized)
@MainActor
struct LedgerBalanceStaleTests {

    private struct Fixture {
        let container: ModelContainer
        /// `container.mainContext` — same context the app's views write on.
        let context: ModelContext
        let store: LedgerBalanceStore
        let bank: Account
        let cash: Account
    }

    /// A small ledger: two accounts plus expense/income/transfer rows,
    /// then a store with notifications disabled (`observing == false`)
    /// and `.zero` throttle so every read re-runs the fingerprint check —
    /// the strictest form of "as soon as refreshIfStale() runs".
    private func makeFixture(observing: Bool = false) throws -> Fixture {
        let container = try AppModelContainer.make(inMemory: true)
        let context = container.mainContext
        let bank = Account(name: "Bank", kind: .bank,
                           openingBalance: 10_000_000, sortOrder: 0)
        let cash = Account(name: "Tiền mặt", kind: .cash,
                           openingBalance: 1_000_000, sortOrder: 1)
        context.insert(bank)
        context.insert(cash)
        context.insert(LedgerTransaction(
            kind: .expense, amount: 300_000, account: bank))
        context.insert(LedgerTransaction(
            kind: .income, amount: 2_000_000, account: bank))
        context.insert(LedgerTransaction(
            kind: .transfer, amount: 500_000, account: bank, toAccount: cash))
        try context.save()
        let store = LedgerBalanceStore(
            container: container, observesSaveNotifications: observing)
        store.fingerprintInterval = .zero
        try store.refresh(context: context)
        return Fixture(container: container, context: context, store: store,
                       bank: bank, cash: cash)
    }

    // MARK: - Detection without any save notification

    /// Insert moves the row count — the fingerprint's simplest signal.
    @Test func insertDetectedWithoutNotifications() throws {
        let fx = try makeFixture()
        let before = fx.store.balance(of: fx.bank)
        fx.context.insert(LedgerTransaction(
            kind: .expense, amount: 999_000, date: .now, account: fx.bank))
        try fx.context.save()
        // The read itself runs the check (interval .zero) — it must
        // already serve the post-save truth, not the old aggregate.
        #expect(fx.store.balance(of: fx.bank) == before - 999_000)
        #expect(fx.store.balance(of: fx.bank) == fx.bank.balance)
        fx.store.refreshIfStale(force: true)
        #expect(fx.store.balance(of: fx.bank) == fx.bank.balance)
    }

    /// Editing `amount` in place: every app edit path stamps `updatedAt`,
    /// and the newest stamp moves the fingerprint.
    @Test func editAmountDetectedWithoutNotifications() throws {
        let fx = try makeFixture()
        let transaction = try #require(
            fx.bank.transactions?.first { $0.kind == .expense })
        let before = fx.store.balance(of: fx.bank)
        transaction.amount = 111_000
        transaction.updatedAt = .now
        try fx.context.save()
        #expect(fx.store.balance(of: fx.bank) == before + 300_000 - 111_000)
        #expect(fx.store.balance(of: fx.bank) == fx.bank.balance)
    }

    /// Deleting a row drops the count — detected without a notification.
    @Test func deleteDetectedWithoutNotifications() throws {
        let fx = try makeFixture()
        let transaction = try #require(
            fx.bank.transactions?.first { $0.kind == .expense })
        let before = fx.store.balance(of: fx.bank)
        fx.context.delete(transaction)
        try fx.context.save()
        #expect(fx.store.balance(of: fx.bank) == before + 300_000)
        #expect(fx.store.balance(of: fx.bank) == fx.bank.balance)
    }

    /// `openingBalance` edits move the account checksum.
    @Test func openingBalanceEditDetectedWithoutNotifications() throws {
        let fx = try makeFixture()
        let before = fx.store.balance(of: fx.cash)
        fx.cash.openingBalance += 777_000
        try fx.context.save()
        #expect(fx.store.balance(of: fx.cash) == before + 777_000)
        #expect(fx.store.balance(of: fx.cash) == fx.cash.balance)
    }

    /// A 200-row import burst — the CSV-importer/sync write pattern.
    @Test func batchImportDetectedWithoutNotifications() throws {
        let fx = try makeFixture()
        for index in 0..<200 {
            let transaction = LedgerTransaction(
                kind: index.isMultiple(of: 2) ? .expense : .income,
                amount: 10_000 * Int64(index + 1),
                date: .now,
                account: fx.bank)
            transaction.needsReview = true
            transaction.externalSource = CSVImportDeduper.externalSource
            transaction.externalID = "stale-test-\(index)"
            fx.context.insert(transaction)
        }
        try fx.context.save()
        #expect(fx.store.balance(of: fx.bank) == fx.bank.balance)
        // Entries fall back to the walk too — the new rows are in it.
        #expect(
            fx.store.creditCardEntries(of: fx.bank)
                .sorted { ($0.date, $0.delta) < ($1.date, $1.delta) }
                == fx.bank.creditCardEntries
                .sorted { ($0.date, $0.delta) < ($1.date, $1.delta) })
        // And the pass reconverges once it runs.
        try fx.store.refresh(context: fx.context)
        #expect(fx.store.aggregate?.balances[fx.bank.id] == fx.bank.balance)
    }

    /// Level-B data reset: wipe every row, reseed — counts and the
    /// account checksum all move.
    @Test func dataResetDetectedWithoutNotifications() throws {
        let fx = try makeFixture()
        try BackupRestorer.deleteAllRows(in: fx.context)
        try SeedData.seedIfNeeded(context: fx.context)
        try fx.context.save()
        fx.store.refreshIfStale(force: true)
        let accounts = try fx.context.fetch(FetchDescriptor<Account>())
        #expect(accounts.count == 1)   // the reseeded "Tiền mặt" only
        for account in accounts {
            #expect(fx.store.balance(of: account) == account.balance)
        }
        // The deleted fixture account must never serve its old balance:
        // stale reads return the walk (opening balance), not the cached
        // pre-reset figure.
        #expect(fx.store.cachedBalance(of: fx.bank.id) == nil)
        try fx.store.refresh(context: fx.context)
        #expect(fx.store.aggregate?.balances.count == 1)
    }

    /// `.replace` restore: wipe + reinsert — every signal moves.
    @Test func replaceRestoreDetectedWithoutNotifications() throws {
        let fx = try makeFixture()
        let expected = Dictionary(
            uniqueKeysWithValues: [fx.bank, fx.cash].map { ($0.id, $0.balance) })
        let data = try BackupCodec.encode(context: fx.context)
        try BackupRestorer.deleteAllRows(in: fx.context)
        try fx.context.save()
        let document = try BackupCodec.decode(data)
        try BackupRestorer.restore(document, mode: .replace, into: fx.context)
        fx.store.refreshIfStale(force: true)
        let restored = try fx.context.fetch(FetchDescriptor<Account>())
        #expect(restored.count == 2)
        for account in restored {
            #expect(fx.store.balance(of: account) == account.balance)
            #expect(fx.store.balance(of: account) == expected[account.id])
        }
    }

    /// `.merge` restore: the winner row is overwritten in place — count
    /// unchanged — but its backup `updatedAt` becomes the table's newest
    /// stamp, and that moves the fingerprint.
    @Test func mergeRestoreDetectedWithoutNotifications() throws {
        let fx = try makeFixture()
        let transaction = try #require(
            fx.bank.transactions?.first { $0.kind == .expense })
        // Make the local row old so the backup copy wins on `updatedAt`.
        transaction.updatedAt = Date(timeIntervalSince1970: 1_000)
        try fx.context.save()
        try fx.store.refresh(context: fx.context)
        let before = fx.store.balance(of: fx.bank)

        var document = try BackupCodec.decode(
            try BackupCodec.encode(context: fx.context))
        let index = try #require(
            document.transactions.firstIndex { $0.id == transaction.id })
        document.transactions[index].amount = 555_000
        document.transactions[index].updatedAt = .now
        try BackupRestorer.restore(document, mode: .merge, into: fx.context)

        fx.store.refreshIfStale(force: true)
        #expect(fx.store.balance(of: fx.bank) == fx.bank.balance)
        #expect(fx.store.balance(of: fx.bank) != before)
    }

    /// An unsaved edit on `mainContext` — the fingerprint sees pending
    /// changes too, so even a never-committed mutation can't let the
    /// cache disagree with the live relationships readers fall back to.
    @Test func pendingEditDetectedWithoutSave() throws {
        let fx = try makeFixture()
        let transaction = try #require(
            fx.bank.transactions?.first { $0.kind == .expense })
        transaction.amount = 1
        transaction.updatedAt = .now
        fx.store.refreshIfStale(force: true)
        #expect(fx.store.balance(of: fx.bank) == fx.bank.balance)
        fx.context.rollback()
        fx.store.refreshIfStale(force: true)
        #expect(fx.store.balance(of: fx.bank) == fx.bank.balance)
    }

    /// After detection, a fresh aggregate lands and cached reads serve
    /// the new truth again — `cachedBalance` returns a value, not nil.
    @Test func reconvergesAfterDetection() throws {
        let fx = try makeFixture()
        fx.context.insert(LedgerTransaction(
            kind: .expense, amount: 42_000, date: .now, account: fx.bank))
        try fx.context.save()
        fx.store.refreshIfStale(force: true)
        // Suspect — `cachedBalance` must refuse the old value entirely.
        #expect(fx.store.cachedBalance(of: fx.bank.id) == nil)
        try fx.store.refresh(context: fx.context)
        #expect(fx.store.cachedBalance(of: fx.bank.id) == fx.bank.balance)
        #expect(fx.store.aggregate?.balances[fx.bank.id] == fx.bank.balance)
    }

    /// The mismatch bumps `changeCount` on the next main-actor turn —
    /// the signal views use to re-pull paged data.
    @Test func changeCountMovesOnFingerprintMismatch() async throws {
        let fx = try makeFixture()
        let count = fx.store.changeCount
        fx.context.insert(LedgerTransaction(
            kind: .expense, amount: 10_000, date: .now, account: fx.bank))
        try fx.context.save()
        fx.store.refreshIfStale(force: true)
        try await Task.sleep(for: .milliseconds(80))
        #expect(fx.store.changeCount > count)
    }

    // MARK: - The notification path still works

    /// With observation enabled and the fingerprint throttled past the
    /// test's horizon, a save still invalidates synchronously — proving
    /// the notification channels (SwiftData or Core Data) fire here.
    @Test func saveInvalidatesViaNotifications() throws {
        let fx = try makeFixture(observing: true)
        fx.store.fingerprintInterval = .seconds(3_600)
        #expect(fx.store.refreshIfStale() == true)   // consume the one check
        let before = fx.store.balance(of: fx.bank)
        fx.context.insert(LedgerTransaction(
            kind: .expense, amount: 500_000, date: .now, account: fx.bank))
        try fx.context.save()
        // Throttled — only a save notification could have invalidated.
        #expect(fx.store.balance(of: fx.bank) == before - 500_000)
        #expect(fx.store.balance(of: fx.bank) == fx.bank.balance)
    }

    /// The throttle: at most one fingerprint read per interval, with
    /// `force: true` always allowed through.
    @Test func refreshIfStaleThrottles() throws {
        let fx = try makeFixture()
        fx.store.fingerprintInterval = .seconds(3_600)
        #expect(fx.store.refreshIfStale() == true)
        #expect(fx.store.refreshIfStale() == false)
        #expect(fx.store.refreshIfStale(force: true) == true)
    }

    /// `saveAndCheck`: an app-side save through a context on the store's
    /// container runs the fingerprint check inline.
    @Test func saveAndCheckInvalidates() throws {
        let fx = try makeFixture()
        let before = fx.store.balance(of: fx.bank)
        fx.context.insert(LedgerTransaction(
            kind: .income, amount: 250_000, date: .now, account: fx.bank))
        try fx.store.saveAndCheck(fx.context)
        #expect(fx.store.balance(of: fx.bank) == before + 250_000)
        #expect(fx.store.balance(of: fx.bank) == fx.bank.balance)
    }
}
