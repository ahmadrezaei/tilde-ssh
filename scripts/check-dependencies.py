#!/usr/bin/env python3
"""Checks Package.resolved against scripts/dependency-allowlist.txt and requires exact pins.

A dependency passes only if both its SwiftPM identity and its repository URL are on the allowlist, and it is pinned to
a version or revision. Runs anywhere with Python 3, no Swift toolchain needed.
"""
import json
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
RESOLVED = ROOT / "Packages/TildeKit/Package.resolved"
ALLOWLIST = ROOT / "scripts/dependency-allowlist.txt"


def normalise(url: str) -> str:
    url = url.strip().lower().rstrip("/")
    if url.endswith(".git"):
        url = url[: -len(".git")]
    return url.rstrip("/")


def main() -> int:
    allowed: dict[str, str] = {}
    for number, line in enumerate(ALLOWLIST.read_text().splitlines(), 1):
        line = line.split("#", 1)[0].strip()
        if not line:
            continue
        parts = line.split()
        if len(parts) != 2:
            print(f"error: {ALLOWLIST.name}:{number}: expected '<identity> <url>'", file=sys.stderr)
            return 1
        allowed[parts[0].lower()] = normalise(parts[1])

    pins = json.loads(RESOLVED.read_text())["pins"]
    errors = []
    for pin in pins:
        identity = pin["identity"].lower()
        location = normalise(pin["location"])
        state = pin.get("state", {})
        if identity not in allowed:
            errors.append(f"{identity} ({pin['location']}) is not on the allowlist")
        elif allowed[identity] != location:
            errors.append(f"{identity} resolves to {pin['location']}, allowlist says {allowed[identity]}")
        if not (state.get("version") or state.get("revision")):
            errors.append(f"{identity} has no pinned version or revision")
    for name in sorted(set(allowed) - {p["identity"].lower() for p in pins}):
        print(f"note: {name} is allowlisted but no longer resolved; remove it from the allowlist")

    for message in errors:
        print(f"error: {message}", file=sys.stderr)
    if not errors:
        print(f"dependencies ok ({len(pins)} pinned)")
    return 1 if errors else 0


if __name__ == "__main__":
    sys.exit(main())
