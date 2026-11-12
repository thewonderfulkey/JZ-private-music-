# -*- coding: utf-8 -*-
"""量一下用户首页截图里那条「听歌识曲」的实际像素范围，供预览图对齐。"""
from PIL import Image

SRC = r"C:\Users\17948\DoubaoWork\chats\2026-10-22\new-chat-1\lark-im-resources\img_v3_0217b_a53f669c-437b-4fe8-8975-a88aaffcb3eg.webp"
im = Image.open(SRC).convert("RGB")
W, H = im.size
print("SIZE", W, H)
px = im.load()

# 页面底色：取标题区右侧空白（y=140 附近）
bg = px[W - 60, 150]
print("PAGE_BG", bg)

x_probe = int(W * 0.5)
prof = []
for y in range(int(H * 0.08), int(H * 0.30)):
    c = px[x_probe, y]
    d = abs(c[0] - bg[0]) + abs(c[1] - bg[1]) + abs(c[2] - bg[2])
    prof.append((y, d, c))

rows = [p for p in prof if p[1] >= 8]
if rows:
    print("BAND_FIRST", rows[0][0], rows[0][2], "d=", rows[0][1])
    print("BAND_LAST", rows[-1][0], rows[-1][2], "d=", rows[-1][1])
else:
    print("no band found")

# 竖直方向扫左右边界（在带内取中线）
if rows:
    y_mid = (rows[0][0] + rows[-1][0]) // 2
    xs = [x for x in range(0, W) if abs(px[x, y_mid][0] - bg[0]) + abs(px[x, y_mid][1] - bg[1]) + abs(px[x, y_mid][2] - bg[2]) >= 8]
    print("Y_MID", y_mid, "X_FIRST", xs[0] if xs else None, "X_LAST", xs[-1] if xs else None)
    print("BAND_COLOR", px[x_probe, y_mid], "TOP_COLOR", px[x_probe, rows[0][0] + 6])
