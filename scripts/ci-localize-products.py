#!/usr/bin/env python3
"""Point .xctestrun files at this machine's Products directory.

ci-build-for-testing.sh writes products-prefix.txt with the absolute Products
path from the build runner. GitHub workspace paths usually match
(/Users/runner/work/am-finance/am-finance) and this is a no-op. When they
don't, only that prefix is rewritten inside the test-plan plists — the
binaries are still the ones this run compiled. __TESTROOT__ tokens are left
alone. A stale cache cannot sneak in here: the artifact comes from the same
workflow run.
"""
import os
import subprocess
import sys
from pathlib import Path


def xctestrun_files(products: Path):
    found = []
    for path in products.rglob("*"):
        if path.name.endswith(".xctestrun") and path.is_file():
            found.append(path)
        elif path.is_dir() and path.name.endswith(".xctestrun"):
            for child in path.rglob("*"):
                if child.is_file() and child.suffix in {".plist", ".xml", ".xctestrun"}:
                    found.append(child)
    return found


def to_xml(path: Path) -> str:
    return subprocess.check_output(
        ["plutil", "-convert", "xml1", "-o", "-", str(path)],
        text=True,
    )


def main() -> int:
    if len(sys.argv) != 2:
        print("usage: ci-localize-products.py <products-dir>", file=sys.stderr)
        return 2
    # Keep the path the caller passed. resolve() would follow /tmp → /private/tmp
    # (or a runner symlink) and rewrite the xctestrun to a path the download
    # did not use.
    products = Path(os.path.abspath(sys.argv[1]))
    prefix_file = products / "products-prefix.txt"
    if not prefix_file.is_file():
        print(f"ci-localize: no {prefix_file.name}; assuming portable paths", file=sys.stderr)
        return 0
    old = prefix_file.read_text().strip()
    new = str(products)
    runs = xctestrun_files(products)
    if not runs:
        print(f"ci-localize: no .xctestrun under {products}", file=sys.stderr)
        return 1
    if old == new:
        print(f"ci-localize: {len(runs)} xctestrun path(s) already local", file=sys.stderr)
        return 0
    for run in runs:
        text = to_xml(run)
        count = text.count(old)
        if count:
            text = text.replace(old, new)
            run.write_text(text)
        print(f"ci-localize: {run.name} replaced {count} path(s)", file=sys.stderr)
    prefix_file.write_text(new + "\n")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
