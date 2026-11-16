"""P0 第一步：Asset Catalog 三个颜色集（浅色/暗色两档）。

为什么用脚本写：colorset 是 JSON，手写容易漏 appearance 分支；
而这三个颜色是我们全 App 唯一允许自定义的颜色（设计稿 §3.1），写错会让暗色模式整页发灰。
"""
from __future__ import annotations

import json
from pathlib import Path

ROOT = Path("ios/JZMusicHelper/Assets.xcassets")

# 名字 -> (浅色 hex, 暗色 hex)
COLORS = {
    "AccentColor": ("B03A2E", "FF8A76"),   # 朱砂
    "Paper": ("FAF8F3", "0E0D0B"),         # 纸底
    "PaperElevated": ("FFFDF8", "1B1916"), # 纸·浮（卡片/行底）
}


def components(hex_str: str) -> dict:
    r = int(hex_str[0:2], 16) / 255
    g = int(hex_str[2:4], 16) / 255
    b = int(hex_str[4:6], 16) / 255
    return {
        "alpha": "1.000",
        "blue": f"{b:.3f}",
        "green": f"{g:.3f}",
        "red": f"{r:.3f}",
    }


def colorset(light: str, dark: str) -> dict:
    return {
        "colors": [
            {
                "color": {"color-space": "srgb", "components": components(light)},
                "idiom": "universal",
            },
            {
                "appearances": [{"appearance": "luminosity", "value": "dark"}],
                "color": {"color-space": "srgb", "components": components(dark)},
                "idiom": "universal",
            },
        ],
        "info": {"author": "xcode", "version": 1},
    }


def main() -> None:
    for name, (light, dark) in COLORS.items():
        d = ROOT / f"{name}.colorset"
        d.mkdir(parents=True, exist_ok=True)
        (d / "Contents.json").write_text(
            json.dumps(colorset(light, dark), ensure_ascii=False, indent=2) + "\n",
            encoding="utf-8",
        )
        print(f"✓ {name}: light #{light} / dark #{dark}")


if __name__ == "__main__":
    main()
