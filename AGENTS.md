# AM Finance

Native iPhone finance manager. Vietnamese UI, VND only. iOS 17+, Swift 6,
SwiftUI + SwiftData + Swift Testing. No third-party dependencies without asking.

## Generate / build / test

- `./scripts/gen.sh` — downloads pinned XcodeGen (no Homebrew; cached in
  `~/Library/Caches/amfinance-tools`, override with `AMFINANCE_TOOLS_DIR`) and
  regenerates `AMFinance.xcodeproj` from `project.yml`.
- `swift test --package-path Packages/FinanceCore` — fast logic tests on macOS.
- `./scripts/test-app.sh` — the default fast gate: regenerates the project and
  runs only the `AMFinanceTests` unit tests via `xcodebuild test` on an
  auto-picked iPhone simulator (code signing off; the `AMFinanceUITests`
  target is neither built nor run). App tests are serialized across worktrees
  by a shared lock, so a check may wait for another worker's run to finish;
  transient simulator failures retry once.
- `./scripts/test-ui.sh` — the slow UI gate: runs only the `AMFinanceUITests`
  XCUITest smoke suite under the same lock and retry logic, on the dedicated
  `AMFinanceUITests` scheme. Set `AMFINANCE_UI_TEST_FILTERS` to space-separated
  `-only-testing:`/`-skip-testing:` selectors to run just a shard. Integration
  jobs run it, and it must pass before device installs. If you change
  navigation, tab structure or a flow the smoke tests cover, run it yourself
  and update `AppUITests`.
- `scripts/lib-test.sh` — shared lock/simulator/retry helper sourced by both
  test scripts; not meant to be run directly.
- The generated `.xcodeproj` is a build artifact: git-ignored, never commit it.

## UI smoke tests

- `AppUITests/` (`AMFinanceUITests`, XCTest + XCUITest) — end-to-end smoke:
  tabs, quick-add, income+business, edit/delete, settings, accounts/cards/
  loans, debts, reports. Runs via `./scripts/test-ui.sh` on its own
  `AMFinanceUITests` scheme; the default `./scripts/test-app.sh` gate uses the
  `AMFinance` scheme, which only contains the unit-test bundle.
- Tests launch the app with `-uiTestInMemoryStore` → in-memory store + seed.
- Row taps need `.onTapGesture` (List-row `Button` actions don't fire on
  iOS 26); assertions on off-screen list items must scroll first.

## Layout

- `App/Features/<FeatureName>/` — one folder per feature
  (Dashboard, Transactions, Debts, Reports…). **One feature = one folder; do not
  edit `project.yml` unless adding a target or a capability** — `App/` and
  `AppTests/` are globbed, new files need no project edits.
- `App/Models/` — SwiftData models. `App/Shared/` — shared UI/utilities.
- `AppTests/` — app test bundle. `Packages/FinanceCore/` — pure logic package
  (iOS 17 + macOS 14, no SwiftUI/SwiftData imports).

## Rules

- All UI text is Vietnamese (vi-VN).
- Money is `Int64` đồng; format/parse only through `VND` in FinanceCore.
- Pure logic goes in FinanceCore with tests; UI and SwiftData go in `App/`.
- Tests use Swift Testing (`import Testing`, `@Test`, `#expect`).
- SwiftData models must stay CloudKit-compatible: every property optional or
  with a default value, relationships optional with inverses, no unique
  constraints.

## Shared UI kit

Feature screens must use these instead of re-implementing them; use List/Form
with the system inset-grouped style. All in `App/Shared/`:

- `AppCalendar.vietnam` + `AppDateFormat` — day headers, `22/11`, `Tháng 11/2026`, `14:05`.
- `Color(hex:)` + `AppTheme` — income/expense/transfer colors, 12-color palette, ~40 symbols.
- `AmountText(amount:kind:compact:)` — signed, colored VND, monospaced digits.
- `IconBadge(symbol:colorHex:size:)` — SF Symbol on a colored circle.
- `AmountKeypad` + `AmountKeypadState` — đồng keypad; pure reducer, 13-digit cap.
- `IconPickerGrid` + `ColorHexPickerGrid` — icon and color pickers for edit forms.
- `EmptyStateView` — empty-list placeholder with optional action.

## Feature map

One line per `App/Features/` folder with its public entry views so future
workers know what already exists. Pushed views must not create their own
`NavigationStack`.

- `Accounts/` — `AccountsListView`, `AccountDetailView(account:)`, `AccountEditView(account:)`; `AccountBalanceAdjustment` helper.
- `AIAssistant/` — `AISettingsView`, `AIChatView`, `AIInboxSuggestView`, `AICaptureView`; wired at Settings → "Trợ lý AI", the inbox toolbar's "Phân loại bằng AI", the dashboard sparkles button and the `root.aiCapture` satellite beside the "+".
- `AppLock/` — `AppLockSettingsView`, the `.appLockProtected()` modifier on the root; `AppLockController.shared`.
- `BackgroundRefresh/` — `BackgroundRefreshScheduler` (BGAppRefreshTask `vn.amx.finance.refresh`, registered in `AMFinanceApp`), `BackgroundRefreshRunner` (background wallet sync + recurring + reminders with local notifications), `BackgroundRefreshNotificationPlan`.
- `Backup/` — `BackupView` (Settings → Dữ liệu).
- `BillSplit/` — `BillSplitView` (chia bill sheet; `seed:` from the
  transaction editor's unsaved draft or `transaction:` + `BillSplitOriginal`
  for an in-place split), `BillRepaymentSheet` (income → repayment),
  `BillSplitService` (`splitNewBill` posts the payer's own-share expense +
  one transfer advance per friend; `splitExistingExpense` shrinks an
  eligible personal expense in place; `assignRepayment` converts an
  eligible income into a receivable repayment via `WalletSyncTransfer`;
  `canSplitExpense`/`canAssignRepayment` are the editor's eligibility
  mirrors). Equal-split math lives in `FinanceCore.BillSplit`. Entries:
  "Chia bill" / "Ghi nhận hoàn tiền" rows in `TransactionEditorView`.
