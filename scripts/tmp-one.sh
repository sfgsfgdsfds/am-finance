#!/bin/bash
# test-app.sh — the default fast gate: regenerate the project, pick an
# available iPhone simulator and run only the AMFinanceTests unit tests via
# `xcodebuild test` for scheme AMFinance with code signing disabled. The
# AMFinanceUITests smoke suite is neither built nor run here — use
# ./scripts/test-ui.sh for it.
# Quiet on success; prints the failure log tail and exits non-zero on failure.
# Lock, simulator pick and retry details: scripts/lib-test.sh.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

AM_TEST_NAME="test-app"
AM_TEST_SCHEME="AMFinance"
source "$ROOT/scripts/lib-test.sh"

am_test_lock "$ROOT/scripts/test-app.sh"
am_test_run -only-testing:AMFinanceTests/FinanceSyncPullApplyTests
