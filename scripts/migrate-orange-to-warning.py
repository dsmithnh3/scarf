#!/usr/bin/env python3
"""Replace caution system .orange with ScarfColor.warning in Scarf Swift sources."""
import re
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1] / "scarf"

SKIP_PARTS = ("/Tests/", "scarfTests/", "Tests/")

REPLACEMENTS = [
    (r"AnyShapeStyle\(Color\.orange\)", "AnyShapeStyle(ScarfColor.warning)"),
    (r"Color\.orange\.opacity", "ScarfColor.warning.opacity"),
    (r"\.background\(\.orange", ".background(ScarfColor.warning"),
    (r"\.background\(Color\.orange", ".background(ScarfColor.warning"),
    (r"\.fill\(Color\.orange", ".fill(ScarfColor.warning"),
    (r"\.foregroundStyle\(Color\.orange\)", ".foregroundStyle(ScarfColor.warning)"),
    (r"\.foregroundStyle\(\.orange\)", ".foregroundStyle(ScarfColor.warning)"),
    (r": Color\.orange\b", ": ScarfColor.warning"),
    (r"return \.orange\b", "return ScarfColor.warning"),
    (r"case \.unconfirmed: \.orange", "case .unconfirmed: ScarfColor.warning"),
    (r"case \.configured: return \.orange", "case .configured: return ScarfColor.warning"),
    (r"case \.execute: return \.orange", "case .execute: return ScarfColor.warning"),
    (r'case "execute": return \.orange', 'case "execute": return ScarfColor.warning'),
    (r'case "cooldown": return \.orange', 'case "cooldown": return ScarfColor.warning'),
    (r"color: \.orange", "color: ScarfColor.warning"),
    (r": \.orange\b", ": ScarfColor.warning"),
    (r"\.background\(\.orange\.opacity", ".background(ScarfColor.warning.opacity"),
]


def should_skip(path: Path) -> bool:
    s = str(path)
    return any(p in s for p in SKIP_PARTS)


def ensure_import(text: str) -> str:
    if "ScarfColor" not in text:
        return text
    if "import ScarfDesign" in text:
        return text
    if "import SwiftUI" in text:
        return text.replace("import SwiftUI\n", "import SwiftUI\nimport ScarfDesign\n", 1)
    return "import ScarfDesign\n" + text


def main():
    changed = []
    for path in ROOT.rglob("*.swift"):
        if should_skip(path):
            continue
        text = path.read_text()
        if ".orange" not in text and "Color.orange" not in text:
            continue
        orig = text
        for pat, repl in REPLACEMENTS:
            text = re.sub(pat, repl, text)
        text = ensure_import(text)
        if text != orig:
            path.write_text(text)
            changed.append(path.relative_to(ROOT))
    print("Updated", len(changed), "files")
    for p in changed:
        print(" ", p)


if __name__ == "__main__":
    main()
