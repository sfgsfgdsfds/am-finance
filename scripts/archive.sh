#!/bin/bash
# archive.sh — build a Release archive of AMFinance for generic iOS and export
# an App Store Connect (TestFlight-ready) IPA locally. Nothing is uploaded.
#
# Steps:
#   1. regenerate AMFinance.xcodeproj via scripts/gen.sh (pinned XcodeGen)
#   2. `xcodebuild archive` for generic/platform=iOS into
#      build/AMFinance.xcarchive, overriding CURRENT_PROJECT_VERSION with a
#      timestamp build number yyyyMMddHHmm (env override: AM_BUILD_NUMBER)
#   3. `xcodebuild -exportArchive` with scripts/ExportOptions.plist
#      (method app-store-connect, automatic signing, destination export)
#      into build/export/
#
# Signing: the archive step signs with the development profile already on
# this machine (CODE_SIGN_STYLE Automatic, team T6Z3K9KBDB). The export step
# re-signs for distribution, which needs an Apple ID with access to the team
# signed in to Xcode — without one it fails with "No Accounts".
#
# Serialized with the test scripts through the shared machine-wide lock so a
# concurrent test-app.sh/test-ui.sh run can't regenerate the project or share
# DerivedData mid-build.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

AM_TEST_NAME="archive"
AM_TEST_SCHEME="AMFinance" # required by lib-test.sh; only the lock is used
source "$ROOT/scripts/lib-test.sh"
am_test_lock "$ROOT/scripts/archive.sh" # regenerates the project, then locks

BUILD_DIR="$ROOT/build"
ARCHIVE_PATH="$BUILD_DIR/AMFinance.xcarchive"
EXPORT_DIR="$BUILD_DIR/export"
EXPORT_OPTIONS="$ROOT/scripts/ExportOptions.plist"
BUILD_NUMBER="${AM_BUILD_NUMBER:-$(date +%Y%m%d%H%M)}"

[ -f "$EXPORT_OPTIONS" ] || { echo "archive: error: missing $EXPORT_OPTIONS" >&2; exit 1; }

mkdir -p "$BUILD_DIR"

# Print a focused diagnosis for signing failures. $1: xcodebuild log file.
print_signing_hints() {
  grep -iE "error:|No Accounts|provisioning profile|development team|requires a provisioning profile|doesn't support|No profiles for|signing certificate" "$1" 2>/dev/null \
    | sed -E 's/^[[:space:]]+//' | sort -u | tail -n 30 >&2 || true
  if grep -qiE "No Accounts|no account|add a new account" "$1" 2>/dev/null; then
    echo "archive: no Apple ID is signed in to Xcode — open Xcode → Settings →" >&2
    echo "archive: Accounts and sign in with an Apple ID on team T6Z3K9KBDB." >&2
  elif grep -qiE "provisioning profile|No profiles for" "$1" 2>/dev/null; then
    echo "archive: provisioning profile problem — check that the signed-in" >&2
    echo "archive: Apple ID can manage signing for vn.amx.finance (team T6Z3K9KBDB)." >&2
  fi
}

# Release still typechecks `#Preview` bodies, but the stubs they use
# (AppLockPreviewAuthenticator, WalletSyncPreviewAPI) are `#if DEBUG`-gated,
# so a plain Release compile fails. Expose DEBUG for the archive: the only
# DEBUG-gated code in the app is those two preview stubs, dead code in the
# shipped binary. Proper fix is guarding the `#Preview` blocks or ungating
# the stubs — App/ sources are out of scope here.
ARCHIVE_SWIFT_FLAGS="SWIFT_ACTIVE_COMPILATION_CONDITIONS=DEBUG"

echo "archive: archiving AMFinance — Release, generic iOS, build $BUILD_NUMBER"
ARCHIVE_LOG="$(mktemp -t amfinance-archive)"
if xcodebuild archive \
    -project "$ROOT/AMFinance.xcodeproj" \
    -scheme AMFinance \
    -configuration Release \
    -destination "generic/platform=iOS" \
    -archivePath "$ARCHIVE_PATH" \
    -derivedDataPath "$ROOT/DerivedData" \
    -allowProvisioningUpdates \
    CURRENT_PROJECT_VERSION="$BUILD_NUMBER" \
    $ARCHIVE_SWIFT_FLAGS \
    >"$ARCHIVE_LOG" 2>&1; then
  echo "archive: archive succeeded -> $ARCHIVE_PATH"
else
  status=$?
  echo "archive: ** ARCHIVE FAILED ** (log: $ARCHIVE_LOG)" >&2
  print_signing_hints "$ARCHIVE_LOG"
  exit "$status"
fi

echo "archive: exporting App Store Connect IPA -> $EXPORT_DIR"
EXPORT_LOG="$(mktemp -t amfinance-export)"
if xcodebuild -exportArchive \
    -archivePath "$ARCHIVE_PATH" \
    -exportPath "$EXPORT_DIR" \
    -exportOptionsPlist "$EXPORT_OPTIONS" \
    -allowProvisioningUpdates \
    >"$EXPORT_LOG" 2>&1; then
  echo "archive: export succeeded -> $EXPORT_DIR"
  ls -la "$EXPORT_DIR"
else
  status=$?
  echo "archive: ** EXPORT FAILED ** (log: $EXPORT_LOG)" >&2
  print_signing_hints "$EXPORT_LOG"
  exit "$status"
fi
