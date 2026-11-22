# AM Finance

Native iPhone finance manager. Vietnamese UI, VND only. iOS 17+, Swift 6,
SwiftUI + SwiftData + Swift Testing. No third-party dependencies without asking.

## Generate / build / test

- `./scripts/gen.sh` — downloads pinned XcodeGen (no Homebrew; cached in
  `~/Library/Caches/amfinance-tools`, override with `AMFINANCE_TOOLS_DIR`) and
  regenerates `AMFinance.xcodeproj` from `project.yml`.
- `swift test --package-path Packages/FinanceCore` — fast logic tests on macOS.
- `./scripts/test-app.sh` — regenerates the project and runs `xcodebuild test`
  on an auto-picked iPhone simulator (code signing off). App tests are
  serialized across worktrees by a shared lock, so a check may wait for
  another worker's run to finish; transient simulator failures retry once.
- The generated `.xcodeproj` is a build artifact: git-ignored, never commit it.

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
