#!/bin/bash
# bootstrap.sh — make a pinned XcodeGen release binary available without Homebrew.
#
# Downloads the official release zip from github.com/yonaskolb/XcodeGen/releases
# into a per-user cache shared by all git worktrees. Prints the absolute path of
# the xcodegen binary on stdout; all diagnostics go to stderr. Idempotent.
#
# Env:
#   AMFINANCE_TOOLS_DIR — override the tools cache root
#                         (default: ~/Library/Caches/amfinance-tools)
set -euo pipefail

XCODEGEN_VERSION="2.46.0"  # pinned; released 2026-07-16
ZIP_URL="https://github.com/yonaskolb/XcodeGen/releases/download/${XCODEGEN_VERSION}/xcodegen.zip"

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TOOLS_ROOT="${AMFINANCE_TOOLS_DIR:-$HOME/Library/Caches/amfinance-tools}"
PRIMARY_DIR="${TOOLS_ROOT%/}/xcodegen-${XCODEGEN_VERSION}"
FALLBACK_DIR="${ROOT}/.tools/xcodegen-${XCODEGEN_VERSION}"

dest_dir() {
  if mkdir -p "$PRIMARY_DIR" 2>/dev/null && [ -w "$PRIMARY_DIR" ]; then
    printf '%s' "$PRIMARY_DIR"
  else
    mkdir -p "$FALLBACK_DIR"
    printf '%s' "$FALLBACK_DIR"
  fi
}

DEST="$(dest_dir)"
BIN="${DEST}/xcodegen/bin/xcodegen"

if [ -x "$BIN" ]; then
  printf '%s\n' "$BIN"
  exit 0
fi

echo "bootstrap: downloading XcodeGen ${XCODEGEN_VERSION} -> ${DEST}" >&2
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

curl -fL --retry 2 --silent --show-error "$ZIP_URL" -o "$TMP/xcodegen.zip"
unzip -q "$TMP/xcodegen.zip" -d "$DEST"
chmod +x "$BIN"
xattr -dr com.apple.quarantine "$DEST" 2>/dev/null || true

if [ ! -x "$BIN" ]; then
  echo "bootstrap: expected binary not found at $BIN" >&2
  exit 1
fi

printf '%s\n' "$BIN"
