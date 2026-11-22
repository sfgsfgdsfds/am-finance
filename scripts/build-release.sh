#!/bin/bash
# build-release.sh — compile the AMFinance app target in Release configuration
# for the iOS Simulator, code signing disabled. Catches what the Debug-only
# test gates miss (e.g. `#if DEBUG`-gated symbols referenced from `#Preview`
# bodies, which Release still typechecks).
#
# Regenerates the project via scripts/gen.sh, then `xcodebuild build` for
# generic/platform=iOS Simulator into its own derived-data folder
# (build/DerivedData-release/, already git-ignored via build/) so it never
# collides with the test/archive builds and needs no shared lock. Build
# only — no tests, no archive, no export.
# Quiet on success; prints the first compiler errors and exits non-zero on
# failure.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

DERIVED_DATA="$ROOT/build/DerivedData-release"
mkdir -p "$DERIVED_DATA"

"$ROOT/scripts/gen.sh"

echo "build-release: building AMFinance — Release, generic iOS Simulator"
BUILD_LOG="$(mktemp -t amfinance-build-release)"
if xcodebuild build \
    -project "$ROOT/AMFinance.xcodeproj" \
    -scheme AMFinance \
    -configuration Release \
    -destination "generic/platform=iOS Simulator" \
    -derivedDataPath "$DERIVED_DATA" \
    CODE_SIGNING_ALLOWED=NO \
    >"$BUILD_LOG" 2>&1; then
  echo "build-release: ** BUILD SUCCEEDED **"
else
  status=$?
  echo "build-release: ** BUILD FAILED ** (log: $BUILD_LOG)" >&2
  grep -E ": error: |error: " "$BUILD_LOG" 2>/dev/null \
    | sed -E 's/^[[:space:]]+//' | sort -u | head -n 30 >&2 || true
  exit "$status"
fi
