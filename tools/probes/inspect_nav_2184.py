# -*- coding: utf-8 -*-
from PIL import Image

src = r"C:\Users\17948\DoubaoWork\chats\2026-10-22\new-chat-1\lark-im-resources\img_v3_0217b_0743e389-66b9-4cca-b58d-f069397a6f1g.webp"
im = Image.open(src).convert("RGB")
print("SIZE", im.size)
w, h = im.size
# 底栏大概在下方 1/9
crop = im.crop((0, int(h * 0.80), w, h))
crop = crop.resize((crop.width * 2, crop.height * 2), Image.LANCZOS)
out = r"C:\Users\17948\DoubaoWork\chats\2026-10-22\new-chat-1\_tmp_fb3\crop_nav_2184.png"
crop.save(out)
print("SAVED", out, crop.size)

# 逐行扫描第 2 格（约 1/6 ~ 2/6 宽度）里的深色像素范围，判断墨印是否压到标签
x0, x1 = int(w * 1 / 6), int(w * 2 / 6)
rows = []
for y in range(int(h * 0.80), h):
    dark = 0
    for x in range(x0, x1):
        r, g, b = im.getpixel((x, y))
        if r < 90 and g < 80 and b < 70:
            dark += 1
    rows.append((y, dark))
# 打印连续深色行段
seg = []
cur = None
for y, d in rows:
    if d > 5:
        if cur is None:
            cur = [y, y]
        else:
            cur[1] = y
    else:
        if cur is not None:
            seg.append(tuple(cur)); cur = None
if cur is not None:
    seg.append(tuple(cur))
print("DARK_SEGMENTS", seg)
