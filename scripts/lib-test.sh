#!/bin/bash
# lib-test.sh — shared machinery for scripts/test-app.sh and scripts/test-ui.sh:
# the machine-wide cross-worktree lock, iPhone simulator auto-pick and the
# boot → `xcodebuild test` → transient-retry loop.
#
# Concurrent runs from different worktrees auto-pick the same iPhone simulator
# and install the same bundle id, killing each other's test host — so device
# pick + xcodebuild are serialized through a machine-wide lock (lockf on a
# file in the shared tools cache, waits up to 30 minutes). A transient
# simulator failure — "before establishing connection", failed boot/launch —
# is retried once, on a re-booted device or another iPhone if one is free.
#
# Sourced, not executed. The caller must first set:
#   ROOT            absolute project root
#   AM_TEST_NAME    log prefix ("test-app", "test-ui")
#   AM_TEST_SCHEME  Xcode scheme to test (each scheme holds exactly one test
#                   bundle, so nothing extra is built — see project.yml)
# then call `am_test_lock <script-path>` and `am_test_run <extra xcodebuild args>`.

: "${ROOT:?set ROOT before sourcing lib-test.sh}"
: "${AM_TEST_NAME:?set AM_TEST_NAME before sourcing lib-test.sh}"
: "${AM_TEST_SCHEME:?set AM_TEST_SCHEME before sourcing lib-test.sh}"

# Transient runner/simulator failures worth one reboot-and-retry.
AM_TRANSIENT_RE='before establishing connection|failed to boot|unable to boot|simulator failed to launch|failed to launch|could not be launched|timed out|lost connection|connection.*(interrupt|refused|reset|closed)|unable to connect|never finished bootstrapping|early unexpected exit|service delegate|failed to install|mach[ -]error|dtx|disconnect'

# Regenerate the project, then re-run the calling script under the
# machine-wide lock. $1: absolute path of the script to re-exec. Only returns
# when already inside the lock; otherwise exits with the inner exit status.
am_test_lock() {
  if [ "${AMFINANCE_TEST_IN_LOCK:-0}" = "1" ]; then
    return 0
  fi
  "$ROOT/scripts/gen.sh" >&2

  local lock_base="${AMFINANCE_TOOLS_DIR:-$HOME/Library/Caches/amfinance-tools}"
  mkdir -p "$lock_base" 2>/dev/null || lock_base="${TMPDIR:-/tmp}/amfinance-tools"
  local lock_file="${lock_base%/}/app-test.lock"
  touch "$lock_file"

  local status
  if AMFINANCE_TEST_IN_LOCK=1 /usr/bin/lockf -t 1800 "$lock_file" "$1"; then
    exit 0
  else
    status=$?
    if [ "$status" -eq 75 ]; then
      echo "$AM_TEST_NAME: timed out waiting 30m for another app-test run to finish" >&2
    fi
    exit "$status"
  fi
}

_pick_device() { # $1: udid to exclude (optional)
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

_xcodebuild_test() { # $1: device udid, $2: log file, rest: extra xcodebuild args
  local udid="$1" log="$2"
  shift 2
  xcodebuild test \
    -project "$ROOT/AMFinance.xcodeproj" \
    -scheme "$AM_TEST_SCHEME" \
    -destination "platform=iOS Simulator,id=${udid}" \
    -derivedDataPath "$ROOT/DerivedData" \
    CODE_SIGNING_ALLOWED=NO \
    "$@" \
    >"$log" 2>&1
}

# Echo the failing test names / errors found in the xcodebuild log. $1: log file.
_print_failures() {
  local out
  out="$(grep -E "Test Case '.*' (failed|timed out)|: error: |✘|✗|recorded an issue" "$1" 2>/dev/null \
    | sed -E 's/^[[:space:]]+//' | sort -u | tail -n 40)" || true
  if [ -n "$out" ]; then
    echo "$AM_TEST_NAME: failing tests / errors:"
    echo "$out"
  fi
}

# Pick a device, boot it and run `xcodebuild test "$@"` (extra args such as
# -only-testing:TARGET). Retries once on a transient simulator failure.
# Prints the test summary on success; failing test names + the log tail and
# exit non-zero on failure.
am_test_run() {
  local device_udid new_udid log booted status attempt
  device_udid="$(_pick_device "")" || {
    echo "$AM_TEST_NAME: no available iPhone simulator found" >&2
    exit 1
  }

  echo "$AM_TEST_NAME: using iPhone simulator $device_udid" >&2

  log="$(mktemp -t amfinance-xcodebuild)"
  attempt=1
  while true; do
    : >"$log"
    booted=1
    # -b boots the device if needed and blocks until it finishes booting.
    xcrun simctl bootstatus "$device_udid" -b >>"$log" 2>&1 || booted=0

    if [ "$booted" -eq 1 ] && _xcodebuild_test "$device_udid" "$log" "$@"; then
      grep -E "Executed [0-9]+ tests?|Test run with [0-9]+ tests?|Test Suite .*(passed|failed)|TEST SUCCEEDED" "$log" | tail -n 15 || true
      echo "$AM_TEST_NAME: ** TEST SUCCEEDED ** (full log: $log)"
      exit 0
    else
      status=$?
    fi

    if [ "$attempt" -eq 1 ] &&
      { [ "$booted" -eq 0 ] || grep -qiE "$AM_TRANSIENT_RE" "$log" 2>/dev/null; }; then
      echo "$AM_TEST_NAME: transient simulator failure — re-booting and retrying once" >&2
      xcrun simctl shutdown "$device_udid" >/dev/null 2>&1 || true
      new_udid="$(_pick_device "$device_udid" || true)"
      device_udid="${new_udid:-$device_udid}"
      echo "$AM_TEST_NAME: retrying on iPhone simulator $device_udid" >&2
      attempt=2
      continue
    fi

    echo "$AM_TEST_NAME: ** TEST FAILED **" >&2
    _print_failures "$log" >&2
    echo "$AM_TEST_NAME: last 60 lines of $log:" >&2
    tail -n 60 "$log" >&2
    exit "$status"
  done
}
