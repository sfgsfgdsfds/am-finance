#!/bin/bash
# test-app.sh — regenerate the project, pick an available iPhone simulator and
# run `xcodebuild test` for scheme AMFinance with code signing disabled.
# Quiet on success; prints the failure log tail and exits non-zero on failure.
#
# Concurrent runs from different worktrees auto-pick the same iPhone simulator
# and install the same bundle id, killing each other's test host — so device
# pick + xcodebuild are serialized through a machine-wide lock (lockf on a
# file in the shared tools cache, waits up to 30 minutes). A transient
# simulator failure — "before establishing connection", failed boot/launch —
# is retried once, on a re-booted device or another iPhone if one is free.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

if [ "${AMFINANCE_TEST_IN_LOCK:-0}" != "1" ]; then
  "$ROOT/scripts/gen.sh" >&2

  LOCK_BASE="${AMFINANCE_TOOLS_DIR:-$HOME/Library/Caches/amfinance-tools}"
  mkdir -p "$LOCK_BASE" 2>/dev/null || LOCK_BASE="${TMPDIR:-/tmp}/amfinance-tools"
  LOCK_FILE="${LOCK_BASE%/}/app-test.lock"
  touch "$LOCK_FILE"

  if AMFINANCE_TEST_IN_LOCK=1 /usr/bin/lockf -t 1800 "$LOCK_FILE" \
    "$ROOT/scripts/test-app.sh"; then
    exit 0
  else
    status=$?
    if [ "$status" -eq 75 ]; then
      echo "test-app: timed out waiting 30m for another app-test run to finish" >&2
    fi
    exit "$status"
  fi
fi

pick_device() { # $1: udid to exclude (optional)
  xcrun simctl list devices available -j | python3 -c '
import json, sys
exclude = sys.argv[1] or None
try:
    data = json.load(sys.stdin)
except Exception:
    sys.exit(1)
first = None
for runtime, devices in sorted(data.get("devices", {}).items(), reverse=True):
    if "iOS" not in runtime:
        continue
    for dev in devices:
        if not dev.get("isAvailable") or "iPhone" not in dev.get("name", ""):
            continue
        if first is None:
            first = dev["udid"]
        if dev["udid"] != exclude:
            print(dev["udid"])
            sys.exit(0)
if first is not None:
    print(first)  # only device is the excluded one — reuse it
    sys.exit(0)
sys.exit(1)
' "$1"
}

DEVICE_UDID="$(pick_device "")" || {
  echo "test-app: no available iPhone simulator found" >&2
  exit 1
}

echo "test-app: using iPhone simulator $DEVICE_UDID" >&2

LOG="$(mktemp -t amfinance-xcodebuild)"

# Transient runner/simulator failures worth one reboot-and-retry.
TRANSIENT_RE='before establishing connection|failed to boot|unable to boot|simulator failed to launch|failed to launch|could not be launched|timed out|lost connection|connection.*(interrupt|refused|reset|closed)|unable to connect|never finished bootstrapping|early unexpected exit|service delegate|failed to install|mach[ -]error|dtx|disconnect'

run_tests() {
  xcodebuild test \
    -project "$ROOT/AMFinance.xcodeproj" \
    -scheme AMFinance \
    -destination "platform=iOS Simulator,id=${DEVICE_UDID}" \
    -derivedDataPath "$ROOT/DerivedData" \
    CODE_SIGNING_ALLOWED=NO \
    >"$LOG" 2>&1
}

attempt=1
while true; do
  : >"$LOG"
  booted=1
  # -b boots the device if needed and blocks until it finishes booting.
  xcrun simctl bootstatus "$DEVICE_UDID" -b >>"$LOG" 2>&1 || booted=0

  if [ "$booted" -eq 1 ] && run_tests; then
    grep -E "Executed [0-9]+ tests?|Test run with [0-9]+ tests?|Test Suite .*(passed|failed)|TEST SUCCEEDED" "$LOG" | tail -n 15 || true
    echo "test-app: ** TEST SUCCEEDED ** (full log: $LOG)"
    exit 0
  else
    status=$?
  fi

  if [ "$attempt" -eq 1 ] &&
    { [ "$booted" -eq 0 ] || grep -qiE "$TRANSIENT_RE" "$LOG" 2>/dev/null; }; then
    echo "test-app: transient simulator failure — re-booting and retrying once" >&2
    xcrun simctl shutdown "$DEVICE_UDID" >/dev/null 2>&1 || true
    NEW_UDID="$(pick_device "$DEVICE_UDID" || true)"
    DEVICE_UDID="${NEW_UDID:-$DEVICE_UDID}"
    echo "test-app: retrying on iPhone simulator $DEVICE_UDID" >&2
    attempt=2
    continue
  fi

  echo "test-app: ** TEST FAILED ** — last 60 lines of $LOG:" >&2
  tail -n 60 "$LOG" >&2
  exit "$status"
done
