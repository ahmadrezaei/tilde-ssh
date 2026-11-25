#!/usr/bin/env python3
"""Derives the iOS "tinted" app icon from the default 1024 px icon.

The default icon (`icon-ios-1024.png`) is already dark, so iOS uses it for the dark appearance as well. The
tinted appearance wants a grayscale image on a dark background: the system maps its luminosity onto the user's
tint color. This script converts the default icon to grayscale and stretches the levels so the glyph reaches
near-white and the background stays near-black.

Usage: scripts/make-icon-variants.py            (needs Pillow: pip3 install pillow)
"""
from pathlib import Path

from PIL import Image, ImageOps

ICONSET = Path(__file__).resolve().parent.parent / "App/Resources/Assets.xcassets/AppIcon.appiconset"


def main() -> None:
    source = Image.open(ICONSET / "icon-ios-1024.png").convert("RGB")
    gray = ImageOps.grayscale(source)
    # Keep the dark end where it is, lift the mint glyph (luminance ~0.75) to white.
    lut = [min(255, int(max(0, v - 8) * 1.38)) for v in range(256)]
    tinted = gray.point(lut).convert("RGB")
    out = ICONSET / "icon-ios-1024-tinted.png"
    tinted.save(out, optimize=True)
    print(f"wrote {out.relative_to(ICONSET.parent.parent.parent.parent)}")


if __name__ == "__main__":
    main()
