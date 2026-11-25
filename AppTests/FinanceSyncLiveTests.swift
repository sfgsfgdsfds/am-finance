import FinanceCore
import Foundation
import SwiftData
import Testing
@testable import AMFinance

/// LIVE contract test — exercises `FinanceSyncBootstrap` and
/// `FinanceSyncEngine` against the REAL Go sync API
/// (`/Users/ledinhdai/Desktop/AM_Finance_Web`), not the fake. Skipped
/// unless the test runner's environment carries BOTH
/// `AMFINANCE_SYNC_LIVE_URL` and `AMFINANCE_SYNC_LIVE_TOKEN`.
///
/// Bring the API up on a throwaway database in dev auth mode:
///
///     cd ~/Desktop/AM_Finance_Web
///     source scripts/env.sh
///     psql -c 'CREATE DATABASE amfinance_synctest_x'   # Postgres.app
///     AUTH_MODE=dev HTTP_ADDR=127.0.0.1:18080 \
///     DATABASE_URL='postgres://postgres@localhost:5432/amfinance_synctest_x' \
///     go -C api run ./cmd/server
///
/// then run only this suite with TEST_RUNNER_-prefixed env so the
/// variables reach the test process on the simulator:
///
///     TEST_RUNNER_AMFINANCE_SYNC_LIVE_URL=http://127.0.0.1:18080 \
///     TEST_RUNNER_AMFINANCE_SYNC_LIVE_TOKEN='dev:sync-test-<random>' \
///     xcodebuild test -project AMFinance.xcodeproj -scheme AMFinance \
///       -destination 'platform=iOS Simulator,name=…' \
///       -derivedDataPath DerivedData CODE_SIGNING_ALLOWED=NO \
///       -only-testing:AMFinanceTests/FinanceSyncLiveTests
///
/// `dev:<user>` tokens create a fresh server-side user per value — use
/// a random token per run so the server starts empty.
@Suite(.serialized)
struct FinanceSyncLiveTests {

    private static var liveURL: String? {
        let value = ProcessInfo.processInfo.environment["AMFINANCE_SYNC_LIVE_URL"]
        return (value?.isEmpty == false) ? value : nil
    }

    private static var liveToken: String? {
        let value = ProcessInfo.processInfo.environment["AMFINANCE_SYNC_LIVE_TOKEN"]
        return (value?.isEmpty == false) ? value : nil
    }

    static var configured: Bool { liveURL != nil && liveToken != nil }

    /// Rows `seedFullLedger` inserts — see FinanceSyncTestSupport.
    private static let seededRowCount = 22

    @Test(
        .enabled(if: FinanceSyncLiveTests.configured,
                 "needs AMFINANCE_SYNC_LIVE_URL + AMFINANCE_SYNC_LIVE_TOKEN"))
    func uploadDownloadAndSyncConvergeAgainstLiveServer() async throws {
        let baseURL = try #require(URL(string: Self.liveURL ?? ""))
        let token = try #require(Self.liveToken)
        let api = FinanceSyncAPIClient(
            baseURL: baseURL,
            tokenProvider: FixedTokenProvider(token: token),
            urlSession: .shared)

        // A fresh dev token means a fresh user — the server is empty.
        let a = try makeSyncDevice(api: api)
        let ids = try seedFullLedger(in: a.context)
        let probe = try await a.bootstrap.probe()
        #expect(probe.serverEmpty)
        #expect(probe.localTotal == Self.seededRowCount)

        // "Đưa dữ liệu iPhone lên server": REPLACE lands all 22 rows.
        let up = try await a.bootstrap.uploadReplace()
        #expect(up.exportedRows == Self.seededRowCount)
        #expect(up.importUpserted == Self.seededRowCount)
        #expect(up.importTombstoned == 0)
        #expect(up.sync?.pushedUpserts == 0)
        #expect(up.sync?.pushedDeletes == 0)
        #expect(try await a.shadow.isEnabled())

        // "Tải dữ liệu từ server về iPhone" on a second store —
        // identical content hashes and zero push-back.
        let b = try makeSyncDevice(api: api)
        let down = try await b.bootstrap.downloadReplace()
        #expect(down.recordsDownloaded == Self.seededRowCount)
        #expect(down.restoreInserted == Self.seededRowCount)
        #expect(down.sync?.pushedUpserts == 0)
        #expect(down.sync?.pushedDeletes == 0)
        #expect(try await b.shadow.isEnabled())
        #expect(try await a.engine.localContentHashes()
                == b.engine.localContentHashes())

