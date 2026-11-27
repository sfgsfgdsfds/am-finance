import FinanceCore
import Foundation
import SwiftData
import SwiftUI
import Testing
import UIKit
@testable import AMFinance

/// End-to-end view refresh tests in the online-only setup (in-memory app
/// store loaded from `FakeSyncServer` export via `OnlineStore`, instant
/// writes, long-poll, `FinanceSyncMainContextRefresher`): categorizing a
/// `needsReview` expense must immediately drop it from `TransactionsView`'s
/// "Chưa phân loại" queue and update `DashboardView.pendingReviewCount` and
/// `WalletSyncStatusBanner`.
@Suite(.serialized)
@MainActor
struct OnlineCategorizeRefreshTests {

    private final class SaveForwarder: @unchecked Sendable {
        private var observers: [NSObjectProtocol] = []

        init(to center: NotificationCenter) {
            for name in [ModelContext.didSave,
                         Notification.Name.NSManagedObjectContextDidSave] {
                observers.append(NotificationCenter.default.addObserver(
                    forName: name, object: nil, queue: nil
                ) { note in
                    center.post(note)
                })
            }
        }

        deinit {
            for observer in observers {
                NotificationCenter.default.removeObserver(observer)
            }
        }
    }

    private struct OnlineFixture {
        let server: FakeSyncServer
        let device: SyncTestDevice
        let coordinator: FinanceSyncCoordinator
        let store: OnlineStore
        let center: NotificationCenter
        let forwarder: SaveForwarder
        let accountID: UUID
        let categoryID: UUID
        let uncategorizedTxID: UUID
    }

    private func makeOnlineFixture(
        linkedBankAccount: Bool = false
    ) async throws -> OnlineFixture {
        let server = FakeSyncServer()
        let now = Date.now
        let accountID = UUID()
        let categoryID = UUID()
        let uncategorizedTxID = UUID()
        let classifiedTxID = UUID()

        let account = BackupAccount(
            id: accountID,
            name: linkedBankAccount ? "VPBank *1234" : "Tiền mặt",
            kindRaw: (linkedBankAccount ? AccountKind.bank : AccountKind.cash).rawValue,
            openingBalance: 1_000_000,
            icon: linkedBankAccount ? "building.columns.fill" : "banknote.fill",
            colorHex: "34C759",
            note: "",
            sortOrder: 0,
            isArchived: false,
            createdAt: now,
            creditLimit: nil,
            statementDay: nil,
            graceDays: nil,
            loanPrincipal: nil,
            loanAnnualRatePercent: nil,
            loanTermMonths: nil,
            loanStartDate: nil,
            loanPaymentDay: nil,
            loanMethodRaw: nil,
            externalSource: linkedBankAccount ? WalletSyncEngine.externalSource : nil,
            externalAccountID: linkedBankAccount ? "session-1" : nil,
            businessID: nil)
        let category = BackupCategory(
            id: categoryID,
            name: "Ăn uống",
            kindRaw: CategoryKind.expense.rawValue,
            icon: "fork.knife",
            colorHex: "FF9500",
            sortOrder: 0,
            isArchived: false)
        let pendingTx = BackupTransaction(
            id: uncategorizedTxID,
            kindRaw: TransactionKind.expense.rawValue,
            amount: 35_000,
            date: now,
            note: "Cà phê chờ duyệt",
            accountID: accountID,
            toAccountID: nil,
            categoryID: nil,
            businessID: nil,
            needsReview: true,
            externalSource: linkedBankAccount ? WalletSyncEngine.externalSource : nil,
            externalID: linkedBankAccount ? "ext-1" : nil,
            createdAt: now,
            updatedAt: now,
            rentalLeaseID: nil,
            rentalPeriod: nil)
        let doneTx = BackupTransaction(
            id: classifiedTxID,
            kindRaw: TransactionKind.expense.rawValue,
            amount: 45_000,
            date: now.addingTimeInterval(-60),
            note: "Cơm trưa",
            accountID: accountID,
            toAccountID: nil,
            categoryID: categoryID,
            businessID: nil,
            needsReview: false,
            externalSource: nil,
            externalID: nil,
            createdAt: now,
            updatedAt: now,
            rentalLeaseID: nil,
            rentalPeriod: nil)

        server.putRecord(
            entity: "account", id: accountID,
            data: try SyncRecordMapper.jsonValue(of: .account(account)))
        server.putRecord(
            entity: "category", id: categoryID,
            data: try SyncRecordMapper.jsonValue(of: .category(category)))
        server.putRecord(
            entity: "transaction", id: uncategorizedTxID,
            data: try SyncRecordMapper.jsonValue(of: .transaction(pendingTx)))
        server.putRecord(
            entity: "transaction", id: classifiedTxID,
            data: try SyncRecordMapper.jsonValue(of: .transaction(doneTx)))

        let device = try makeSyncDevice(server: server)
        let container = device.container
        let ledgerHook: @Sendable () -> Void = {
            Task { @MainActor in
                LedgerBalanceStores.shared(for: container).invalidate()
            }
        }
        await device.engine.addLocalStoreChangeHook(ledgerHook)
        await device.bootstrap.addLocalStoreChangeHook(ledgerHook)
        await FinanceSyncMainContextRefresher.install(
            on: device.engine, container: device.container)

        let coordinator = FinanceSyncCoordinator(
            engine: device.engine, bootstrap: device.bootstrap,
            shadow: device.shadow, isSignedIn: { true },
            serverDisplay: "test.local")
        coordinator.liveWaitTimeout = 0.05
        coordinator.liveBackoffInitial = .milliseconds(40)
        coordinator.liveBackoffMaximum = .milliseconds(120)
        coordinator.liveEmptyPullDelay = .milliseconds(80)

        let store = OnlineStore(
            container: device.container,
            api: syncTestClient(for: server),
            bootstrap: device.bootstrap,
            coordinator: coordinator,
            isSignedIn: { true },
            signIn: {},
            afterLoad: { await coordinator.refreshState() })

        await store.start()
        #expect(store.phase == .ready)

        let center = NotificationCenter()
        let forwarder = SaveForwarder(to: center)
        coordinator.startObservingLocalSaves(center: center)

        return OnlineFixture(
            server: server,
            device: device,
            coordinator: coordinator,
            store: store,
            center: center,
            forwarder: forwarder,
            accountID: accountID,
            categoryID: categoryID,
            uncategorizedTxID: uncategorizedTxID)
    }

