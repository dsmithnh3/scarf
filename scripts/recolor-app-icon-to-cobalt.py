#!/usr/bin/env python3
"""Recolor the orange Scarf app-icon artwork to Electric Cobalt blue.

Preserves the glass scarf mark (low-saturation highlights/shadows) and maps
warm/orange background + tinted folds onto the cobalt brand scale (~214°).
"""
from __future__ import annotations

import colorsys
import json
import math
from pathlib import Path

try:
    from PIL import Image
except ImportError as exc:
    raise SystemExit("Pillow required") from exc

ROOT = Path(__file__).resolve().parents[1]

# Source artwork (preserved orange scarf mark — never overwrite this file)
SOURCE = ROOT / "design/static-site/assets/scarf-app-icon-1024-orange-source.png"

# Brand anchors (light → deep), matching update-cobalt-colorsets.py
BRIGHT = (0x5B, 0x9F, 0xFF)
PRIMARY = (0x00, 0x66, 0xE8)
DEEP = (0x00, 0x2E, 0x6E)

# Hue window treated as "brand orange" to remap (degrees)
ORANGE_HUE_MIN = 5.0
ORANGE_HUE_MAX = 55.0
MIN_SAT_TO_RECOLOR = 0.12


def lerp(a: float, b: float, t: float) -> float:
    return a + (b - a) * t


def mix_rgb(t: float) -> tuple[float, float, float]:
    """Map normalized depth 0 (center/bright) → 1 (edge/deep) onto brand RGB."""
    t = max(0.0, min(1.0, t))
    if t < 0.55:
        u = t / 0.55
        return (
            lerp(BRIGHT[0], PRIMARY[0], u) / 255,
            lerp(BRIGHT[1], PRIMARY[1], u) / 255,
            lerp(BRIGHT[2], PRIMARY[2], u) / 255,
        )
    u = (t - 0.55) / 0.45
    return (
        lerp(PRIMARY[0], DEEP[0], u) / 255,
        lerp(PRIMARY[1], DEEP[1], u) / 255,
        lerp(PRIMARY[2], DEEP[2], u) / 255,
    )


def orange_depth(h_deg: float, s: float, v: float) -> float:
    """Estimate position in the old orange gradient from HSV."""
    # Deeper/darker orange → higher depth; bright center → lower.
    # Also nudge by hue (deeper rust is slightly redder / lower hue).
    hue_t = 1.0 - max(0.0, min(1.0, (h_deg - ORANGE_HUE_MIN) / (ORANGE_HUE_MAX - ORANGE_HUE_MIN)))
    return max(0.0, min(1.0, (1.0 - v) * 0.75 + hue_t * 0.15 + (1.0 - s) * 0.1))


def recolor(im: Image.Image) -> Image.Image:
    im = im.convert("RGBA")
    px = im.load()
    w, h = im.size
    for y in range(h):
        for x in range(w):
            r, g, b, a = px[x, y]
            if a == 0:
                continue
            rf, gf, bf = r / 255.0, g / 255.0, b / 255.0
            hue, sat, val = colorsys.rgb_to_hsv(rf, gf, bf)
            h_deg = hue * 360.0

            # Keep glassy white / grey scarf body (desaturated).
            if sat < MIN_SAT_TO_RECOLOR:
                continue
            if not (ORANGE_HUE_MIN <= h_deg <= ORANGE_HUE_MAX):
                continue

            depth = orange_depth(h_deg, sat, val)
            nr, ng, nb = mix_rgb(depth)
            # Preserve relative luminance variation inside the mapped band
            # so highlights in orange-tinted folds still read as highlights.
            lift = (val - 0.45) * 0.35
            nr = max(0.0, min(1.0, nr + lift))
            ng = max(0.0, min(1.0, ng + lift))
            nb = max(0.0, min(1.0, nb + lift * 0.85))
            # Keep saturation feel: blend mapped brand color with original value.
            nh, ns, nv = colorsys.rgb_to_hsv(nr, ng, nb)
            ns = max(ns, sat * 0.85)
            nv = max(0.0, min(1.0, val * 0.35 + nv * 0.65))
            nr, ng, nb = colorsys.hsv_to_rgb(nh, ns, nv)
            px[x, y] = (int(nr * 255), int(ng * 255), int(nb * 255), a)
    return im


def export_catalog(master: Image.Image, catalog: Path) -> None:
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
        out = catalog / filename
        master.resize((px, px), Image.Resampling.LANCZOS).save(out, "PNG")
        print("Wrote", out.relative_to(ROOT), px)


def main() -> None:
    if not SOURCE.is_file():
        raise SystemExit(f"missing source icon: {SOURCE}")

    master = recolor(Image.open(SOURCE))
    master_path = ROOT / "icon-v2.5.png"
    master.save(master_path, "PNG")
    print("Wrote", master_path.relative_to(ROOT))

    # Design / marketing mirrors
    for dest, size in [
        (ROOT / "design/static-site/assets/scarf-app-icon-1024.png", 1024),
        (ROOT / "design/static-site/assets/scarf-app-icon-512.png", 512),
        (ROOT / "design/static-site/assets/scarf-app-icon-256.png", 256),
        (ROOT / "design/static-site/assets/scarf-app-icon-128.png", 128),
        (ROOT / "design/static-site/assets/scarf-icon.png", 256),
        (ROOT / "site/landing/assets/scarf-icon-256.png", 256),
    ]:
        master.resize((size, size), Image.Resampling.LANCZOS).save(dest, "PNG")
        print("Wrote", dest.relative_to(ROOT), size)

    export_catalog(master, ROOT / "scarf/scarf/Assets.xcassets/AppIcon.appiconset")
    export_catalog(master, ROOT / "scarf/Scarf iOS/Assets.xcassets/AppIcon.appiconset")

    ios_master = ROOT / "design/Assets.xcassets/AppIcon-iOS.appiconset/Scarf-AppIcon-iOS-1024.png"
    if ios_master.parent.is_dir():
        master.save(ios_master, "PNG")
        print("Wrote", ios_master.relative_to(ROOT))


if __name__ == "__main__":
    main()
