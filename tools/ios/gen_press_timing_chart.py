# -*- coding: utf-8 -*-
"""画"短按 / 长按都会完整铺满整条高亮"的时序示意图（非真机录屏）。

用途：给老板解释第三十九轮：短按不是只亮一半，而是在松手后用 0.12s 快速铺满；
长按用 0.55s 慢慢铺满；点歌动作延后 0.22s，让高亮先播完再弹悬浮栏/播放页。
"""
from pathlib import Path

from PIL import Image, ImageDraw, ImageFont

ROOT = Path(__file__).resolve().parents[2]
OUT = ROOT / "docs/ios/mockups/press-timing.png"

W, H = 1200, 760
BG = (17, 17, 17)
FG = (235, 232, 226)
SUB = (150, 146, 138)
GREEN = (120, 196, 140)
AMBER = (214, 168, 90)
GRID = (52, 52, 52)
FONT = "C:/Windows/Fonts/msyh.ttc"


def font(size: int) -> ImageFont.FreeTypeFont:
    try:
        return ImageFont.truetype(FONT, size)
    except Exception:
        return ImageFont.load_default()


def lerp(c1, c2, t):
    t = min(max(t, 0), 1)
    return tuple(int(a + (b - a) * t) for a, b in zip(c1, c2))


img = Image.new("RGB", (W, H), BG)
d = ImageDraw.Draw(img)

d.text((40, 26), "短按 / 长按：高亮都会完整铺满整条", font=font(28), fill=FG)
d.text((40, 68), "时序示意（按 0.12s 快速铺满 / 0.55s 慢速铺满计算），不是真机录屏",
       font=font(15), fill=SUB)

x0, x1 = 210, 1140
TOTAL = 1200
ms_to_x = lambda ms: x0 + (x1 - x0) * (ms / TOTAL)

for ms in range(0, TOTAL + 1, 100):
    x = ms_to_x(ms)
    d.line((x, 110, x, 690), fill=GRID, width=1)
    d.text((x - 18, 700), f"{ms}ms", font=font(12), fill=SUB)


def band(y, segments, label, note):
    d.text((40, y), label, font=font(20), fill=FG)
    d.text((40, y + 26), note, font=font(13), fill=SUB)
    for start, end, color_from, color_to in segments:
        steps = 60
        for i in range(steps):
            a = start + (end - start) * i / steps
            b = start + (end - start) * (i + 1) / steps
            d.rectangle((ms_to_x(a), y + 10, ms_to_x(b), y + 52),
                        fill=lerp(color_from, color_to, i / steps))


# 短按：0-60 亮斑；60-220 快速铺满；220-320 停；320-720 退
band(150, [
    (0, 60, (60, 40, 30), (90, 70, 40)),
    (60, 180, lerp(GREEN, BG, 0.55), GREEN),
    (180, 280, GREEN, GREEN),
    (280, 680, GREEN, BG),
], "短按 60ms", "松手后 0.12s 快速铺满 → 停 0.10s → 点歌动作 0.22s 才弹栏/页")
d.text((ms_to_x(190), 182), "铺满 100%", font=font(14), fill=(20, 40, 24))

# 长按：0-550 慢速铺满；550-650 停；650-1050 退
band(320, [
    (0, 550, lerp(GREEN, BG, 0.75), GREEN),
    (550, 650, GREEN, GREEN),
    (650, 1050, GREEN, BG),
], "长按 550ms+", "按住时 0.55s 慢慢铺满 → 松手后停 0.10s → 0.40s 退")
d.text((ms_to_x(560), 352), "铺满 100%", font=font(14), fill=(20, 40, 24))

# 普通按钮
band(490, [
    (0, 160, lerp(AMBER, BG, 0.6), AMBER),
], "普通按钮", "按下 0.14s 缩到 0.95 / 压暗，最短可见 160ms")
d.text((ms_to_x(170), 522), "缩放 + 压暗", font=font(14), fill=SUB)

# 说明
d.text((40, 620), "关键：短按不是停在半截再淡出——松手后用更快的速度把整条铺满，"
                  "两种按法最终都是 100% 高亮。", font=font(15), fill=FG)
d.text((40, 646), "高亮铺满后停 0.10s；点歌条的播放/悬浮栏/播放页延后 0.22s，"
                  "保证高亮先播完再弹。", font=font(14), fill=SUB)

img.save(OUT, "PNG")
print(OUT)
