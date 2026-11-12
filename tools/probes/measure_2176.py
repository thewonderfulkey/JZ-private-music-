# -*- coding: utf-8 -*-
"""v2.1.76 实机截图：按暖纸色（R-B>=10）定位栏体，量几何/配色/文字"""
from PIL import Image

P = r"C:\Users\17948\DoubaoWork\chats\2026-10-22\new-chat-1\_tmp_fb3\shot_dl_2176.jpg"
im = Image.open(P).convert("RGB")
W, H = im.size
px = im.load()


def is_paper(p):
    r, g, b = p
    return r >= 232 and g >= 228 and b >= 210 and (r - b) >= 10 and (g - b) >= 6


# 1 找栏体：逐行统计暖纸像素
ys = []
for y in range(int(H * 0.5), H):
    c = sum(1 for x in range(0, W, 2) if is_paper(px[x, y]))
    if c > W * 0.15:
        ys.append(y)
top, bot = min(ys), max(ys)
h = bot - top + 1
print("bar top/bottom", top, bot, "height px", h)

midy = (top + bot) // 2 + 20
xs = [x for x in range(W) if is_paper(px[x, midy])]
left, right = min(xs), max(xs)
w = right - left + 1
print("bar left/right", left, right, "width px", w, "center", (left + right) / 2)

# 2 圆角：上边缘每行的左内缩
print("corner inset profile:")
prof = []
for dy in range(0, 45, 2):
    y = top + dy
    row = [x for x in range(W) if is_paper(px[x, y])]
    if row:
        inset = min(row) - left
        prof.append((dy, inset))
        print("  dy=%2d inset=%3d" % (dy, inset))

# 由 inset 估算半径：inset≈r 时 dy≈0.29r 之类；直接用 r 满足 inset = r - sqrt(r^2-(r-dy)^2)
import math
best = None
for r in range(10, 120):
    err = 0
    for dy, inset in prof[:12]:
        if dy > r:
            continue
        ideal = r - math.sqrt(max(0, r * r - (r - dy) ** 2))
        err += (ideal - inset) ** 2
    if best is None or err < best[1]:
        best = (r, err)
print("corner radius estimate px", best)

# 3 配色采样（远离文字处）
print("bg samples:", [px[left + 20, top + 12], px[right - 20, top + 12], px[left + 20, bot - 12]])
print("paper hex approx: #%02X%02X%02X" % px[left + 20, top + 12])

# 4 文字带（暗像素）
bands = []
cur = None
for y in range(top, bot + 1):
    c = 0
    for x in range(left, right, 1):
        r, g, b = px[x, y]
        if r < 170 and g < 165 and b < 155:
            c += 1
    if c >= 2:
        cur = [y, y] if cur is None else [cur[0], y]
    else:
        if cur:
            bands.append(tuple(cur))
            cur = None
if cur:
    bands.append(tuple(cur))
print("text bands", bands, "gaps", [(bands[i + 1][0] - bands[i][1]) for i in range(len(bands) - 1)])

for i, (y0, y1) in enumerate(bands):
    xmin, xmax, cnt = W, 0, 0
    for y in range(y0, y1 + 1):
        for x in range(left, right):
            r, g, b = px[x, y]
            if r < 170 and g < 165 and b < 155:
                xmin = min(xmin, x); xmax = max(xmax, x); cnt += 1
    print("band%d y=%d..%d h=%d  x=%d..%d  padL=%d padR=%d  darkpx=%d  centerX=%.1f"
          % (i, y0, y1, y1 - y0 + 1, xmin, xmax, xmin - left, right - xmax, cnt, (xmin + xmax) / 2))
