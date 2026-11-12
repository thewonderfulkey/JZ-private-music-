# -*- coding: utf-8 -*-
"""v2.1.81 首页「听歌识曲」栏预览（基于用户真机首页截图）。
严格按 Compose 实装口径绘制（1080px 宽 = 360dp，3px/dp）：
  条：左右 16dp、上 12dp / 下 4dp、高 84dp、圆角 2dp、surface→surface2 竖渐变、1dp 墨线 10%
  左列 132dp：19sp 楷体题字 + 6dp 间隔 + 11sp text3 副标题
  中间声纹：16 根 1.2dp 墨线，包络朝右走高，alpha 0.05→0.16
  右端 MicDisc 56dp：外圈墨线(呼吸 0.10~0.24) + 内圈墨线 0.55 + 淡墨盘 0.05 + 麦克风 0.38 倍
"""
import os
import math
from PIL import Image, ImageDraw, ImageFont

ROOT = r"C:\Users\17948\DoubaoWork\chats\2026-10-22\new-chat-1"
SRC = os.path.join(ROOT, r"lark-im-resources\img_v3_0217b_a53f669c-437b-4fe8-8975-a88aaffcb3eg.webp")
FONT = os.path.join(ROOT, r"JZMusicHelperAndroid\app\src\main\res\font\lxgw_wenkai_regular.ttf")
OUTDIR = os.path.join(ROOT, "_tmp_fb3")

INK = (0x2E, 0x2A, 0x24)
TEXT2 = (0x5C, 0x54, 0x46)
TEXT3 = (0x74, 0x6C, 0x60)
SURF = (0xFD, 0xFC, 0xF9)
SURF2 = (0xEF, 0xEB, 0xE1)
PAGE = (0xFA, 0xF8, 0xF3)


def mix(base, top, a):
    return tuple(int(round(base[i] * (1 - a) + top[i] * a)) for i in range(3))


im = Image.open(SRC).convert("RGB")
W, H = im.size
D = W / 360.0


def dp(v):
    return int(round(v * D))


px = im.load()

# ---------- 1. 找旧栏上下边框（长横线行） ----------
bg = px[W - 20, dp(56)]
rows = []
for y in range(dp(133), dp(215)):
    cnt = 0
    for x in range(dp(16), W - dp(16)):
        c = px[x, y]
        if sum(abs(c[i] - bg[i]) for i in range(3)) >= 6:
            cnt += 1
    if cnt > W * 0.85:
        rows.append(y)
print("BORDER ROWS", rows[:6], "...", rows[-6:])
top_old, bot_old = rows[0], rows[-1]
left_old = dp(16)
right_old = W - dp(16) - 1
print("OLD RECT", left_old, top_old, right_old, bot_old, "h_dp", (bot_old - top_old + 1) / D)

# ---------- 2. 新栏几何（严格按代码） ----------
new_top = top_old
new_h = dp(84)
new_bot = new_top + new_h - 1
delta = new_h - (bot_old - top_old + 1)

# 内容整体下移 delta（新栏比旧栏高），底部裁回原高
if delta > 0:
    below = im.crop((0, bot_old + 1, W, H))
    whole = Image.new("RGB", (W, H + delta), PAGE)
    whole.paste(im.crop((0, 0, W, bot_old + 1)), (0, 0))
    whole.paste(below, (0, new_bot + 1))
    im = whole.crop((0, 0, W, H))
    px = im.load()
print("DELTA px", delta)

draw = ImageDraw.Draw(im)

# ---------- 3. 画新栏 ----------
card = Image.new("RGB", (right_old - left_old + 1, new_h))
cd = ImageDraw.Draw(card)
for y in range(new_h):
    cd.line([(0, y), (card.width, y)], fill=mix(SURF, SURF2, y / max(1, new_h - 1)))
mask = Image.new("L", card.size, 0)
ImageDraw.Draw(mask).rounded_rectangle([0, 0, card.width - 1, card.height - 1], radius=dp(2), fill=255)
im.paste(card, (left_old, new_top), mask)
draw = ImageDraw.Draw(im)
draw.rounded_rectangle([left_old, new_top, right_old, new_bot], radius=dp(2),
                       outline=mix(SURF2, INK, 0.10), width=max(1, dp(0.5)))

