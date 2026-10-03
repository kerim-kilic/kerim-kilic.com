#!/usr/bin/env python3
"""Render static/favicon.svg into the PNG and ICO variants browsers and phones ask for.

  static/favicon.ico            16/32/48 px, transparent rounded corners
  static/apple-touch-icon.png   180 px, full-bleed (iOS applies its own rounding)

Needs Google Chrome (or set CHROME) and Pillow. Set CHROME_FLAGS=--no-sandbox in containers.
"""
import os, subprocess, tempfile
from pathlib import Path
from PIL import Image

root = Path(__file__).resolve().parents[2]
svg = (root / "static/favicon.svg").read_text()
chrome = os.environ.get("CHROME", "google-chrome")
flags = os.environ.get("CHROME_FLAGS", "").split()


def render(svg_text: str, size: int, out: Path) -> None:
    with tempfile.TemporaryDirectory() as tmp:
        page = Path(tmp) / "icon.html"
        page.write_text(
            f'<!doctype html><html style="background:transparent"><body style="margin:0;background:transparent">'
            f'<div style="width:{size}px;height:{size}px">{svg_text.replace("<svg ", f"<svg width={size!r} height={size!r} ", 1)}</div>'
            f"</body></html>"
        )
        subprocess.run(
            [chrome, "--headless=new", "--disable-gpu", "--hide-scrollbars", "--default-background-color=00000000",
             f"--window-size={size},{size}", f"--screenshot={out}", *flags, page.as_uri()],
            check=True, capture_output=True,
        )


with tempfile.TemporaryDirectory() as tmp:
    big = Path(tmp) / "rounded-256.png"
    render(svg, 256, big)
    Image.open(big).convert("RGBA").save(root / "static/favicon.ico", sizes=[(16, 16), (32, 32), (48, 48)])

render(svg.replace('rx="14"', 'rx="0"'), 180, root / "static/apple-touch-icon.png")
print("wrote static/favicon.ico and static/apple-touch-icon.png")