- `BalanceTrend/` — `BalanceTrendView(account:)`, `BalanceTrendAnchorSheet(account:)`.
- `Budgets/` — `BudgetsView`, `BudgetsEditSheet`, `BudgetsSummaryCard` (dashboard).
- `BusinessHub/` — `BusinessHubView`, `BusinessHubDetailView(business:)`.
- `CreditCards/` — `CreditCardDetailView(account:)`, `CreditCardPaymentSheet`.
- `CSVImport/` — `CSVImportView` (Settings → Dữ liệu → "Nhập sao kê CSV"; pick file + account, map columns, confirm) + `CSVImportParser`/`Detector`/`Mapper`/`Importer`/`Deduper`.
- `Dashboard/` — `DashboardView` ("Tổng quan" tab) + its card structs.
- `DataReset/` — `DataResetView` (Settings → Dữ liệu → "Xoá dữ liệu"): level A wipes transactions + import memory, level B wipes every model and reseeds; `DataResetService`, `DataResetSummary`; success posts `.dataResetCompleted` → `AMFinanceApp` rebuilds the root.
- `Debts/` — `DebtsView` ("Nợ & Thẻ" tab).
- `Loans/` — `LoanDetailView(account:)`, `LoanPaymentSheet`, `LoanPrepaymentSheet`, `LoanRateChangeSheet`.
- `Receivables/` — `ReceivablesView(business:?)`, `ReceivableDetailView(account:)`, `ReceivableActionSheet` (advance/repayment/fee/write-off).
- `Recurring/` — `RecurringListView`, `RecurringEditView`; `App/Models/RecurringGenerator` posts due occurrences on activation.
- `Reminders/` — `ReminderSettingsView`; `ReminderScheduler.reschedule(context:)` runs on activation.
- `Rentals/` — `RentalsView(business:?)`, `RentalUnitDetailView(unit:)`, `RentalUnitEditView`, `RentalLeaseEditView`, `RentalCollectSheet`; posting via `RentalActions`, month math in `RentalSnapshot`.
- `Reports/` — `ReportsView` ("Báo cáo" tab) + section views.
- `Settings/` — `SettingsView` (hub) + `CategoriesListView`, `BusinessesListView`, `BusinessEditView`, `CategoryEditView`.
- `SpendingShare/` — `SpendingShareCard(interval:title:)` (dashboard, "Tỉ lệ chi tiêu tháng này") and `SpendingShareSection(interval:scope:kind:onSelectCategory:onSelectBusiness:)` (reports donuts, drill-down by slice); off-main aggregation in `SpendingShareBuilder`, chart in `App/Shared/ShareDonutChart.swift`.
- `TransactionEditor/` — `TransactionEditorView` (quick-add and edit sheet).
- `Transactions/` — `TransactionsView` ("Giao dịch" tab).
- `WalletLink/` — `WalletLinkSettingsView` (OIDC sign-in to wallet.amx.vn via auth.amx.vn).
- `WalletSync/` — `WalletSyncAccountsView`, `WalletSyncInboxView`, `WalletSyncRulesView`, `WalletSyncStatusBanner`, `.walletSyncAutoRefresh()` modifier; shared `WalletSyncCoordinator` created in `AMFinanceApp`.

## Performance

- `App/Models/LedgerBalanceStore.swift` caches every account balance plus
  card/trend/receivable entries in one pass over fetched transactions.
  Views must read `LedgerBalanceStores.shared(for: container)` (e.g.
  `ledger.balance(of:)`), not the per-account relationship walks;
  `Account.balance` stays the fallback for non-UI callers and stale reads.
- Invalidation is defence-in-depth — on iOS 17 SwiftData does not post
  `ModelContext.didSave` reliably (fixed in iOS 18), so three layers work
  together: (1) the store observes `ModelContext.didSave` plus the Core
  Data notifications still emitted underneath it on iOS 17
  (`NSManagedObjectContextDidSave`, `NSPersistentStoreRemoteChange`);
  (2) `ledger.refreshIfStale()` runs a cheap `LedgerFingerprint`
  (transaction count + newest `updatedAt`, account count + an
  opening-balance checksum — `fetchCount` and limit-1 fetches only) on
  every read, throttled to once a second, plus on `.active` scene phase
  in `AMFinanceApp` and inside `ledger.saveAndCheck(context)` for
  app-side saves; (3) while stale or merely suspected stale (fingerprint
  mismatch or pending unsaved writes on `mainContext`), reads fall back
  to `account.balance` et al. — never a stale cached number. A
  `LedgerAggregateFetcher` model actor recomputes off-main.
- Every in-place `LedgerTransaction` edit must stamp `updatedAt = .now` —
  the fingerprint's newest-stamp check depends on it. Any write that
  bypasses `save()` must call `ledger.invalidate()` manually.
- The 30k-row benchmark suite is `PerformanceBenchmark` in
  `AppTests/PerformanceTests.swift` — gated off by default; enable by
  creating `<app container>/tmp/amfinance-perf-big` and running that suite.

## Release

- `scripts/archive.sh` builds and exports an IPA for TestFlight.
- `scripts/upload-testflight.sh` uploads the IPA — only with
  `--yes-upload`; without it the script is a dry run.
- Both scripts must only run after `./scripts/test-app.sh` and
  `./scripts/test-ui.sh` pass.
