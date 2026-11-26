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

# The unit-test bundle is copied into AMFinance.app/PlugIns by the AMFinance
# scheme. The UI scheme rebuilds that same .app and drops the plug-in (the
# quick run's artifact had the app and the UI runner, and no
# AMFinanceTests.xctest). Stash the hosted-test extras and put them back.
SIM_PRODUCTS="$PRODUCTS/Debug-iphonesimulator"
HOST_APP="$SIM_PRODUCTS/AMFinance.app"
STASH="$ROOT/build/host-stash"

stash_host_extras() {
  rm -rf "$STASH"
  mkdir -p "$STASH"
  if [ -d "$HOST_APP/PlugIns" ]; then
    cp -R "$HOST_APP/PlugIns" "$STASH/PlugIns"
  fi
  if [ -d "$HOST_APP/Frameworks" ]; then
    cp -R "$HOST_APP/Frameworks" "$STASH/Frameworks"
  fi
  if [ -d "$SIM_PRODUCTS/AMFinanceTests.xctest" ]; then
    cp -R "$SIM_PRODUCTS/AMFinanceTests.xctest" "$STASH/AMFinanceTests.xctest"
  fi
}

restore_host_extras() {
  if [ -d "$STASH/PlugIns" ]; then
    mkdir -p "$HOST_APP/PlugIns"
    cp -R "$STASH/PlugIns/." "$HOST_APP/PlugIns/"
  elif [ -d "$STASH/AMFinanceTests.xctest" ]; then
    mkdir -p "$HOST_APP/PlugIns"
    cp -R "$STASH/AMFinanceTests.xctest" "$HOST_APP/PlugIns/"
  fi
  if [ -d "$STASH/Frameworks" ]; then
    mkdir -p "$HOST_APP/Frameworks"
    cp -R "$STASH/Frameworks/." "$HOST_APP/Frameworks/"
  fi
}

build_scheme AMFinance
stash_host_extras
if [ "${AM_BUILD_UI:-0}" = "1" ]; then
  build_scheme AMFinanceUITests
  restore_host_extras
fi

if [ ! -d "$HOST_APP/PlugIns/AMFinanceTests.xctest" ]; then
  echo "build-for-testing: AMFinanceTests.xctest missing from the host app" >&2
  find "$DERIVED" -name 'AMFinanceTests.xctest' -print >&2 || true
  exit 1
fi
# Hosted unit tests load this from the app. build-for-testing usually copies
# it; a UI-scheme rebuild of the .app can drop it. Copy from the SDK if so.
inject_dest="$HOST_APP/Frameworks/libXCTestBundleInject.dylib"
if [ ! -f "$inject_dest" ] && [ -n "${DEVELOPER_DIR:-}" ]; then
  inject_src="$(find "$DEVELOPER_DIR/Platforms/iPhoneSimulator.platform" -name 'libXCTestBundleInject.dylib' 2>/dev/null | head -n 1 || true)"
  if [ -n "$inject_src" ]; then
    mkdir -p "$HOST_APP/Frameworks"
    cp "$inject_src" "$inject_dest"
    echo "build-for-testing: copied libXCTestBundleInject.dylib from ${inject_src}"
  fi
fi

if [ "${AM_BUILD_UI:-0}" = "1" ] && [ ! -d "$SIM_PRODUCTS/AMFinanceUITests-Runner.app/PlugIns/AMFinanceUITests.xctest" ]; then
  echo "build-for-testing: UI test runner missing" >&2
  find "$DERIVED" -name 'AMFinanceUITests*.xctest' -o -name 'AMFinanceUITests-Runner.app' -print >&2 || true
  exit 1
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
