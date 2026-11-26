#!/bin/bash
# ci-select-xcode.sh — on a GitHub-hosted macOS runner, select the highest
# /Applications/Xcode_*.app (a release beats a beta of the same version) and
# print xcodebuild -version plus the installed iOS runtimes.
# Not used on the owner's Mac.
set -euo pipefail

export PYTHONDONTWRITEBYTECODE=1

selected="$(python3 -B - <<'PY'
import re
from pathlib import Path

apps = list(Path("/Applications").glob("Xcode_*.app"))
if not apps:
    raise SystemExit("no /Applications/Xcode_*.app")

def sort_key(path):
    ver = path.name[:-4].split("_", 1)[1]
    parts = []
    for tok in re.split(r"[._]", ver):
        if tok.isdigit():
            parts.append((0, int(tok)))
        else:
            parts.append((1, tok.lower()))
    beta = 1 if re.search(r"beta|rc", path.name, re.I) else 0
    # Higher version wins; a release beats a beta of the same version.
    return (parts, 0 if beta else 1)

best = {}
for path in apps:
    try:
        resolved = path.resolve()
    except OSError:
        continue
    key = sort_key(path)
    if resolved not in best or key > best[resolved][0]:
        best[resolved] = (key, str(resolved))
if not best:
    raise SystemExit("no usable Xcode_*.app")
print(max(best.values(), key=lambda item: item[0])[1])
PY
)"

if [ ! -d "${selected}/Contents/Developer" ]; then
  echo "selected Xcode has no Contents/Developer: ${selected}" >&2
  exit 1
fi

echo "selected ${selected}"
export DEVELOPER_DIR="${selected}/Contents/Developer"
sudo xcode-select -s "$DEVELOPER_DIR"
if [ -n "${GITHUB_ENV:-}" ]; then
  echo "DEVELOPER_DIR=${DEVELOPER_DIR}" >> "$GITHUB_ENV"
fi
sudo xcodebuild -license accept || true
xcodebuild -version
xcode_ver="$(xcodebuild -version | awk 'NR==1 { print $2; exit }')"
if [ -n "${GITHUB_ENV:-}" ]; then
  # Used as the explicit-module cache key. SDK modules are content-addressed,
  # so a cache from an older tree cannot produce a wrong binary.
  echo "XCODE_VERSION=${xcode_ver}" >> "$GITHUB_ENV"
fi
echo "--- iOS runtimes ---"
xcrun simctl list runtimes