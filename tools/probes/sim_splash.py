# -*- coding: utf-8 -*-
"""模拟不同适配方案在 4:3 / 16:10 平板上的开屏观感（用于选型，不是产物）。"""
import os

from PIL import Image, ImageDraw

ROOT = r"C:\Users\17948\DoubaoWork\chats\2026-10-22\new-chat-1"
ASSET = os.path.join(ROOT, "JZMusicHelperAndroid", "app", "src", "main", "res", "drawable-nodpi", "splash_ink_main.jpg")
OUT = os.path.join(ROOT, "_tmp_fb3")
im = Image.open(ASSET).convert("RGB")
PAPER = (250, 245, 236)

cases = [("A_16x10_left", 800, 1280, "left"),
         ("B_4x3_left", 900, 1200, "left"),
         ("C_16x10_center", 800, 1280, "center"),
         ("D_4x3_center", 900, 1200, "center")]

for name, W, H, mode in cases:
    s = H / im.size[1]
    w2 = int(im.size[0] * s)
    img = im.resize((w2, H), Image.LANCZOS)
    canvas = Image.new("RGB", (W, H), PAPER)
    ox = 0 if mode == "left" else int((W - w2) / 2)
    canvas.paste(img, (ox, 0))
    d = ImageDraw.Draw(canvas)
    d.text((10, 10), "peak@%d%%  (%s)" % (int((ox + w2 * 0.308) / W * 100), mode), fill=(180, 40, 30))
    canvas.save(os.path.join(OUT, "sim_%s.jpg" % name), quality=90)
    print(name, canvas.size, "ox", ox, "imgw", w2)
