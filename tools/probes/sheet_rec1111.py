# -*- coding: utf-8 -*-
"""分块联系表：每张 12 帧、4 列，避免超大图。"""
import os

from PIL import Image, ImageDraw

ROOT = r"C:\Users\17948\DoubaoWork\chats\2026-10-22\new-chat-1\_tmp_fb3"


def sheets(folder, prefix, cols=4, cell_w=250, per=12):
    files = sorted(os.listdir(os.path.join(ROOT, folder)))
    imgs = [(f, Image.open(os.path.join(ROOT, folder, f))) for f in files]
    first = imgs[0][1]
    ch = int(cell_w * first.size[1] / first.size[0])
    for s in range(0, len(imgs), per):
        chunk = imgs[s:s + per]
        rows = (len(chunk) + cols - 1) // cols
        canvas = Image.new("RGB", (cols * cell_w, rows * (ch + 16)), (255, 255, 255))
        d = ImageDraw.Draw(canvas)
        for i, (f, im) in enumerate(chunk):
            r, c = divmod(i, cols)
            canvas.paste(im.resize((cell_w, ch)), (c * cell_w, r * (ch + 16) + 16))
            d.text((c * cell_w + 4, r * (ch + 16) + 2), f, fill=(0, 0, 0))
        name = "%s_%02d.jpg" % (prefix, s // per + 1)
        canvas.save(os.path.join(ROOT, name), quality=90)
        print(name, canvas.size, len(chunk))


sheets("frames_a", "sheet_a")
sheets("frames_b", "sheet_b")
