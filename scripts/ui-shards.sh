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
# Test-body time on the green run 45752846072 (xcodebuild's "Executed N tests
# in Xs", compile and the runner-stall retry excluded):
#   shard 1  349s   shard 2  444s   shard 3  375s   shard 4  476s
# ui3's 34 min job was a ~21 min test-runner stall while the app was still
# compiling, plus queueing behind the 5-macOS-job cap — not a longer shard.
# Keep these name lists easy to merge; testOnlineLaunch stays appended to
# shard 1 when the test exists.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
n="${1:-}"

prefix="-only-testing:AMFinanceUITests/AMFinanceUITests"

shard1=(testWiredFeatureScreens testFinanceSync)
shard2=(testTabsReportsAndSettings testTransactionsAddEditDelete testAccountsAndDebts)
shard3=(testRentalsImportAndReminders testAIEntryPointsAndSpendingShare testTransactionScopes)
shard4=(testBillSplit testAgentLedgerAccess testAgentProposalConfirm testAgentSharedConversation testAgentHistory)

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
