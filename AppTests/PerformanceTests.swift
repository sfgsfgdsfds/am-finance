import Testing
import SwiftData
import Foundation
import FinanceCore
@testable import AMFinance

/// Timing helpers shared by the gate-scale suite and the 30k benchmark.
/// Every metric prints `PERF | <operation> | <ms>` so a run's output can be
/// pasted into the report table; the two columns the report uses are
/// `*.before` (old code path) and `*.after` (new code path) measurements.
enum PerfClock {
    private static func milliseconds(_ duration: Duration) -> Double {
        let components = duration.components
        return Double(components.seconds) * 1_000
            + Double(components.attoseconds) / 1e15
    }

    @discardableResult
    static func ms(_ name: String, _ body: () throws -> Void) -> Double {
        let start = ContinuousClock.now
        do { try body() } catch { Issue.record("\(name) threw \(error)") }
        let ms = milliseconds(ContinuousClock.now - start)
        print("PERF | \(name) | \(String(format: "%.1f", ms)) ms")
        return ms
    }

    @discardableResult
    static func msAsync(
        _ name: String,
        _ body: () async throws -> Void
    ) async -> Double {
        let start = ContinuousClock.now
        do { try await body() } catch { Issue.record("\(name) threw \(error)") }
        let ms = milliseconds(ContinuousClock.now - start)
        print("PERF | \(name) | \(String(format: "%.1f", ms)) ms")
        return ms
    }
}

/// Shared measurement entry points used at both dataset scales.
@MainActor
enum PerfOps {

    /// Old: `account.balance` walks both relationship arrays per read on a
    /// cold context. New: one single-pass aggregate, then dictionary hits.
    static func balances(
        _ ds: PerformanceSeeder.Dataset, tag: String
    ) throws {
        let cold = ModelContext(ds.container)
        let coldAccounts = try cold.fetch(
            FetchDescriptor<Account>(
                sortBy: [SortDescriptor(\.sortOrder)]))
        PerfClock.ms("\(tag).balance.walk.before") {
            _ = coldAccounts.map(\.balance)
        }
        // Warm read — what a second body evaluation cost before.
        PerfClock.ms("\(tag).balance.walk.warm.before") {
            _ = coldAccounts.map(\.balance)
        }

        let store = LedgerBalanceStores.shared(for: ds.container)
        PerfClock.ms("\(tag).balance.refresh") {
            try! store.refresh(context: ds.context)
        }
        PerfClock.ms("\(tag).balance.cached.after") {
            _ = ds.accounts.map { store.balance(of: $0) }
        }
        for account in ds.accounts {
            #expect(store.balance(of: account) == account.balance)
        }
    }

    /// Old: card / receivable / loan detail inputs walk relationships.
    static func accountDetailInputs(
        _ ds: PerformanceSeeder.Dataset, tag: String
    ) throws {
        let store = LedgerBalanceStores.shared(for: ds.container)
        try store.refresh(context: ds.context)

        var oldEntries: [CreditCardEntry] = []
        PerfClock.ms("\(tag).cardEntries.before") {
            oldEntries = ds.card.creditCardEntries
        }
        var newEntries: [CreditCardEntry] = []
        PerfClock.ms("\(tag).cardEntries.after") {
            newEntries = store.creditCardEntries(of: ds.card)
        }
        // Same multiset — the old relationship order is unspecified and
        // every consumer (CreditCardCycle) reduces over the entries.
        #expect(
            newEntries.sorted { ($0.date, $0.delta) < ($1.date, $1.delta) }
                == oldEntries.sorted {
                    ($0.date, $0.delta) < ($1.date, $1.delta) })

        var oldSnapshot: ReceivableSnapshot?
        PerfClock.ms("\(tag).receivable.before") {
            oldSnapshot = ReceivableSnapshot.make(account: ds.receivable)
        }
        var newSnapshot: ReceivableSnapshot?
        PerfClock.ms("\(tag).receivable.after") {
            newSnapshot = store.receivableSnapshot(of: ds.receivable)
        }
        #expect(newSnapshot == oldSnapshot)

