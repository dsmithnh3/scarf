#!/usr/bin/env python3
"""Generate Electric Cobalt gradient app icons for macOS and iOS asset catalogs."""
from __future__ import annotations

import json
import math
from pathlib import Path

try:
    from PIL import Image, ImageDraw
except ImportError:
    raise SystemExit("pip install Pillow required")

ROOT = Path(__file__).resolve().parents[1]

# Gradient stops: bright -> primary -> deep
STOPS = [
    (0.0, (0x7B, 0x9C, 0xFF)),
    (0.55, (0x2F, 0x5B, 0xEA)),
    (1.0, (0x12, 0x25, 0x6E)),
]


def lerp(a: float, b: float, t: float) -> float:
    return a + (b - a) * t


def sample_gradient(t: float) -> tuple[int, int, int]:
    t = max(0.0, min(1.0, t))
    for i in range(len(STOPS) - 1):
        t0, c0 = STOPS[i]
        t1, c1 = STOPS[i + 1]
        if t <= t1:
            if t1 == t0:
                return c1
            u = (t - t0) / (t1 - t0)
            return (
                int(lerp(c0[0], c1[0], u)),
                int(lerp(c0[1], c1[1], u)),
                int(lerp(c0[2], c1[2], u)),
            )
    return STOPS[-1][1]


def make_icon(size: int) -> Image.Image:
    img = Image.new("RGBA", (size, size), (0, 0, 0, 0))
    px = img.load()
    for y in range(size):
        for x in range(size):
            # topLeading -> bottomTrailing like ScarfGradient.brand
            t = (x + y) / (2 * (size - 1)) if size > 1 else 0
            r, g, b = sample_gradient(t)
            px[x, y] = (r, g, b, 255)

    # macOS-style continuous rounded rect mask (~22% radius)
    mask = Image.new("L", (size, size), 0)
    draw = ImageDraw.Draw(mask)
    radius = int(size * 0.223)
    draw.rounded_rectangle((0, 0, size - 1, size - 1), radius=radius, fill=255)
    img.putalpha(mask)
    return img


def export_catalog(catalog: Path) -> None:
    contents = json.loads((catalog / "Contents.json").read_text())
    for entry in contents.get("images", []):
        filename = entry.get("filename")
        if not filename:
            continue
        size_str = entry.get("size", "512x512")
        base = int(float(size_str.split("x")[0]))
        scale = entry.get("scale", "1x")
        mult = int(scale.replace("x", "")) if scale.endswith("x") else 1
        px = base * mult
        icon = make_icon(px)
        out = catalog / filename
        icon.save(out, "PNG")
        print("Wrote", out.relative_to(ROOT), px)


def main() -> None:
    master = 1024
    master_path = ROOT / "icon-v2.5.png"
    make_icon(master).save(master_path, "PNG")
    print("Wrote", master_path)

    export_catalog(ROOT / "scarf/scarf/Assets.xcassets/AppIcon.appiconset")
    export_catalog(ROOT / "scarf/Scarf iOS/Assets.xcassets/AppIcon.appiconset")


if __name__ == "__main__":
    main()
