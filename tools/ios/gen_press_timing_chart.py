# -*- coding: utf-8 -*-
"""画一张"短按 60ms 时按压态可见窗口"的时序示意图（非真机录屏）。

用途：给老板解释第三十七轮的最短可见时长修复；不是 App 截图。
"""
from pathlib import Path

from PIL import Image, ImageDraw, ImageFont

ROOT = Path(__file__).resolve().parents[2]
OUT = ROOT / "docs/ios/mockups/press-timing.png"

W, H = 1200, 680
BG = (17, 17, 17)
FG = (235, 232, 226)
SUB = (150, 146, 138)
RED = (214, 90, 80)
GREEN = (120, 196, 140)
GRID = (52, 52, 52)

FONT = "C:/Windows/Fonts/msyh.ttc"


def font(size: int) -> ImageFont.FreeTypeFont:
    try:
        return ImageFont.truetype(FONT, size)
    except Exception:
        return ImageFont.load_default()


def lerp(c1, c2, t):
    return tuple(int(a + (b - a) * t) for a, b in zip(c1, c2))


img = Image.new("RGB", (W, H), BG)
d = ImageDraw.Draw(img)

d.text((40, 28), "短按 60ms：按压态在屏幕上的可见窗口", font=font(28), fill=FG)
d.text((40, 70), "时序示意（按 pressDown/pressUp 与最短可见时长计算），不是真机录屏",
       font=font(15), fill=SUB)

x0, x1 = 200, 1120
ms_to_x = lambda ms: x0 + (x1 - x0) * (ms / 800.0)

# 时间轴
for ms in range(0, 801, 100):
    x = ms_to_x(ms)
    d.line((x, 120, x, 610), fill=GRID, width=1)
    d.text((x - 16, 618), f"{ms}ms", font=font(12), fill=SUB)

# 改前
y = 180
d.text((40, y), "改前", font=font(20), fill=FG)
d.text((40, y + 26), "isPressed 60ms", font=font(13), fill=SUB)
d.text((40, y + 46), "没撑到渲染", font=font(13), fill=SUB)
d.rectangle((ms_to_x(0), y + 10, ms_to_x(60), y + 50), fill=(70, 34, 32),
            outline=RED, width=1)
d.text((ms_to_x(70), y + 18), "屏幕上：0 帧（0ms）", font=font(15), fill=RED)

# 改后：列表行 220ms 可见 + 400ms 渐隐
y = 330
d.text((40, y), "改后", font=font(20), fill=FG)
d.text((40, y + 26), "最短可见 220ms", font=font(13), fill=SUB)
d.text((40, y + 46), "+ 0.40s 渐隐", font=font(13), fill=SUB)
d.rectangle((ms_to_x(0), y + 10, ms_to_x(220), y + 50), fill=lerp(GREEN, (35, 60, 42), 0.25))
fade_end = 220 + 400
steps = 80
for i in range(steps):
    a = 220 + (fade_end - 220) * i / steps
    b = 220 + (fade_end - 220) * (i + 1) / steps
    t = i / steps
    col = lerp(GREEN, BG, t)
    d.rectangle((ms_to_x(a), y + 10, ms_to_x(b), y + 50), fill=col)
d.text((ms_to_x(232), y + 18), "先亮满 0.22s，再 0.40s 退干净", font=font(15), fill=FG)

# 普通按钮
y = 480
d.text((40, y), "普通按钮", font=font(20), fill=FG)
d.text((40, y + 26), "最短可见 160ms", font=font(13), fill=SUB)
d.rectangle((ms_to_x(0), y + 10, ms_to_x(160), y + 50), fill=(46, 70, 52))
d.text((ms_to_x(172), y + 18), "播放/暂停、工具按钮", font=font(15), fill=SUB)

img.save(OUT, "PNG")
print(OUT)
