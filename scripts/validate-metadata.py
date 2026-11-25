#!/usr/bin/env python3
"""Validates the App Store metadata in fastlane/metadata against Apple's limits.

Checks, per locale directory:
  - character limits (name 30, subtitle 30, keywords 100, promotional text 170, description 4000,
    release notes 4000), counted in Unicode characters as App Store Connect does
  - keywords: comma separated, no spaces after commas, no duplicates, nothing already in name or subtitle
  - URLs are https
  - no trailing newline in single-line fields (fastlane would upload it)

Usage: scripts/validate-metadata.py [--quiet]      Exit status 1 on any error.
"""
import re
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent / "fastlane" / "metadata"
LIMITS = {
    "name": 30,
    "subtitle": 30,
    "keywords": 100,
    "promotional_text": 170,
    "description": 4000,
    "release_notes": 4000,
}
SINGLE_LINE = {"name", "subtitle", "keywords", "promotional_text", "support_url", "marketing_url", "privacy_url"}
URLS = ("support_url", "marketing_url", "privacy_url")
STOPWORDS = {"for", "and", "the", "a", "an", "of", "to", "in", "on", "&", "–", "-"}


def words(text: str) -> set[str]:
    return {w for w in re.findall(r"[a-z0-9]+", text.lower()) if w not in STOPWORDS}


def main() -> int:
    quiet = "--quiet" in sys.argv
    errors: list[str] = []
    locales = sorted(p for p in ROOT.iterdir() if p.is_dir())
    if not locales:
        print(f"no locale directories in {ROOT}")
        return 1

    for locale in locales:
        fields: dict[str, str] = {}
        for name in [*LIMITS, *URLS]:
            path = locale / f"{name}.txt"
            if not path.exists():
                errors.append(f"{locale.name}/{name}.txt is missing")
                continue
            text = path.read_text(encoding="utf-8")
            fields[name] = text
            if name in SINGLE_LINE and ("\n" in text):
                errors.append(f"{locale.name}/{name}.txt must be a single line without a trailing newline")
            body = text.strip("\n") if name not in SINGLE_LINE else text
            if name in LIMITS:
                count = len(body)
                status = "ok" if count <= LIMITS[name] else "TOO LONG"
                if not quiet:
                    print(f"{locale.name:8} {name:17} {count:5} / {LIMITS[name]:<5} {status}")
                if count > LIMITS[name]:
                    errors.append(f"{locale.name}/{name}.txt is {count} characters (limit {LIMITS[name]})")

        keywords = fields.get("keywords", "")
        if keywords:
            if ", " in keywords or keywords != keywords.strip():
                errors.append("keywords: remove spaces around commas")
            terms = [k for k in keywords.split(",") if k]
            dupes = sorted({k for k in terms if terms.count(k) > 1})
            if dupes:
                errors.append(f"keywords: duplicate terms {dupes}")
            indexed = words(fields.get("name", "")) | words(fields.get("subtitle", ""))
            overlap = sorted(t for t in terms if t.lower() in indexed)
            if overlap:
                errors.append(f"keywords: already indexed through name/subtitle: {overlap}")
            if any(" " in t for t in terms):
                errors.append("keywords: multi-word terms waste characters; split them")

        for name in URLS:
            value = fields.get(name, "")
            if value and not re.fullmatch(r"https://[^\s/]+\.[^\s/]+(/\S*)?", value):
                errors.append(f"{locale.name}/{name}.txt is not an https URL: {value!r}")

    for message in errors:
        print(f"error: {message}", file=sys.stderr)
    if not errors and not quiet:
        print("metadata ok")
    return 1 if errors else 0


if __name__ == "__main__":
    sys.exit(main())
