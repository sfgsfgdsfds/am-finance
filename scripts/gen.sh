#!/bin/bash
# gen.sh — bootstrap XcodeGen and regenerate AMFinance.xcodeproj from project.yml.
# The generated project is a build artifact: git-ignored, never committed.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
XCODEGEN="$("$ROOT/scripts/bootstrap.sh")"
"$XCODEGEN" generate --spec "$ROOT/project.yml" --project "$ROOT"
