#!/usr/bin/env python3
"""Checks Package.resolved against scripts/dependency-allowlist.txt and requires exact pins.

Fails when a dependency is not on the allowlist (supply-chain review needed) or when a pin has no version or
revision. Runs anywhere with Python 3, no Swift toolchain needed.
"""
import json
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
RESOLVED = ROOT / "Packages/TildeKit/Package.resolved"
ALLOWLIST = ROOT / "scripts/dependency-allowlist.txt"


def main() -> int:
    allowed = set()
    for line in ALLOWLIST.read_text().splitlines():
        line = line.split("#", 1)[0].strip()
        if line:
            allowed.add(line.lower())

    pins = json.loads(RESOLVED.read_text())["pins"]
    errors = []
    for pin in pins:
        identity = pin["identity"].lower()
        state = pin.get("state", {})
        if identity not in allowed:
            errors.append(f"{identity} ({pin['location']}) is not on the allowlist")
        if not (state.get("version") or state.get("revision")):
            errors.append(f"{identity} has no pinned version or revision")
    for name in sorted(allowed - {p["identity"].lower() for p in pins}):
        print(f"note: {name} is allowlisted but no longer resolved; remove it from the allowlist")

    for message in errors:
        print(f"error: {message}", file=sys.stderr)
    if not errors:
        print(f"dependencies ok ({len(pins)} pinned)")
    return 1 if errors else 0


if __name__ == "__main__":
    sys.exit(main())
