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
- AMDev stops a single `--check` after 15 minutes and the whole UI suite
  takes longer, so gate it as four shards with `AMFINANCE_UI_TEST_FILTERS`
  (each selector is `-only-testing:AMFinanceUITests/AMFinanceUITests/<name>`):
  (1) `testWiredFeatureScreens`, `testFinanceSync`, `testOnlineLaunch`; (2)
  `testTabsReportsAndSettings`, `testTransactionsAddEditDelete`,
  `testAccountsAndDebts`; (3) `testRentalsImportAndReminders`,
  `testAIEntryPointsAndSpendingShare`, `testTransactionScopes`; (4)
  `testBillSplit`, `testAgentLedgerAccess`, `testAgentProposalConfirm`,
  `testAgentSharedConversation`, `testAgentHistory`.
  Put a new UI test into the lightest shard.
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
- Adding `-uiTestAgentScript` (honoured only beside the in-memory store,
  DEBUG-only) makes the Agent screen count as configured — a scripted
  offline client proposes one canned expense — so
  `testAgentProposalConfirm` drives the proposal card end to end.
- Adding `-uiTestFakeSyncServer` (also honoured only beside the
  in-memory store, DEBUG-only) points the finance sync at an in-app
  in-memory server (push/pull/import + seq + tombstones) with a fake
  signed-in token — `testFinanceSync` drives the Máy chủ page
  (status visible, "Tải lại dữ liệu" reloads from the fake export).
  Without `-uiTestOnline` the sign-in gate stays off so the seeded
  tabs are immediate, and automatic sync triggers stay inert.
  `-uiTestOnline` (with both flags) runs the online gate against the
  fake, which is seeded with one account, "Ăn uống" and two
  transactions; the save observer stays on so a quick-add pushes.
  `testOnlineLaunch` checks the loading gate, that push (DEBUG
  "Mốc máy chủ" seq on Máy chủ) and "Tải lại dữ liệu".
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
- `AIAgent/` — `AIAgentView` (the one chat-style Agent, pushed from the
  dashboard sparkles button, Settings → "Agent" and the Giao dịch
  toolbar leading button), a thin view over `AIAgentController` —
  `AIAgentControllers.shared(for: container)` keeps ONE shared session
  app-wide so an in-flight turn survives pops and tab switches (the
  conversation is replaced only on "Cuộc trò chuyện mới", a history
  open/delete or `.dataResetCompleted`; a real provider-destination
  change rebuilds the session `restoring:` the snapshot under the same
  record id; a transient `makeClient` failure keeps it while the
  screen shows "Chưa cấu hình AI"; `AgentActivityDot`/
  `agentActivityBadge()` badge the three entry points while the agent
  works or a reply landed unseen) —
  driven by `AIAgentChatSession` (bounded
  loop: max 4 tool steps per turn, one correction round, tool results
  ride back as untrusted user-role text; `pendingProposal` →
  `confirmProposal()` is the only write path) + `AIAgentChatProtocol`
  (JSON-in-text contract: answer / search / summary / actions);
  `AIAgentLedgerTools` (`lookup` bounded read under `resultLimit`/
  `scanLimit`/`maxWindow`, `validate` dry run, atomic user-confirmed
  `apply` of setCategory/add/edit/delete — `actionLimit`, per-action
  refusals as `AIAgentApplyError.action(i, reason)`);
  `AIAgentToolPlanner` search-args parsing + day helpers;
  `AIAgentAccess`/`AIAgentPermission` policy — the `aiAgent.access` and
  `aiAgent.includeNotes` `@AppStorage` keys set in `AISettingsView`
  → "Quyền của Agent".
  History: `AIAgentConversationStore` keeps one JSON per conversation
  in `Application Support/AgentConversations/` (device-local only —
  no SwiftData, no CloudKit, NOT in Backup export; `.live()` returns a
  fresh temp dir under `-uiTestInMemoryStore`), capped at 50
  conversations / 400 messages / 200k transcript chars. The controller
  auto-saves `session.snapshot()` on `onStateChange`, restores the
  latest record on the first session of a launch and reopens entries
  via `openConversation`/`deleteConversation`/`deleteAllConversations`;
  both data-reset levels wipe it. `AIAgentHistoryView` ("Lịch sử",
  toolbar id `agent.history`) lists saved conversations — tap to
  restore, swipe to delete, "Xoá tất cả".
