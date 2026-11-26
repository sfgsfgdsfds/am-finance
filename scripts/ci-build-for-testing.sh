#!/bin/bash
# ci-build-for-testing.sh — compile the app and test bundles once for the
# iOS Simulator, with no simulator booted. CI test jobs download
# DerivedData/Build/Products and run test-without-building.
#
# AM_BUILD_UI=1 also builds the AMFinanceUITests bundle (quick / all / ui).
# The unit suite leaves it unset and builds only AMFinance + AMFinanceTests.
#
# Signing off. COMPILER_INDEX_STORE_ENABLE=NO skips the index store, which
# the test run does not need. No destination device, so the test runner
# cannot start (and stall) while swiftc is still working — that stall is
# what made the old `xcodebuild test` first attempt burn ~17 min.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

DERIVED="$ROOT/DerivedData"
PRODUCTS="$DERIVED/Build/Products"
mkdir -p "$DERIVED"

"$ROOT/scripts/gen.sh"

LOG="$(mktemp -t amfinance-xcodebuild)"
echo "build-for-testing: log $LOG"

build_scheme() { # $1 scheme
  local scheme="$1" started status
  started="$(date +%s)"
  echo "build-for-testing: $(date -u +%H:%M:%S) scheme ${scheme}"
  if xcodebuild build-for-testing \
      -project "$ROOT/AMFinance.xcodeproj" \
      -scheme "$scheme" \
      -destination "generic/platform=iOS Simulator" \
      -derivedDataPath "$DERIVED" \
      CODE_SIGNING_ALLOWED=NO \
      CODE_SIGNING_REQUIRED=NO \
      CODE_SIGN_IDENTITY= \
      COMPILER_INDEX_STORE_ENABLE=NO \
      COMPILATION_CACHE_ENABLE_CACHING=YES \
      >>"$LOG" 2>&1; then
    echo "build-for-testing: scheme ${scheme} ok in $(( $(date +%s) - started ))s"
    return 0
  fi
  status=$?
  echo "build-for-testing: scheme ${scheme} FAILED in $(( $(date +%s) - started ))s (log: $LOG)" >&2
  grep -E ": error: |error: " "$LOG" 2>/dev/null \
    | sed -E 's/^[[:space:]]+//' | sort -u | head -n 30 >&2 || true
  return "$status"
}

build_scheme AMFinance
if [ "${AM_BUILD_UI:-0}" = "1" ]; then
  build_scheme AMFinanceUITests
fi

if [ ! -d "$PRODUCTS" ]; then
  echo "build-for-testing: missing $PRODUCTS" >&2
  exit 1
fi

echo "build-for-testing: products before slim"
du -sh "$PRODUCTS" 2>/dev/null || true
# dSYMs are not needed to install or run simulator tests.
while IFS= read -r dsym; do
  rm -rf "$dsym"
done < <(find "$PRODUCTS" -name '*.dSYM' -prune)
# The build machine's absolute Products path. Test jobs rewrite .xctestrun
# when their checkout path differs. __TESTROOT__ tokens are left alone.
printf '%s\n' "$PRODUCTS" > "$PRODUCTS/products-prefix.txt"

echo "build-for-testing: xctestrun files"
find "$PRODUCTS" -name '*.xctestrun' -print
xctestrun_count="$(find "$PRODUCTS" -name '*.xctestrun' | wc -l | tr -d ' ')"
want_xctestrun=1
if [ "${AM_BUILD_UI:-0}" = "1" ]; then
  want_xctestrun=2
fi
if [ "$xctestrun_count" -lt "$want_xctestrun" ]; then
  echo "build-for-testing: expected at least ${want_xctestrun} .xctestrun, found ${xctestrun_count}" >&2
  exit 1
fi

echo "build-for-testing: DerivedData top level"
du -sh "$DERIVED" "$DERIVED"/* 2>/dev/null | head -n 40 || true

echo "build-for-testing: products after slim"
du -sh "$PRODUCTS" 2>/dev/null || true
echo "build-for-testing: ** BUILD SUCCEEDED **"
