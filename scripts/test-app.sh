#!/bin/bash
# test-app.sh — regenerate the project, pick an available iPhone simulator and
# run `xcodebuild test` for scheme AMFinance with code signing disabled.
# Quiet on success; prints the failure log tail and exits non-zero on failure.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

"$ROOT/scripts/gen.sh" >&2

DEVICE_UDID="$(xcrun simctl list devices available -j | python3 -c '
import json, sys
try:
    data = json.load(sys.stdin)
except Exception:
    sys.exit(1)
for runtime, devices in sorted(data.get("devices", {}).items(), reverse=True):
    if "iOS" not in runtime:
        continue
    for dev in devices:
        if dev.get("isAvailable") and "iPhone" in dev.get("name", ""):
            print(dev["udid"])
            sys.exit(0)
sys.exit(1)
')" || { echo "test-app: no available iPhone simulator found" >&2; exit 1; }

echo "test-app: using iPhone simulator $DEVICE_UDID" >&2

LOG="$(mktemp -t amfinance-xcodebuild)"
DEST="platform=iOS Simulator,id=${DEVICE_UDID}"

if xcodebuild test \
    -project "$ROOT/AMFinance.xcodeproj" \
    -scheme AMFinance \
    -destination "$DEST" \
    -derivedDataPath "$ROOT/DerivedData" \
    CODE_SIGNING_ALLOWED=NO \
    >"$LOG" 2>&1
then
  grep -E "Executed [0-9]+ tests?|Test run with [0-9]+ tests?|Test Suite .*(passed|failed)|TEST SUCCEEDED" "$LOG" | tail -n 15 || true
  echo "test-app: ** TEST SUCCEEDED ** (full log: $LOG)"
else
  status=$?
  echo "test-app: ** TEST FAILED ** — last 60 lines of $LOG:" >&2
  tail -n 60 "$LOG" >&2
  exit "$status"
fi
