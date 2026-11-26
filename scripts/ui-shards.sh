#!/bin/bash
# ui-shards.sh — the only list of AMFinanceUITests smoke shards.
#
# Prints the AMFINANCE_UI_TEST_FILTERS value for one shard (space-separated
# -only-testing: selectors). CI and AGENTS.md both point here; do not copy
# the lists anywhere else.
#
#   ./scripts/ui-shards.sh <1|2|3|4>
#
# Shard 1 also includes testOnlineLaunch when that test exists in AppUITests.
# Put a new UI test into the lightest shard below.
#
# Test-body time from run 45773347916 (test-without-building; xcresulttool):
#   testWiredFeatureScreens 360s   testFinanceSync 57s
#   testAccountsAndDebts 282s      testTransactionsAddEditDelete 199s
#   testTabsReportsAndSettings 96s
#   testRentalsImportAndReminders 275s
#   testAIEntryPointsAndSpendingShare 135s
#   testTransactionScopes 94s
#   testBillSplit 98s  testAgentSharedConversation 80s
#   testAgentHistory 74s  testAgentProposalConfirm 67s
#   testAgentLedgerAccess 44s
# Shard 1 stays the two names below so testOnlineLaunch can still be appended.
# The other three are packed to ~7.5–8.5 min of test body (the old shard 2
# was 577s and the long pole).
# Keep these name lists easy to merge.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
n="${1:-}"

prefix="-only-testing:AMFinanceUITests/AMFinanceUITests"

shard1=(testWiredFeatureScreens testFinanceSync)
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

if have_test testOnlineLaunch; then
  shard1+=(testOnlineLaunch)
fi

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