    private func makeWindow<V: View>(hosting rootView: V) -> UIWindow {
        let window: UIWindow
        if let scene = UIApplication.shared.connectedScenes
            .compactMap({ $0 as? UIWindowScene }).first {
            window = UIWindow(windowScene: scene)
        } else {
            window = UIWindow(frame: CGRect(x: 0, y: 0, width: 390, height: 844))
        }
        window.frame = CGRect(x: 0, y: 0, width: 390, height: 844)
        let host = UIHostingController(rootView: rootView)
        window.rootViewController = host
        window.makeKeyAndVisible()
        host.view.frame = window.bounds
        host.view.setNeedsLayout()
        host.view.layoutIfNeeded()
        return window
    }

    private func pumpRunLoop() {
        RunLoop.main.run(until: Date().addingTimeInterval(0.02))
    }

    private func waitUntil(
        timeout: Duration = .seconds(3),
        _ condition: () -> Bool
    ) async -> Bool {
        let deadline = ContinuousClock.now + timeout
        while ContinuousClock.now < deadline {
            pumpRunLoop()
            if condition() { return true }
            try? await Task.sleep(for: .milliseconds(10))
        }
        pumpRunLoop()
        return condition()
    }

    private func categorizeOnMainContext(_ fx: OnlineFixture) throws {
        let main = fx.device.container.mainContext
        let txID = fx.uncategorizedTxID
        let catID = fx.categoryID
        let tx = try #require(try main.fetch(FetchDescriptor<LedgerTransaction>(
            predicate: #Predicate { $0.id == txID })).first)
        let cat = try #require(try main.fetch(FetchDescriptor<LedgerCategory>(
            predicate: #Predicate { $0.id == catID })).first)

        var draft = TransactionDraft(transaction: tx)
        draft.category = cat
        try draft.apply(to: tx)
        try LedgerBalanceStores.shared(for: main.container).saveAndCheck(main)
    }

