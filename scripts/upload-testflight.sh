#!/bin/bash
# upload-testflight.sh — upload the archived AMFinance build to App Store
# Connect (TestFlight) using the Apple ID signed in to Xcode. No API keys,
# certificates or passwords are stored in this repo.
#
# Re-exports build/AMFinance.xcarchive with destination "upload" (same
# scripts/ExportOptions.plist as archive.sh, destination flipped), which
# validates the IPA and uploads it with the Xcode account's credentials.
#
# Refuses to run unless called as:  scripts/upload-testflight.sh --yes-upload
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

BUILD_DIR="$ROOT/build"
ARCHIVE_PATH="$BUILD_DIR/AMFinance.xcarchive"
UPLOAD_DIR="$BUILD_DIR/upload"
UPLOAD_PLIST="$BUILD_DIR/ExportOptions-upload.plist"

print_prereqs() {
  cat >&2 <<'EOF'
Prerequisites for a TestFlight upload:
  1. An app record for bundle id vn.amx.finance exists in App Store Connect
     (Apps → AM Finance). Create it first if missing.
  2. An Apple ID with access to team T6Z3K9KBDB is signed in to Xcode
     (Xcode → Settings → Accounts).
  3. build/AMFinance.xcarchive exists — run scripts/archive.sh first.
EOF
}

if [ "${1:-}" != "--yes-upload" ]; then
  echo "upload: refusing to upload — this ships a real build to Apple." >&2
  print_prereqs
  echo "usage: $0 --yes-upload" >&2
  exit 2
fi

if [ ! -d "$ARCHIVE_PATH" ]; then
  echo "upload: error: $ARCHIVE_PATH not found — run scripts/archive.sh first." >&2
  exit 1
fi

mkdir -p "$BUILD_DIR"
cp "$ROOT/scripts/ExportOptions.plist" "$UPLOAD_PLIST"
/usr/libexec/PlistBuddy -c "Set :destination upload" "$UPLOAD_PLIST"

print_prereqs

echo "upload: exporting + uploading $ARCHIVE_PATH to App Store Connect"
UPLOAD_LOG="$(mktemp -t amfinance-upload)"
if xcodebuild -exportArchive \
    -archivePath "$ARCHIVE_PATH" \
    -exportPath "$UPLOAD_DIR" \
    -exportOptionsPlist "$UPLOAD_PLIST" \
    -allowProvisioningUpdates \
    >"$UPLOAD_LOG" 2>&1; then
  echo "upload: ** UPLOAD SUCCEEDED ** — the build will appear in App Store"
  echo "upload: Connect → TestFlight once Apple finishes processing it."
else
  status=$?
  echo "upload: ** UPLOAD FAILED ** (log: $UPLOAD_LOG)" >&2
  grep -iE "error:|No Accounts|provisioning profile|app record|No suitable application|authentication|unauthorized" "$UPLOAD_LOG" 2>/dev/null \
    | sed -E 's/^[[:space:]]+//' | sort -u | tail -n 30 >&2 || true
  print_prereqs
  exit "$status"
fi