        var oldItems: [DebtsUpcomingItem] = []
        PerfClock.ms("\(tag).debtsUpcoming.before") {
            oldItems = DebtsUpcomingMapper.items(for: ds.accounts, now: .now)
        }
        var newItems: [DebtsUpcomingItem] = []
        PerfClock.ms("\(tag).debtsUpcoming.after") {
            newItems = DebtsUpcomingMapper.items(
                for: ds.accounts, now: .now,
                balanceOf: { store.balance(of: $0) },
                cardEntriesOf: { store.creditCardEntries(of: $0) })
        }
        #expect(newItems == oldItems)
    }

    /// Old: `NetWorth`/`AccountGrouping` re-walk relationships per account.
    static func netWorthAndGrouping(
        _ ds: PerformanceSeeder.Dataset, tag: String
    ) throws {
        let store = LedgerBalanceStores.shared(for: ds.container)
        try store.refresh(context: ds.context)

        var oldTotal: Int64 = 0
        PerfClock.ms("\(tag).netWorth.before") {
            oldTotal = NetWorth.total(ds.accounts)
        }
        var newTotal: Int64 = 0
        PerfClock.ms("\(tag).netWorth.after") {
            newTotal = NetWorth.total(ds.accounts) { store.balance(of: $0) }
        }
        #expect(newTotal == oldTotal)

        var oldSections: [AccountSection] = []
        PerfClock.ms("\(tag).grouping.before") {
            oldSections = AccountGrouping.sections(from: ds.accounts)
        }
        var newSections: [AccountSection] = []
        PerfClock.ms("\(tag).grouping.after") {
            newSections = AccountGrouping.sections(
                from: ds.accounts) { store.balance(of: $0) }
        }
        #expect(newSections == oldSections)
    }

    /// Dashboard: the six-month window fetch + entry mapping + snapshot.
    static func dashboard(
        _ ds: PerformanceSeeder.Dataset, tag: String
    ) throws {
        let calendar = AppCalendar.vietnam
        let interval = ReportSummary.monthInterval(containing: .now, calendar: calendar)
        let start = calendar.date(byAdding: .month, value: -5, to: interval.start)!

        func entries(prefetch: Bool) throws -> [ReportEntry] {
            let context = ModelContext(ds.container)
            var descriptor = FetchDescriptor<LedgerTransaction>(
                predicate: #Predicate { $0.date >= start },
                sortBy: [SortDescriptor(\LedgerTransaction.date, order: .reverse)]
            )
            if prefetch {
                descriptor.relationshipKeyPathsForPrefetching =
                    [\.account, \.toAccount, \.category, \.business]
            }
            return try context.fetch(descriptor).map {
                ReportEntry(
                    date: $0.date, kind: $0.kind, amount: $0.amount,
                    categoryID: $0.category?.id, businessID: $0.business?.id)
            }
        }

        var plain: [ReportEntry] = []
        PerfClock.ms("\(tag).dashboard.entries.before") {
            plain = try! entries(prefetch: false)
        }
        var prefetched: [ReportEntry] = []
        PerfClock.ms("\(tag).dashboard.entries.after") {
            prefetched = try! entries(prefetch: true)
        }
        #expect(prefetched == plain)

        PerfClock.ms("\(tag).dashboard.snapshot") {
            _ = DashboardSnapshot.make(
                entries: plain,
                accounts: ds.accounts.map {
                    .init(id: $0.id, name: $0.name,
                          isLiability: $0.kind.isLiability,
                          icon: $0.icon, colorHex: $0.colorHex,
                          balance: $0.balance,
                          isArchived: $0.isArchived,
                          sortOrder: $0.sortOrder)
                },
                pendingReviewCount: ds.reviewCount,
                hasAnyTransaction: true,
                now: .now, calendar: calendar)
        }
    }

    /// The all-months search path: fetch every row, build list rows, match
    /// a query. Old: normalize() per row per field per keystroke. New: one
    /// folded search blob per row (indexed once per data change) and one
    /// normalized query object.
    static func transactionSearch(
        _ ds: PerformanceSeeder.Dataset, tag: String
    ) throws {
        let cold = ModelContext(ds.container)
        var descriptor = FetchDescriptor<LedgerTransaction>(
            sortBy: [SortDescriptor(\LedgerTransaction.date, order: .reverse)]
        )
        descriptor.relationshipKeyPathsForPrefetching =
            [\.account, \.toAccount, \.category, \.business]
        var all: [LedgerTransaction] = []
        PerfClock.ms("\(tag).search.fetchAll") {
            all = try! cold.fetch(descriptor)
        }
        var rows: [TransactionListRow] = []
        PerfClock.ms("\(tag).search.rows") {
            rows = all.map { TransactionListRow(transaction: $0) }
        }

        let query = "an trua"
        var oldMatches: [TransactionListRow] = []
        PerfClock.ms("\(tag).search.keystroke.before") {
            oldMatches = rows.filter {
                TransactionListSearch.matches($0, query: query)
            }
        }

        var index: [UUID: [String]] = [:]
        PerfClock.ms("\(tag).search.indexBuild") {
            index = Dictionary(
                uniqueKeysWithValues: rows.map {
                    ($0.id, TransactionListSearch.searchableFields(for: $0))
                })
        }
        let normalized = TransactionListSearch.normalizedQuery(query)
        var newMatches: [TransactionListRow] = []
        PerfClock.ms("\(tag).search.keystroke.after") {
            newMatches = rows.filter {
                TransactionListSearch.matches(
                    $0, query: normalized, searchable: index[$0.id])
            }
        }
        #expect(newMatches == oldMatches)
    }

    /// The inbox's old per-row suggestion scan vs. one pass per direction.
    static func inboxSuggestions(
        _ ds: PerformanceSeeder.Dataset, tag: String
    ) throws {
        let context = ModelContext(ds.container)
        let pending = try context.fetch(FetchDescriptor<LedgerTransaction>(
            predicate: #Predicate { $0.needsReview == true },
            sortBy: [SortDescriptor(\LedgerTransaction.date, order: .reverse)]))
        let cutoff = AppCalendar.vietnam.date(
            byAdding: .day, value: -WalletSyncSuggestions.windowDays, to: .now)!
        let recent = try context.fetch(FetchDescriptor<LedgerTransaction>(
            predicate: #Predicate { $0.date >= cutoff }))

        var oldResult: [[UUID]] = []
        PerfClock.ms("\(tag).inbox.suggestions.before") {
            oldResult = pending.map { transaction in
                let kind: CategoryKind = transaction.kind == .income ? .income : .expense
                return WalletSyncSuggestions.top(
                    kind: kind, transactions: recent,
                    categories: ds.categories, now: .now
                ).map(\.id)
            }
        }
        var income: [UUID] = []
        var expense: [UUID] = []
        PerfClock.ms("\(tag).inbox.suggestions.after") {
            income = WalletSyncSuggestions.top(
                kind: .income, transactions: recent,
                categories: ds.categories, now: .now).map(\.id)
            expense = WalletSyncSuggestions.top(
                kind: .expense, transactions: recent,
                categories: ds.categories, now: .now).map(\.id)
        }
        for (index, transaction) in pending.enumerated() {
            let expected = transaction.kind == .income ? income : expense
            #expect(oldResult[index] == expected)
        }
    }

    /// Rule matching per imported row: old re-folds the note for every
    /// rule; new folds it once against pre-folded keywords.
    static func ruleMatching(
        _ ds: PerformanceSeeder.Dataset, tag: String
    ) throws {
        let context = ModelContext(ds.container)
        let pending = try context.fetch(FetchDescriptor<LedgerTransaction>(
            predicate: #Predicate { $0.needsReview == true }))
        let categoryIDs = ds.categories.filter { $0.kind == .expense }
        let rules = categoryIDs.enumerated().map { index, category in
            WalletSyncRule(
                keyword: "ghi chu \(index)",
                direction: .any,
                action: .category(category.id))
        } + [
            WalletSyncRule(keyword: "Grab", direction: .moneyOut,
                           action: .category(categoryIDs[0].id)),
            WalletSyncRule(keyword: "luong", direction: .moneyIn,
                           action: .category(categoryIDs[0].id)),
        ]
        let categories = Dictionary(
            uniqueKeysWithValues: ds.categories.map { ($0.id, $0) })
        let businesses = Dictionary(
            uniqueKeysWithValues: ds.businesses.map { ($0.id, $0) })
        let accounts = Dictionary(
            uniqueKeysWithValues: ds.accounts.map { ($0.id, $0) })

        var oldApplied = 0
        PerfClock.ms("\(tag).rules.apply.before") {
            for transaction in pending {
                if WalletSyncRuleApplier.apply(
                    to: transaction, rules: rules,
                    categories: categories, businesses: businesses,
                    accounts: accounts) != nil { oldApplied += 1 }
            }
        }
        let compiled = WalletSyncCompiledRules(rules: rules)
        var newApplied = 0
        PerfClock.ms("\(tag).rules.apply.after") {
            for transaction in pending {
                if compiled.apply(
                    to: transaction, categories: categories,
                    businesses: businesses, accounts: accounts) != nil { newApplied += 1 }
            }
        }
        #expect(newApplied == oldApplied)
    }

    /// Reports tab: the windowed fetch plus the aggregations the screen
    /// maps into `ReportsSnapshot`.
    static func reports(
        _ ds: PerformanceSeeder.Dataset, tag: String
    ) throws {
        let calendar = AppCalendar.vietnam
        let interval = ReportSummary.monthInterval(containing: .now, calendar: calendar)
        let start = calendar.date(byAdding: .month, value: -2, to: interval.start)!
        // `#Predicate` cannot key-path into a captured struct — hoist `end`.
        let end = interval.end
        let context = ModelContext(ds.container)
        var entries: [ReportEntry] = []
        PerfClock.ms("\(tag).reports.fetch") {
            var descriptor = FetchDescriptor<LedgerTransaction>(
                predicate: #Predicate { $0.date >= start && $0.date < end },
                sortBy: [SortDescriptor(\LedgerTransaction.date)]
            )
            descriptor.relationshipKeyPathsForPrefetching = [\.category, \.business]
            entries = try! context.fetch(descriptor).map {
                ReportEntry(
                    date: $0.date, kind: $0.kind, amount: $0.amount,
                    categoryID: $0.category?.id, businessID: $0.business?.id)
            }
        }
        PerfClock.ms("\(tag).reports.aggregate") {
            _ = ReportSummary.totals(entries: entries, in: interval)
            _ = ReportSummary.monthly(
                entries: entries, months: 3, endingAt: .now, calendar: calendar)
            _ = ReportSummary.byCategory(
                entries: entries, in: interval, kind: .expense)
            _ = ReportSummary.byBusiness(entries: entries, in: interval)
        }
    }
}

/// The gate-scale performance suite: a ~4k-transaction dataset keeps the
/// default `test-app.sh` run fast while still catching regressions. The
/// printed PERF lines are the "after" numbers for the report; the same
/// tests measured the old paths as `*.before`.
@Suite(.serialized)
@MainActor
struct PerformanceTests {
    private static var shared: PerformanceSeeder.Dataset?

    private func dataset() throws -> PerformanceSeeder.Dataset {
        if let shared = Self.shared { return shared }
        let seeded = try PerformanceSeeder.seed(
            transactionCount: 4_000, reviewCount: 300)
        Self.shared = seeded
        return seeded
    }

    @Test func balanceReads() throws {
        try PerfOps.balances(dataset(), tag: "guard")
    }

    @Test func accountDetailInputs() throws {
        try PerfOps.accountDetailInputs(dataset(), tag: "guard")
    }

    @Test func netWorthAndGrouping() throws {
        try PerfOps.netWorthAndGrouping(dataset(), tag: "guard")
    }

    @Test func dashboard() throws {
        try PerfOps.dashboard(dataset(), tag: "guard")
    }

    @Test func transactionSearch() throws {
        try PerfOps.transactionSearch(dataset(), tag: "guard")
    }

    @Test func inboxSuggestions() throws {
        try PerfOps.inboxSuggestions(dataset(), tag: "guard")
    }

    @Test func ruleMatching() throws {
        try PerfOps.ruleMatching(dataset(), tag: "guard")
    }

    @Test func reports() throws {
        try PerfOps.reports(dataset(), tag: "guard")
    }

    // MARK: - Regression guards (generous thresholds)

    /// Cached balance lookups must stay microseconds-fast on a large
    /// ledger — the whole point of the store.
    @Test func cachedBalanceLookupIsInstant() throws {
        let ds = try dataset()
        let store = LedgerBalanceStores.shared(for: ds.container)
        try store.refresh(context: ds.context)
        let ms = PerfClock.ms("guard.balance.cached.assert") {
            for _ in 0..<50 {
                _ = ds.accounts.map { store.balance(of: $0) }
            }
        }
        #expect(ms < 50)
    }

    /// One aggregate pass over the guard dataset stays well under a
    /// second — it runs off the main actor in the app.
    @Test func aggregatePassIsBounded() throws {
        let ds = try dataset()
        let store = LedgerBalanceStores.shared(for: ds.container)
        let ms = PerfClock.ms("guard.balance.refresh.assert") {
            try! store.refresh(context: ds.context)
        }
        #expect(ms < 2_000)
    }

    /// A single search pass over every row of the guard dataset.
    @Test func searchPassIsBounded() throws {
        let ds = try dataset()
        let cold = ModelContext(ds.container)
        var descriptor = FetchDescriptor<LedgerTransaction>(
            sortBy: [SortDescriptor(\LedgerTransaction.date, order: .reverse)]
        )
        descriptor.relationshipKeyPathsForPrefetching =
            [\.account, \.toAccount, \.category, \.business]
        let all = try cold.fetch(descriptor)
        let rows = all.map { TransactionListRow(transaction: $0) }
        let index = Dictionary(
            uniqueKeysWithValues: rows.map {
                ($0.id, TransactionListSearch.searchableFields(for: $0))
            })
        let query = TransactionListSearch.normalizedQuery("an")
        let ms = PerfClock.ms("guard.search.keystroke.assert") {
            _ = rows.filter {
                TransactionListSearch.matches(
                    $0, query: query, searchable: index[$0.id])
            }
        }
        #expect(ms < 250)
    }
}

/// The full-scale benchmark: the VPBank-import profile (~30k transactions,
/// 3 years, 6 accounts, 25 categories, 3 businesses, 2,000 pending rows).
///
/// Disabled by default so `test-app.sh` stays a fast gate. To run it,
/// drop a marker file into the test host app's sandbox tmp, then run the
/// benchmark suite directly:
///   APP=$(xcrun simctl get_app_container booted vn.amx.finance data)
///   touch "$APP/tmp/amfinance-perf-big"
///   xcodebuild test -project AMFinance.xcodeproj -scheme AMFinance \
///     -destination 'platform=iOS Simulator,id=<booted-udid>' \
///     -derivedDataPath DerivedData CODE_SIGNING_ALLOWED=NO \
///     -only-testing:AMFinanceTests/PerformanceBenchmark
///   rm "$APP/tmp/amfinance-perf-big"
/// then read the printed `PERF | bench.*` lines from the log. (Install
/// the app once first — e.g. via `./scripts/test-app.sh` — so the data
/// container exists.)
@Suite(
    .serialized,
    .enabled(
        if: PerformanceBenchmarkGate.isEnabled,
        "30k benchmark: marker file in the test host's tmp (see doc comment)"
    )
)
@MainActor
struct PerformanceBenchmark {
    private static var shared: PerformanceSeeder.Dataset?

    private func dataset() throws -> PerformanceSeeder.Dataset {
        if let shared = Self.shared { return shared }
        let seeded = try PerformanceSeeder.seed(
            transactionCount: 30_000, reviewCount: 2_000)
        Self.shared = seeded
        return seeded
    }

    @Test func seedReport() throws {
        let ds = try dataset()
        let all = try ds.context.fetch(FetchDescriptor<LedgerTransaction>())
        let pending = try ds.context.fetchCount(FetchDescriptor<LedgerTransaction>(
            predicate: #Predicate { $0.needsReview == true }))
        print("PERF | benchmark.rows | \(all.count) txns, \(pending) pending")
        #expect(all.count == 30_000)
        #expect(pending == 2_000)
    }

    @Test func balanceReads() throws {
        try PerfOps.balances(dataset(), tag: "bench")
    }

    @Test func accountDetailInputs() throws {
        try PerfOps.accountDetailInputs(dataset(), tag: "bench")
    }

    @Test func netWorthAndGrouping() throws {
        try PerfOps.netWorthAndGrouping(dataset(), tag: "bench")
    }

    @Test func dashboard() throws {
        try PerfOps.dashboard(dataset(), tag: "bench")
    }

    @Test func transactionSearch() throws {
        try PerfOps.transactionSearch(dataset(), tag: "bench")
    }

    @Test func inboxSuggestions() throws {
        try PerfOps.inboxSuggestions(dataset(), tag: "bench")
    }

    @Test func ruleMatching() throws {
        try PerfOps.ruleMatching(dataset(), tag: "bench")
    }

    @Test func reports() throws {
        try PerfOps.reports(dataset(), tag: "bench")
    }
}

enum PerformanceBenchmarkGate {
    /// Marker file inside the test host app's own sandbox tmp — created
    /// from macOS via `simctl get_app_container <udid> vn.amx.finance data`.
    static let isEnabled = FileManager.default.fileExists(
        atPath: NSTemporaryDirectory() + "amfinance-perf-big")
}