pad_l, pad_r = dp(18), dp(13)
center_y = (new_top + new_bot) // 2

title_f = ImageFont.truetype(FONT, dp(19))
sub_f = ImageFont.truetype(FONT, dp(11))
# 两行整体垂直居中：19sp ≈ 26dp 行高 + 6dp + 11sp ≈ 15dp
block_h = dp(26) + dp(6) + dp(15)
ty = center_y - block_h // 2
draw.text((left_old + pad_l, ty), "听歌识曲", font=title_f, fill=INK)
draw.text((left_old + pad_l, ty + dp(26) + dp(6)), "把手机靠近声源，听十秒", font=sub_f, fill=TEXT3)

mic_d = dp(56)
mic_cx = right_old - pad_r - mic_d // 2
mic_cy = center_y
r = mic_d / 2.0

# 呼吸圈取中值 0.17；淡墨盘 0.05（代码里只有一道呼吸圈 + 一层盘）
ring = Image.new("RGBA", (W, H), (0, 0, 0, 0))
rd = ImageDraw.Draw(ring)
rd.ellipse([mic_cx - r + dp(0.7), mic_cy - r + dp(0.7), mic_cx + r - dp(0.7), mic_cy + r - dp(0.7)],
           outline=mix(SURF2, INK, 0.17) + (255,), width=max(1, dp(0.47)))
rd.ellipse([mic_cx - r + dp(2.4), mic_cy - r + dp(2.4), mic_cx + r - dp(2.4), mic_cy + r - dp(2.4)],
           fill=mix(SURF, INK, 0.05) + (255,))
im = Image.alpha_composite(im.convert("RGBA"), ring).convert("RGB")
draw = ImageDraw.Draw(im)

# 麦克风字形（Material Filled.Mic 24dp 网格等比换算，整体 0.38 盘径）
gw = mic_d * 0.38
bx, by = mic_cx - gw / 2.0, mic_cy - gw / 2.0
u = gw / 24.0
# 胶囊
cap_w = 7.4 * u
cap_top = by + 3.0 * u
cap_bot = by + 13.2 * u
draw.rounded_rectangle([mic_cx - cap_w / 2, cap_top, mic_cx + cap_w / 2, cap_bot],
                       radius=cap_w / 2, fill=INK)
# 下方承接半圆（碗形：0..180 走下半圈）+ 竖杆
arc_r = 5.4 * u
arc_cy = by + 11.4 * u
draw.arc([mic_cx - arc_r, arc_cy - arc_r, mic_cx + arc_r, arc_cy + arc_r],
         start=0, end=180, fill=INK, width=max(1, int(round(2.0 * u))))
draw.line([(mic_cx, arc_cy + arc_r), (mic_cx, by + 21.0 * u)],
          fill=INK, width=max(1, int(round(2.0 * u))))

# 声纹：16 根，包络朝右
wave_l = left_old + pad_l + dp(132) + dp(6)
wave_r = mic_cx - r - dp(4)
n = 16
gap = (wave_r - wave_l) / n
for i in range(n):
    t = i / (n - 1)
    env = 0.16 + 0.84 * math.sin(t * math.pi * 0.85)
    h = new_h * 0.30 * env
    a = 0.05 + 0.11 * t
    x = wave_l + gap * i + gap / 2
    draw.line([(x, mic_cy - h / 2), (x, mic_cy + h / 2)], fill=mix(SURF2, INK, a), width=max(1, dp(0.4)))

full = os.path.join(OUTDIR, "preview_2181_home.jpg")
im.save(full, quality=94)
print("SAVED", full, im.size)

crop_top = max(0, new_top - dp(26))
crop_bot = min(H, new_bot + dp(26))
crop = im.crop((0, crop_top, W, crop_bot))
crop = crop.resize((int(crop.width * 1.25), int(crop.height * 1.25)), Image.LANCZOS)
bar = os.path.join(OUTDIR, "preview_2181_bar.jpg")
crop.save(bar, quality=95)
print("SAVED", bar, crop.size)
