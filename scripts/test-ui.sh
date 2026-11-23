#!/bin/bash
# test-ui.sh — the slow end-to-end gate: regenerate the project, pick an
# available iPhone simulator and run only the AMFinanceUITests XCUITest smoke
# suite via `xcodebuild test` for scheme AMFinanceUITests with code signing
# disabled. Run by integration jobs and before device installs;
# ./scripts/test-app.sh stays the fast default gate.
# Quiet on success; prints failing test names + the log tail and exits
# non-zero on failure. Lock, simulator pick and retry details:
# scripts/lib-test.sh.
#
# Optional sharding: AMFINANCE_UI_TEST_FILTERS holds a space-separated list
# of xcodebuild test selectors, e.g.
#   AMFINANCE_UI_TEST_FILTERS='-only-testing:AMFinanceUITests/AMFinanceUITests/testBillSplit' ./scripts/test-ui.sh
#   AMFINANCE_UI_TEST_FILTERS='-skip-testing:AMFinanceUITests/AMFinanceUITests/testBillSplit' ./scripts/test-ui.sh
# When set, the selectors are passed through INSTEAD of the default
# whole-bundle -only-testing:AMFinanceUITests (the scheme holds no other
# test target, so -skip-testing alone still means "the smoke suite minus").
# The variable rides along on the lock re-exec below unchanged.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

AM_TEST_NAME="test-ui"
AM_TEST_SCHEME="AMFinanceUITests"
source "$ROOT/scripts/lib-test.sh"

filters=(-only-testing:AMFinanceUITests)
if [ -n "${AMFINANCE_UI_TEST_FILTERS:-}" ]; then
  read -r -a filters <<<"$AMFINANCE_UI_TEST_FILTERS"
  if [ "${#filters[@]}" -eq 0 ]; then
    echo "$AM_TEST_NAME: AMFINANCE_UI_TEST_FILTERS is set but empty" >&2
    exit 2
  fi
  for selector in "${filters[@]}"; do
    case "$selector" in
      -only-testing:?*|-skip-testing:?*) ;;
      *)
        echo "$AM_TEST_NAME: invalid AMFINANCE_UI_TEST_FILTERS selector '$selector'" >&2
        echo "$AM_TEST_NAME: expected space-separated -only-testing:.../-skip-testing:... tokens" >&2
        exit 2
        ;;
    esac
  done
fi

am_test_lock "$ROOT/scripts/test-ui.sh"
am_test_run "${filters[@]}"
