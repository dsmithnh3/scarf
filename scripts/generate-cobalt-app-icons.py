#!/usr/bin/env python3
"""Regenerate Electric Cobalt app icons from the orange scarf mark.

Delegates to ``recolor-app-icon-to-cobalt.py`` so we never replace the real
scarf artwork with a blank gradient.
"""
from __future__ import annotations

import runpy
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]


def main() -> None:
    runpy.run_path(str(ROOT / "scripts/recolor-app-icon-to-cobalt.py"), run_name="__main__")


if __name__ == "__main__":
    main()