    @Test func categorizingNeedsReviewExpenseDropsItFromUnclassifiedTransactionsView() async throws {
        let fx = try await makeOnlineFixture()
        defer {
            fx.coordinator.stopLiveUpdates()
            fx.coordinator.stopObservingLocalSaves()
            LedgerBalanceStores.remove(fx.device.container)
        }

        var latestRows: [TransactionListRow] = []
        var renderCount = 0
        let window = makeWindow(
            hosting: TransactionsView { rows in
                latestRows = rows
                renderCount += 1
            }
            .modelContainer(fx.device.container)
        )
        defer {
            window.isHidden = true
            window.rootViewController = nil
        }

        #expect(await waitUntil {
            latestRows.count == 1
                && latestRows.first?.id == fx.uncategorizedTxID
                && latestRows.first?.needsReview == true
        })

        let rendersBeforeEdit = renderCount
        try categorizeOnMainContext(fx)

        // Confirm push reached the server with categoryID + needsReview=false.
        #expect(await waitUntil {
            guard case .object(let fields)? = fx.server.row(
                entity: "transaction", id: fx.uncategorizedTxID)?.data
            else { return false }
            return fields["categoryID"] == .string(fx.categoryID.uuidString)
                && fields["needsReview"] == .bool(false)
        })

        // The rendered "Chưa phân loại" list must re-render and drop the row.
        #expect(await waitUntil {
            renderCount > rendersBeforeEdit && latestRows.isEmpty
        })
        withExtendedLifetime(fx.forwarder) {}
    }

    @Test func categorizingNeedsReviewExpenseUpdatesDashboardPendingReviewCount() async throws {
        let fx = try await makeOnlineFixture()
        defer {
            fx.coordinator.stopLiveUpdates()
            fx.coordinator.stopObservingLocalSaves()
            LedgerBalanceStores.remove(fx.device.container)
        }

        var latestPending = -1
        let window = makeWindow(
            hosting: DashboardView(syncCoordinator: nil) { count in
                latestPending = count
            }
            .modelContainer(fx.device.container)
        )
        defer {
            window.isHidden = true
            window.rootViewController = nil
        }

        #expect(await waitUntil { latestPending == 1 })

        try categorizeOnMainContext(fx)

        #expect(await waitUntil { latestPending == 0 })
        withExtendedLifetime(fx.forwarder) {}
    }

    @Test func categorizingNeedsReviewExpenseUpdatesWalletSyncStatusBanner() async throws {
        let fx = try await makeOnlineFixture(linkedBankAccount: true)
        defer {
            fx.coordinator.stopLiveUpdates()
            fx.coordinator.stopObservingLocalSaves()
            LedgerBalanceStores.remove(fx.device.container)
        }

        let walletSync = WalletSyncCoordinator.live(
            context: fx.device.container.mainContext)
        var latestPending = -1
        let window = makeWindow(
            hosting: NavigationStack {
                WalletSyncStatusBanner(coordinator: walletSync) { count in
                    latestPending = count
                }
            }
            .modelContainer(fx.device.container)
        )
        defer {
            window.isHidden = true
            window.rootViewController = nil
        }

        #expect(await waitUntil { latestPending == 1 })

        try categorizeOnMainContext(fx)

        #expect(await waitUntil { latestPending == 0 && walletSync.pendingReviewCount == 0 })
        withExtendedLifetime(fx.forwarder) {}
    }

    @Test func remoteCategorizationPullUpdatesTransactionsAndDashboard() async throws {
        let fx = try await makeOnlineFixture()
        defer {
            fx.coordinator.stopLiveUpdates()
            fx.coordinator.stopObservingLocalSaves()
            LedgerBalanceStores.remove(fx.device.container)
        }

        var latestRows: [TransactionListRow] = []
        var latestPending = -1
        let window = makeWindow(
            hosting: VStack {
                TransactionsView { rows in latestRows = rows }
                DashboardView(syncCoordinator: nil) { count in latestPending = count }
            }
            .modelContainer(fx.device.container)
        )
        defer {
            window.isHidden = true
            window.rootViewController = nil
        }

        #expect(await waitUntil {
            latestRows.count == 1
                && latestRows.first?.id == fx.uncategorizedTxID
                && latestPending == 1
        })

        guard case .object(var fields)? = fx.server.row(
            entity: "transaction", id: fx.uncategorizedTxID)?.data
        else {
            Issue.record("seeded row missing on server")
            return
        }
        fields["categoryID"] = .string(fx.categoryID.uuidString)
        fields["needsReview"] = .bool(false)
        fx.server.putRecord(
            entity: "transaction", id: fx.uncategorizedTxID,
            data: .object(fields))

        #expect(await waitUntil { latestRows.isEmpty && latestPending == 0 })
        withExtendedLifetime(fx.forwarder) {}
    }

    @Test func saveAndCheckBumpsChangeCountBeforeFirstAggregateEvenWithoutNotifications() throws {
        let container = try AppModelContainer.make(inMemory: true)
        let main = container.mainContext
        let cash = Account(name: "Tiền mặt", kind: .cash)
        let food = LedgerCategory(name: "Ăn uống", kind: .expense)
        let tx = LedgerTransaction(
            kind: .expense, amount: 30_000, note: "Cà phê",
            account: cash, needsReview: true)
        main.insert(cash)
        main.insert(food)
        main.insert(tx)
        try main.save()

        // iOS 17 blind spot: notifications disabled and no aggregate computed yet.
        let store = LedgerBalanceStore(
            container: container, observesSaveNotifications: false)
        let before = store.changeCount
        var draft = TransactionDraft(transaction: tx)
        draft.category = food
        try draft.apply(to: tx)
        try store.saveAndCheck(main)
        #expect(store.changeCount > before)
    }
}
