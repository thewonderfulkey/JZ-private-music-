# -*- coding: utf-8 -*-
"""量一下预览图里纸签的位置，确认和预览脚本的 dp 口径一致。"""
from PIL import Image

p = r"C:\Users\17948\DoubaoWork\chats\2026-10-22\new-chat-1\_tmp_fb3\preview_2186_result.jpg"
im = Image.open(p).convert("RGB")
W, H = im.size
print("size", W, H)

# 纸签是 SURF(253,252,249) 铺在纸底渐变上；找最左列(22dp*3=66px)附近由底变面色的行
col = 66 + 10
rows = []
prev = None
for y in range(H):
    c = im.getpixel((col, y))
    if prev is not None and abs(c[0] - prev[0]) + abs(c[1] - prev[1]) + abs(c[2] - prev[2]) > 6:
        rows.append((y, c))
    prev = c
print("col66 变化行前 12:", rows[:12])

# 麦克风舞台：找竖排中心列上圆环节点
cx = W // 2
tr = []
prev = None
for y in range(0, 1200):
    c = im.getpixel((cx, y))
    if prev is not None and abs(c[0] - prev[0]) + abs(c[1] - prev[1]) + abs(c[2] - prev[2]) > 4:
        tr.append((y, c))
    prev = c
print("center 列前 10 变化:", tr[:10])
