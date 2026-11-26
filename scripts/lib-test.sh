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
# Optional:
#   AM_TEST_PRODUCTS  build-for-testing Products directory. When set, run
#                     test-without-building against that scheme's .xctestrun
#                     instead of compiling again.
# then call `am_test_lock <script-path>` and `am_test_run <extra xcodebuild args>`.

: "${ROOT:?set ROOT before sourcing lib-test.sh}"
: "${AM_TEST_NAME:?set AM_TEST_NAME before sourcing lib-test.sh}"
: "${AM_TEST_SCHEME:?set AM_TEST_SCHEME before sourcing lib-test.sh}"

# Transient runner/simulator failures worth one reboot-and-retry.
# "test runner crashed" / handleStalledWait: the UI runner sometimes dies
# while the simulator is still coming up on a fresh GitHub-hosted image.
# One reboot-and-retry clears it. Do not match the Apple TV
# "native architecture is nil" warnings — those show up on green runs too.
AM_TRANSIENT_RE='before establishing connection|failed to boot|unable to boot|simulator failed to launch|failed to launch|could not be launched|does not have a process ID|timed out|lost connection|connection.*(interrupt|refused|reset|closed)|unable to connect|never finished bootstrapping|early unexpected exit|service delegate|failed to install|mach[ -]error|dtx|disconnect|test runner crashed|handleStalledWait'

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

# Newest plain iOS runtime, then a normal iPhone. GitHub's xcode-27 image also
# ships a device-specific seed runtime (iOS-27-2-iPhone19-4) whose only phone
# is "iPhone Duo"; string-sorting runtimes picks that first and the smoke
# tests miss rows that fit on a normal phone. Skip that runtime and Duo/SE.
_pick_device() { # $1: udid to exclude (optional)
  xcrun simctl list devices available -j | python3 -c '
import json, re, sys
exclude = sys.argv[1] or None
try:
    data = json.load(sys.stdin)
except Exception:
    sys.exit(1)

def plain_ios(runtime):
    # ...SimRuntime.iOS-27-2 or iOS-27-2-1. Reject iOS-27-2-iPhone19-4.
    m = re.search(r"iOS-(\d+(?:-\d+){0,2})$", runtime)
    if not m:
        return None
    return tuple(int(p) for p in m.group(1).split("-"))

def name_score(name):
    if "Duo" in name or "SE" in name:
        return -1
    if re.fullmatch(r"iPhone \d+ Pro Max", name):
        return 30
    if re.fullmatch(r"iPhone \d+ Pro", name):
        return 20
    if re.fullmatch(r"iPhone \d+", name):
        return 10
    if "iPhone" in name:
        return 0
    return -1

preferred = []
fallback = []
for runtime, devices in data.get("devices", {}).items():
    if "iOS" not in runtime:
        continue
    version = plain_ios(runtime)
    for dev in devices:
        if not dev.get("isAvailable") or "iPhone" not in dev.get("name", ""):
            continue
        udid = dev["udid"]
        name = dev.get("name", "")
        fallback.append((udid, name, runtime))
        score = name_score(name)
        if version is None or score < 0 or udid == exclude:
            continue
        preferred.append((version, score, name, udid, runtime))

if preferred:
    preferred.sort(reverse=True)
    version, score, name, udid, runtime = preferred[0]
    sys.stderr.write("pick %s on %s\n" % (name, runtime))
    print(udid)
    sys.exit(0)
for udid, name, runtime in fallback:
    if udid != exclude:
        sys.stderr.write("pick fallback %s on %s\n" % (name, runtime))
        print(udid)
        sys.exit(0)
if fallback:
    print(fallback[0][0])
    sys.exit(0)
sys.exit(1)
' "$1"
}

_xcodebuild_test() { # $1: device udid, $2: log file, $3: result bundle, rest: extra args
  local udid="$1" log="$2" results="$3"
  shift 3
  local -a cmd
  # test-without-building reads products from the xctestrun. A fresh
  # derived-data path would make xcodebuild look for binaries that were
  # never built there, so only the compile path passes -derivedDataPath.
  if [ -n "${AM_XCTESTRUN:-}" ]; then
    cmd=(xcodebuild test-without-building -xctestrun "$AM_XCTESTRUN")
  else
    cmd=(
      xcodebuild test
      -project "$ROOT/AMFinance.xcodeproj"
      -scheme "$AM_TEST_SCHEME"
      -derivedDataPath "$ROOT/DerivedData"
    )
  fi
  "${cmd[@]}" \
    -destination "platform=iOS Simulator,id=${udid}" \
    -destination-timeout 120 \
    -resultBundlePath "$results" \
    CODE_SIGNING_ALLOWED=NO \
    CODE_SIGNING_REQUIRED=NO \
    CODE_SIGN_IDENTITY= \
    "$@" \
    >"$log" 2>&1
}

# The unit scheme's file is named AMFinance_… and must not match
# AMFinanceUITests_….
_resolve_xctestrun() {
  if [ -n "${AM_XCTESTRUN:-}" ]; then
    return 0
  fi
  local dir="$AM_TEST_PRODUCTS" f base
  local -a matches=()
  if [ ! -d "$dir" ]; then
    echo "$AM_TEST_NAME: products dir missing: $dir" >&2
    exit 1
  fi
  while IFS= read -r f; do
    base="$(basename "$f")"
    case "$base" in
      "${AM_TEST_SCHEME}"_*|"${AM_TEST_SCHEME}.xctestrun") matches+=("$f") ;;
    esac
  done < <(find "$dir" -name '*.xctestrun' \( -type f -o -type d \))
  if [ "${#matches[@]}" -ne 1 ]; then
    echo "$AM_TEST_NAME: expected 1 xctestrun for ${AM_TEST_SCHEME}, found ${#matches[@]} under $dir" >&2
    find "$dir" -name '*.xctestrun' -print >&2 || true
    exit 1
  fi
  AM_XCTESTRUN="${matches[0]}"
}

