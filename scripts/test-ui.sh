#!/bin/bash
# test-ui.sh — the slow end-to-end gate: regenerate the project, pick an
# available iPhone simulator and run only the AMFinanceUITests XCUITest smoke
# suite via `xcodebuild test` for scheme AMFinance with code signing disabled.
# Run by integration jobs and before device installs; ./scripts/test-app.sh
# stays the fast default gate.
# Quiet on success; prints failing test names + the log tail and exits
# non-zero on failure. Lock, simulator pick and retry details:
# scripts/lib-test.sh.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

AM_TEST_NAME="test-ui"
AM_TEST_SCHEME="AMFinanceUITests"
source "$ROOT/scripts/lib-test.sh"

am_test_lock "$ROOT/scripts/test-ui.sh"
am_test_run -only-testing:AMFinanceUITests
