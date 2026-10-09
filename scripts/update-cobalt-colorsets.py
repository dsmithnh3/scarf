#!/usr/bin/env python3
"""Write ScarfBrand colorset Contents.json for Electric Cobalt recolor."""
import json
from pathlib import Path

BASE = Path("scarf/Packages/ScarfDesign/Sources/ScarfDesign/ScarfBrand.xcassets")


def hex_rgb(h: str) -> tuple[float, float, float]:
    h = h.lstrip("#")
    r, g, b = int(h[0:2], 16), int(h[2:4], 16), int(h[4:6], 16)
    return r / 255, g / 255, b / 255


def colorset(light: str, dark: str) -> dict:
    lr, lg, lb = hex_rgb(light)
    dr, dg, db = hex_rgb(dark)

    def comp(r, g, b):
        return {
            "alpha": "1.000",
            "red": f"{r:.3f}",
            "green": f"{g:.3f}",
            "blue": f"{b:.3f}",
        }

    return {
        "colors": [
            {"color": {"color-space": "srgb", "components": comp(lr, lg, lb)}, "idiom": "universal"},
            {
                "appearances": [{"appearance": "luminosity", "value": "dark"}],
                "color": {"color-space": "srgb", "components": comp(dr, dg, db)},
                "idiom": "universal",
            },
        ],
        "info": {"author": "xcode", "version": 1},
    }


# Hue ~214° (classic cobalt / azure), not ~226° indigo which reads purple.
# Anchored near cobalt blue (#0047AB) but lifted for UI contrast.
PAIRS = {
    "Brand/BrandPrimary": ("0066E8", "5B9FFF"),
    "Brand/BrandHover": ("0056C7", "7AB0FF"),
    "Brand/BrandActive": ("00419A", "3D86F0"),
    "Brand/BrandDeep": ("002E6E", "00419A"),
    "Brand/BrandBright": ("5B9FFF", "7AB0FF"),
    "Brand/BrandSoftStart": ("E6F0FF", "121A2A"),
    "Brand/BrandSoftEnd": ("C2D8FF", "1C2E4D"),
    "Surface/BackgroundPrimary": ("F7F8FA", "0E1016"),
    "Surface/BackgroundSecondary": ("FFFFFF", "181B24"),
    "Surface/BackgroundTertiary": ("EEF0F4", "1E2230"),
    "Surface/Border": ("1A1D26", "E8ECF5"),
    "Surface/BorderStrong": ("1A1D26", "E8ECF5"),
    "Foreground/ForegroundPrimary": ("12141A", "E8ECF2"),
    "Foreground/ForegroundMuted": ("5C6370", "9AA3B2"),
    "Foreground/ForegroundFaint": ("8B919C", "6B7382"),
}

ACCENT = ("0066E8", "5B9FFF")


def main():
    root = Path(__file__).resolve().parents[1]
    for rel, (light, dark) in PAIRS.items():
        path = root / BASE / f"{rel}.colorset" / "Contents.json"
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_text(json.dumps(colorset(light, dark), indent=2) + "\n")

    for target in [
        root / "scarf/scarf/Assets.xcassets/AccentColor.colorset/Contents.json",
        root / "scarf/Scarf iOS/Assets.xcassets/AccentColor.colorset/Contents.json",
    ]:
        target.write_text(json.dumps(colorset(*ACCENT), indent=2) + "\n")

    print("Wrote", len(PAIRS), "colorsets + 2 AccentColor")


if __name__ == "__main__":
    main()
