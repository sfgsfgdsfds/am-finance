#!/bin/bash
# ui-shards.sh — the only list of AMFinanceUITests smoke shards.
#
# Prints the AMFINANCE_UI_TEST_FILTERS value for one shard (space-separated
# -only-testing: selectors). CI and AGENTS.md both point here; do not copy
# the lists anywhere else.
#
#   ./scripts/ui-shards.sh <1|2|3|4>
#
# Test-body time from run 45773347916 (test-without-building; xcresulttool):
#   testWiredFeatureScreens 360s   testFinanceSync 57s                 shard 1  417s
#   testTransactionsAddEditDelete 199s   testAccountsAndDebts 282s     shard 2  481s
#   testRentalsImportAndReminders 275s
#   testAIEntryPointsAndSpendingShare 135s
#   testTabsReportsAndSettings 96s                                      shard 3  506s
#   testTransactionScopes 94s
#   testBillSplit 98s  testAgentSharedConversation 80s
#   testAgentHistory 74s  testAgentProposalConfirm 67s
#   testAgentLedgerAccess 44s                                           shard 4  457s
# Shard 1 is the lightest (417s). testOnlineLaunch (~1–2 min) is on it:
# 417+120s = 537s, still the lowest new maximum (shard 4 would become 577s,
# shard 2 601s). Rebalanced job walls (run 45776397258, without this test)
# were ui1 15m40s, ui2 15m02s, ui3 15m04s, ui4 16m37s — boot overhead, not
# the packing metric. The other three stay at ~7.5–8.5 min of test body.
# Put a new UI test into the lightest shard. Keep these name lists easy to merge.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
n="${1:-}"

prefix="-only-testing:AMFinanceUITests/AMFinanceUITests"

shard1=(testWiredFeatureScreens testFinanceSync testOnlineLaunch)
shard2=(testTransactionsAddEditDelete testAccountsAndDebts)
shard3=(testRentalsImportAndReminders testAIEntryPointsAndSpendingShare testTabsReportsAndSettings)
shard4=(testBillSplit testAgentLedgerAccess testAgentProposalConfirm testAgentSharedConversation testAgentHistory testTransactionScopes)

# BSD grep on the runners has no reliable --include, so search the files directly.
have_test() {
  local name="$1" f
  while IFS= read -r f; do
    if grep -qE "func[[:space:]]+${name}[[:space:]]*\\(" "$f"; then
      return 0
    fi
  done < <(find "$ROOT/AppUITests" -name '*.swift' -type f)
  return 1
}

case "$n" in
  1) tests=("${shard1[@]}") ;;
  2) tests=("${shard2[@]}") ;;
  3) tests=("${shard3[@]}") ;;
  4) tests=("${shard4[@]}") ;;
  *)
    echo "usage: ui-shards.sh <1|2|3|4>" >&2
    exit 2
    ;;
esac

for t in "${tests[@]}"; do
  if ! have_test "$t"; then
    echo "ui-shards: test ${t} (shard ${n}) not found in AppUITests" >&2
    exit 2
  fi
done

out=""
for t in "${tests[@]}"; do
  sel="${prefix}/${t}"
  if [ -z "$out" ]; then
    out="$sel"
  else
    out="${out} ${sel}"
  fi
done
printf '%s\n' "$out"