- `AIAssistant/` — `AISettingsView` (Settings → Trợ lý AI → "Nhà cung cấp AI"; hosts the "Quyền của Agent" pickers), `AIInboxSuggestView` (inbox toolbar's "Phân loại bằng AI"), `AICaptureView` (the `root.aiCapture` satellite beside "+"); shared plumbing `AIClient`/`AIChatClientProtocol`, `AIChatScope` + `AIChatContextLoader`/`AIFinanceContextBuilder` summaries, extraction/categorization parsers.
- `AppLock/` — `AppLockSettingsView`, the `.appLockProtected()` modifier on the root; `AppLockController.shared`.
- `BackgroundRefresh/` — `BackgroundRefreshScheduler` (BGAppRefreshTask `vn.amx.finance.refresh`, registered in `AMFinanceApp`), `BackgroundRefreshRunner` (background wallet sync + recurring + reminders with local notifications — no web-sync step; the in-memory store is not loaded in the background), `BackgroundRefreshNotificationPlan`.
- `Backup/` — `BackupView` (Settings → Dữ liệu). Export is the in-memory ledger. Restore `.replace` POSTs the document to `v1/backup/import` then `OnlineStore.reload()`; `.merge` restores into memory and the engine pushes it (large files can take a while).
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
- `FinanceSync/` — two-way server sync (online-only launch: every REAL
  launch runs it over an in-memory app store AND an in-memory shadow —
  `FinanceSyncCoordinator.makeStack(inMemoryShadow: true)`, no
  `FinanceSync.store` file is opened; `FinanceSyncBootstrap.loadOnline`
  is the launch load and `FinanceSyncAPIClient.exportSnapshot()`/`head()`/
  `wait(cursor:timeout:)` its server calls — see `OnlineStore/`): `FinanceSyncEngine`
  (`actor` owning a background `ModelContext` — `syncOnce(fullScan:)` pulls from the
  shadow cursor with parent-before-child deferred resolution, then
  diffs local content hashes vs the shadow and pushes `SyncBatcher`
  batches; conflict policy is FIXED — an unpushed local change wins
  over the pulled version and pushes that cycle; `422` index ≥ 0
  quarantines the one record until its hash changes; `409` reruns
  pull+diff ≤ 3 rounds; pushes persist key+body before sending so a
  crash replays byte-identically; the pull cursor never jumps on push —
  own writes return as no-ops. The diff has two scan modes
  (`FinanceSyncScanMode`, `report.scanMode`): QUICK is the routine
  cycle — transactions are re-hashed only when `updatedAt` passes the
  persisted `lastScanStart` minus a 5 s margin, inserts/deletes still
  surface through the id-set diff vs the shadow, the eight small
  entities always hash fully; FULL re-hashes everything — first cycle
  after launch, `syncOnce(fullScan: true)`, or when `lastFullScanAt`
  ages past 6 h — and is the backstop for `updatedAt`-invisible edits
  and silent relationship nullifications. Content hashing is the
  direct field encoder (`SyncRecordMapper.canonicalFields` →
  `SyncContentHasher.hash(fields:)`) — byte-identical to the old
  encode → parse → canonicalize pipeline; pulled records decode to the
  same DTO and hash the same way. `report.hashedTransactions` counts
  the rows actually hashed this cycle. Local writes fire the
  `addLocalStoreChangeHook` closure and
  `.financeSyncLocalStoreChanged` — step 4 hooks
  `LedgerBalanceStore.invalidate()` there) → `FinanceSyncReport`;
  `FinanceSyncConfig` (base URL + UserDefaults override),
  `FinanceSyncAPIClient` (push/pushEncoded/pull/importBackup/highWater
  against `/v1/sync/*`, one-time 401 token-refresh retry, typed
  conflict/validation/idempotency errors), `SyncShadowStore`
  (`@ModelActor` over a separate `FinanceSync.store` holding
  `SyncShadowEntry` + `SyncQuarantineEntry` + the `SyncShadowState`
  singleton — pull cursor, pending-push idempotency key/body, the
  scan markers `lastScanStart`/`lastFullScanAt` — NOT in
  `AppSchema.allModels`), `SyncRecordMapper` (model ↔ backup-v5 DTO
  per row — `syncFields` is the one field enumeration feeding both the
  content hash and the wire `SyncJSONValue`, `references(of:)` for
  deferred relinking).
  Wire types/canonical hashing/diff/batching live in
  `FinanceCore/SyncJSON.swift` + `SyncWire.swift`.
  `FinanceSyncBootstrap` (actor, uses only the engine's public API) is
  the first-sync chooser: `probe()` (server empty? local counts? shadow
  empty?), `uploadReplace()` ("Đưa dữ liệu iPhone lên server" — export
  backup-v5 → `importBackup` REPLACE → wipe shadow → shadow = local
  content hashes at cursor 0 → `syncOnce(fullScan: true)` reconcile →
  enable), `downloadReplace()` ("Tải dữ liệu từ server về iPhone" —
  pull all pages → build a backup-v5 doc →
  `BackupRestorer.restore(.replace)` → shadow = local hashes, cursor =
  stream head → `syncOnce(fullScan: true)` → enable).
  Sync enables only as the last step so a failed run is safely
  resumable. Test scaffolding lives in
  `AppTests/FinanceSyncTestSupport.swift` — `FakeSyncServer`
  (unique-host URLProtocol stub, pull-hold seam, import REPLACE),
  `makeSyncDevice`, `seedFullLedger` (all 9 entities + edge cases).
  `AppTests/FinanceSyncLiveTests` is the live contract test against the
  real Go API — skipped unless `AMFINANCE_SYNC_LIVE_URL` +
  `AMFINANCE_SYNC_LIVE_TOKEN` are set; bring up `AM_Finance_Web` on a
  throwaway DB with `AUTH_MODE=dev` on 127.0.0.1 and pass the vars via
  `TEST_RUNNER_`-prefixed env (see the file's header).
  App wiring: `FinanceSyncCoordinator` (@MainActor @Observable,
  single-flight `syncNow`/`syncIfStale`, `enable(mode:)` via the
  bootstrap, `pause()`/`resume()`/`disconnect()`, the ~3 s debounced
  local-save trigger — instant, no debounce, while `instantWrites` is on
  (online mode; saves during a cycle coalesce into one follow-up) — and
  Vietnamese `errorText`) is created once in
  `AMFinanceApp` and injected via `.environment(\.financeSync)` —
  under `-uiTestInMemoryStore` WITHOUT `-uiTestFakeSyncServer` the
  coordinator is not created at all (like `WalletSyncCoordinator`), so
  no shadow store or refresh task exists during smoke tests;
  `.financeSyncAutoRefresh()` on the root attaches appear/scenePhase/
  60 s triggers plus the save-notification debounce — it attaches
  NOTHING under `-uiTestInMemoryStore` except `-uiTestOnline` (that
  launch keeps the triggers so a quick-add pushes), and every trigger is further
  gated on `coordinator.enabled`/`refreshState()` writes only on real
  changes — a `.dataResetCompleted` forces the next
  cycle FULL, and the engine/bootstrap `addLocalStoreChangeHook`
  invalidates `LedgerBalanceStores`. `ServerStatusView`
  (Settings → Dữ liệu → "Máy chủ", AX ids `server.*`) shows the server
  URL, the signed-in WalletLink account, the connection state and the
  last update time (plus a DEBUG "Mốc máy chủ" high-water seq when the
  UI-test fake is on), plus "Tải lại dữ liệu" (`OnlineStore.reload()`) and
  "Đăng xuất" (WalletLink `signOut`, in-memory data dropped, back to
  the sign-in gate). There is no enable/pause/disconnect UI.
  Only USER saves trigger the auto-sync (`FinanceSyncSaveFilter`:
  engine-origin thread mark + synced-entity names + container), and
  `FinanceSyncMainContextRefresher` re-fetches overwritten rows the main
  context holds after each applied page, then writes the synced
  properties back through their setters and saves inside
  `FinanceSyncSaveFilter.asEngine` so Observation fires without
  scheduling a push. If the main context already has unsaved user
  edits, those are saved first as a normal user save (outside
  `asEngine`, so the instant push runs); the engine-tagged save and
  its `rollback` cover only the refresher's own touches. In online
  mode the coordinator also long-polls
  `GET /v1/sync/wait` while the scene is active (`isOnline` drops on a
  transport failure; a `422` sets `rejectionReloadPending` and the store
  reloads from the export).
  `BackgroundRefreshRunner` does not run a web-sync step — the store is
  not loaded in the background. The skip-when-not-ready guard stays.
  `FinanceSyncUITestSupport` is the DEBUG-only `-uiTestFakeSyncServer`
  in-app fake (mirror of `FakeSyncServer` minus test seams) + fixed
  token provider; it drives the Máy chủ page. Data reset and a
  replace-restore POST `v1/backup/import` (REPLACE) and reload.
- `DataReset/` — `DataResetView` (Settings → Dữ liệu → "Xoá dữ liệu"): level A (transactions) and level B (everything, then `SeedData` defaults) build the resulting backup-v5 document, POST `v1/backup/import` (REPLACE) and `OnlineStore.reload()`; footers say the web copy is deleted too. BOTH levels also wipe the saved Agent conversation history (`DataResetService.conversationStore.deleteAll()`); `DataResetService`, `DataResetSummary`; success posts `.dataResetCompleted` → `AMFinanceApp` rebuilds the root. Plain UI-test launches (no server) restore that same document locally.
- `Debts/` — `DebtsView` ("Nợ & Thẻ" tab).
- `Loans/` — `LoanDetailView(account:)`, `LoanPaymentSheet`, `LoanPrepaymentSheet`, `LoanRateChangeSheet`.
- `OnlineStore/` — the online-only launch (stage 1; the web server IS the
  backend, nothing is persisted locally). `OnlineStore` (@MainActor
  @Observable; phases `starting → signedOut → migratingLegacy → loading →
  ready | failed(text)`, `isOnline`, `rejectionMessage`, `signIn()`/`retry()`, `reload(message:)` — the one reload path for a rejected push, "Tải lại dữ liệu", data reset and replace-restore — and `signOut()`) is created in `AMFinanceApp`
  for every real launch (and for `-uiTestInMemoryStore -uiTestFakeSyncServer
  -uiTestOnline`, DEBUG) over an in-memory app container with NO
  `SeedData` and an in-memory shadow; `OnlineGate` (`OnlineGateView`) shows
  `RootTabView` — and so recurring/reminder/wallet-sync activation — ONLY
  in `ready`, else sign-in (client-id field when WalletLink is not
  configured) / loading / error + "Thử lại". While `ready` but offline
  the gate covers the tabs with "Mất kết nối máy chủ — đang thử lại…".
  A rejected push (`422`) reloads this same path and alerts
  "Máy chủ từ chối thay đổi: …". Load = `GET /v1/backup/export`
  (`FinanceSyncSnapshot`: document + `syncSeq`, body wins over
  `X-Sync-Seq`) → `FinanceSyncBootstrap.loadOnline`: `.replace` restore
  inside `FinanceSyncSaveFilter.asEngine`, shadow = local hashes at cursor
  `syncSeq`, enable, one engine cycle (pushes 0, pulls only newer seqs); a
  brand-new server (`syncSeq == 0`, no rows) is seeded with `SeedData` in
  memory and the cycle pushes it. Plain `-uiTestInMemoryStore` launches
  stay seeded/offline/no gate. `LegacyStoreMigrator` (after sign-in,
  before load, only if `Application Support/default.store` exists —
  verified default URL): backup-v5 export to `LegacyStore-<ts>/
  legacy-backup.json` FIRST; sync configured (enabled/paused/any shadow
  entry or cursor) → `syncOnce(fullScan:)` twice, the second must push 0
  (still-quarantined records only live in the backup → one-time notice);
  never synced → `head == 0` imports the export, else server wins + notice;
  then `default.store*`/`FinanceSync.store*` are MOVED (never deleted) into
  the folder. `LegacyMigration.json` records folder/decisions so a retry
  after any failure resumes; any failure moves nothing → `failed`.
  `BackgroundRefreshRunner(isDataReady:)` skips wallet sync, recurring
  AND reminders until the store is `ready` (no web-sync step). Tests:
  `AppTests/OnlineStoreTests.swift` (temp-directory Application Support,
  `FakeSyncServer` export/head/`setFailure` seams).
- `Receivables/` — `ReceivablesView(business:?)`, `ReceivableDetailView(account:)`, `ReceivableActionSheet` (advance/repayment/fee/write-off).
- `Recurring/` — `RecurringListView`, `RecurringEditView`; `App/Models/RecurringGenerator` posts due occurrences on activation.
- `Reminders/` — `ReminderSettingsView`; `ReminderScheduler.reschedule(context:)` runs on activation.
- `Rentals/` — `RentalsView(business:?)`, `RentalUnitDetailView(unit:)`, `RentalUnitEditView`, `RentalLeaseEditView`, `RentalCollectSheet`; posting via `RentalActions`, month math in `RentalSnapshot`.
- `Reports/` — `ReportsView` ("Báo cáo" tab) + section views.
- `Settings/` — `SettingsView` (hub) + `CategoriesListView`, `BusinessesListView`, `BusinessEditView`, `CategoryEditView`.
- `SpendingShare/` — `SpendingShareCard(interval:title:)` (dashboard, "Tỉ lệ chi tiêu tháng này") and `SpendingShareSection(interval:scope:kind:onSelectCategory:onSelectBusiness:)` (reports donuts, drill-down by slice); off-main aggregation in `SpendingShareBuilder`, chart in `App/Shared/ShareDonutChart.swift`.
- `TransactionEditor/` — `TransactionEditorView` (quick-add and edit sheet).
- `Transactions/` — `TransactionsView` ("Giao dịch" tab) with the
  `TransactionListScope` strip (`txList.scope.*` AX ids): "Chưa phân loại"
  default queue, "Tất cả" (only scope showing the month Thu/Chi summary),
  "Chuyển khoản", one tab per used category.
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
