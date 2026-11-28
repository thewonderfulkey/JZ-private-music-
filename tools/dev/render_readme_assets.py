"""Rasterize the README SVGs and composite the app icon into the banner.

The generic SVG renderer used by the visual-thinking skill refuses embedded images, so the
banner is rendered from a no-icon variant and the icon is pasted with Pillow afterwards.
"""
from __future__ import annotations

import os
import shutil
import subprocess
import sys
from pathlib import Path

from PIL import Image, ImageDraw

ROOT = Path(__file__).resolve().parents[2]
OUT = ROOT / "docs/images/readme"
TMP = ROOT / ".build/readme-assets"
ICON = ROOT / "ios/JZMusicHelper/Assets.xcassets/AppIcon.appiconset/AppIcon.png"

SKILL = Path.home() / ".dsh/skills/visual-thinking"
RENDERER = SKILL / "scripts/render-svg.cjs"
NODE_MODULES = Path.home() / ".dsh/tools/vt-render/node_modules"


def render(svg: Path, png: Path) -> None:
    env = os.environ.copy()
    env["NODE_PATH"] = str(NODE_MODULES)
    node = shutil.which("node") or r"D:\Nodejs\node.exe"
    cmd = [node, str(RENDERER), str(svg), str(png), "--channel", "chrome", "--scale", "2"]
    print("render:", " ".join(cmd))
    proc = subprocess.run(cmd, cwd=SKILL, env=env, capture_output=True, text=True)
    if proc.stdout:
        print(proc.stdout[-800:])
    if proc.stderr:
        print(proc.stderr[-800:])
    # exit 2 = rendered with review diagnostics; the PNG is still usable.
    if proc.returncode not in (0, 2):
        raise SystemExit(f"renderer failed ({proc.returncode}) for {svg.name}")
    if not png.exists():
        raise SystemExit(f"renderer produced no PNG for {svg.name}")


def paste_icon(base_path: Path, out_path: Path, xy: tuple[int, int], size: int, radius: int) -> None:
    base = Image.open(base_path).convert("RGBA")
    icon = Image.open(ICON).convert("RGBA").resize((size, size), Image.LANCZOS)
    mask = Image.new("L", (size, size), 0)
    ImageDraw.Draw(mask).rounded_rectangle([0, 0, size - 1, size - 1], radius=radius, fill=255)
    icon.putalpha(mask)
    base.alpha_composite(icon, dest=xy)
    base.convert("RGB").save(out_path, quality=95)
    print("wrote", out_path)


def main() -> int:
    if not RENDERER.exists():
        raise SystemExit(f"renderer not found: {RENDERER}")

    render(OUT / "architecture.svg", OUT / "architecture.png")

    render(TMP / "banner-render.svg", TMP / "banner-base.png")
    paste_icon(TMP / "banner-base.png", OUT / "banner.png", (176, 224), 480, 60)

    render(TMP / "banner-dark-render.svg", TMP / "banner-dark-base.png")
    paste_icon(TMP / "banner-dark-base.png", OUT / "banner-dark.png", (216, 264), 400, 50)
    return 0


if __name__ == "__main__":
    sys.exit(main())