        // Edge cases survived the round trip on B — relationship links,
        // the rental period, loan terms. (Predicates capture local
        // constants; #Predicate cannot key-path into `ids`.)
        let rentTxID = ids.rentTx
        let rentalLeaseID = ids.rentalLease
        let transferTxID = ids.transferTx
        let cashAccountID = ids.cashAccount
        let creditCardAccountID = ids.creditCardAccount
        let loanAccountID = ids.loanAccount
        let expenseTxID = ids.expenseTx
        let overallBudgetID = ids.overallBudget
        let unlinkedTxID = ids.unlinkedTx

        let rent = try #require(try b.context.fetch(
            FetchDescriptor<LedgerTransaction>(
                predicate: #Predicate { $0.id == rentTxID })).first)
        #expect(rent.rentalLease?.id == rentalLeaseID)
        #expect(rent.rentalPeriod != nil)
        let transfer = try #require(try b.context.fetch(
            FetchDescriptor<LedgerTransaction>(
                predicate: #Predicate { $0.id == transferTxID })).first)
        #expect(transfer.account?.id == cashAccountID)
        #expect(transfer.toAccount?.id == creditCardAccountID)
        let loan = try #require(try b.context.fetch(
            FetchDescriptor<Account>(
                predicate: #Predicate { $0.id == loanAccountID })).first)
        #expect(loan.loanMethodRaw == LoanMethod.annuity.rawValue)
        #expect(loan.loanAnnualRatePercent == 8.55)

        // The incremental path (syncOnce, not import): edit + insert +
        // delete on A → one push batch → B converges after its pull.
        let tx = try #require(try a.context.fetch(
            FetchDescriptor<LedgerTransaction>(
                predicate: #Predicate { $0.id == expenseTxID })).first)
        tx.note = "sửa trên A ✏️"
        tx.updatedAt = .now
        let cash = try #require(try a.context.fetch(
            FetchDescriptor<Account>(
                predicate: #Predicate { $0.id == cashAccountID })).first)
        let extra = LedgerTransaction(
            kind: .income, amount: 777_000,
            note: "đồng bộ thêm ✨", account: cash)
        a.context.insert(extra)
        let budget = try #require(try a.context.fetch(
            FetchDescriptor<Budget>(
                predicate: #Predicate { $0.id == overallBudgetID })).first)
        a.context.delete(budget)
        try a.context.save()

        let pushed = try await a.engine.syncOnce()
        #expect(pushed.pushedUpserts == 2)
        #expect(pushed.pushedDeletes == 1)

        _ = try await b.engine.syncOnce()
        #expect(try await a.engine.localContentHashes()
                == b.engine.localContentHashes())
        #expect(try b.context.fetchCount(FetchDescriptor<Budget>(
            predicate: #Predicate { $0.id == overallBudgetID })) == 0)

        // And the reverse direction: edit + delete on B → A converges.
        let bTx = try #require(try b.context.fetch(
            FetchDescriptor<LedgerTransaction>(
                predicate: #Predicate { $0.id == transferTxID })).first)
        bTx.note = "sửa trên B 🔄"
        bTx.updatedAt = .now
        let bUnlinked = try #require(try b.context.fetch(
            FetchDescriptor<LedgerTransaction>(
                predicate: #Predicate { $0.id == unlinkedTxID })).first)
        b.context.delete(bUnlinked)
        try b.context.save()

        let bPushed = try await b.engine.syncOnce()
        #expect(bPushed.pushedUpserts == 1)
        #expect(bPushed.pushedDeletes == 1)

        _ = try await a.engine.syncOnce()
        #expect(try await a.engine.localContentHashes()
                == b.engine.localContentHashes())
    }
}