_prepare_products() {
  if [ -z "${AM_TEST_PRODUCTS:-}" ]; then
    return 0
  fi
  python3 "$ROOT/scripts/ci-localize-products.py" "$AM_TEST_PRODUCTS"
  _resolve_xctestrun
  echo "$AM_TEST_NAME: test-without-building ${AM_XCTESTRUN}" >&2
}

# Best-effort per-test durations. Never fails the run.
_report_durations() { # $1 xcresult
  local bundle="$1" json
  if [ ! -e "$bundle" ]; then
    return 0
  fi
  json="$(mktemp -t amfinance-xcresult)"
  if ! xcrun xcresulttool get test-results tests --path "$bundle" --format json >"$json" 2>"$json.err"; then
    if ! xcrun xcresulttool get test-results tests --path "$bundle" >"$json" 2>>"$json.err"; then
      echo "$AM_TEST_NAME: xcresulttool could not read durations" >&2
      return 0
    fi
  fi
  python3 - "$json" <<'PY' || true
import json, sys
try:
    data = json.load(open(sys.argv[1]))
except Exception as exc:
    print("ci-durations: unreadable json (%s)" % exc)
    raise SystemExit(0)
found = []
def walk(node):
    if isinstance(node, dict):
        name = node.get("name") or ""
        ntype = str(node.get("nodeType") or "")
        dur = node.get("durationInSeconds")
        if dur is None and isinstance(node.get("duration"), (int, float)):
            dur = node.get("duration")
        children = node.get("children")
        is_case = "case" in ntype.lower() or (
            isinstance(name, str) and name.startswith("test") and not children
        )
        if is_case and isinstance(name, str) and isinstance(dur, (int, float)):
            found.append((float(dur), name))
        for value in node.values():
            walk(value)
    elif isinstance(node, list):
        for value in node:
            walk(value)
walk(data)
uniq = []
seen = set()
for item in found:
    if item in seen:
        continue
    seen.add(item)
    uniq.append(item)
uniq.sort(reverse=True)
print("ci-durations: %d test(s)" % len(uniq))
for dur, name in uniq[:40]:
    print("  %8.2fs  %s" % (dur, name))
if len(uniq) > 40:
    print("  ... %d more" % (len(uniq) - 40))
PY
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
  local device_udid new_udid log booted status attempt results
  _prepare_products
  device_udid="$(_pick_device "")" || {
    echo "$AM_TEST_NAME: no available iPhone simulator found" >&2
    exit 1
  }

  echo "$AM_TEST_NAME: using iPhone simulator $device_udid" >&2

  log="$(mktemp -t amfinance-xcodebuild)"
  mkdir -p "$ROOT/build"
  attempt=1
  while true; do
    : >"$log"
    booted=1
    # -b boots the device if needed and blocks until it finishes booting.
    xcrun simctl bootstatus "$device_udid" -b >>"$log" 2>&1 || booted=0

    results="$ROOT/build/TestResults-${AM_TEST_NAME}-attempt${attempt}.xcresult"
    rm -rf "$results"
    if [ "$booted" -eq 1 ] && _xcodebuild_test "$device_udid" "$log" "$results" "$@"; then
      grep -E "Executed [0-9]+ tests?|Test run with [0-9]+ tests?|Test Suite .*(passed|failed)|TEST SUCCEEDED" "$log" | tail -n 15 || true
      _report_durations "$results" || true
      if ! grep -qE "Test run with [1-9][0-9]* tests|Executed [1-9][0-9]* tests" "$log"; then
        echo "$AM_TEST_NAME: ** TEST FAILED ** (xcodebuild succeeded but executed 0 tests)" >&2
        exit 1
      fi
      echo "$AM_TEST_NAME: ** TEST SUCCEEDED ** (full log: $log)"
      exit 0
    else
      status=$?
    fi

    if [ "$attempt" -eq 1 ] &&
      { [ "$booted" -eq 0 ] || grep -qiE "$AM_TRANSIENT_RE" "$log" 2>/dev/null; }; then
      echo "$AM_TEST_NAME: transient simulator failure — re-booting and retrying once" >&2
      echo "$AM_TEST_NAME: transient match:" >&2
      grep -niE "$AM_TRANSIENT_RE" "$log" 2>/dev/null | head -n 20 >&2 || true
      echo "$AM_TEST_NAME: last 40 lines of the failed attempt:" >&2
      tail -n 40 "$log" >&2 || true
      xcrun simctl shutdown "$device_udid" >/dev/null 2>&1 || true
      new_udid="$(_pick_device "$device_udid" || true)"
      device_udid="${new_udid:-$device_udid}"
      echo "$AM_TEST_NAME: retrying on iPhone simulator $device_udid" >&2
      attempt=2
      continue
    fi

    echo "$AM_TEST_NAME: ** TEST FAILED **" >&2
    _print_failures "$log" >&2
    _report_durations "$results" || true
    echo "$AM_TEST_NAME: last 60 lines of $log:" >&2
    tail -n 60 "$log" >&2
    exit "$status"
  done
}
