# -*- coding: utf-8 -*-
"""量化对比：手机与平板开屏帧里墨迹的包围盒与画面占比。"""
import os

import numpy as np
from PIL import Image

ROOT = r"C:\Users\17948\DoubaoWork\chats\2026-10-22\new-chat-1\_tmp_fb3"

for tag, frame in [("phone", "frames_a/t06.50.jpg"), ("tablet", "frames_b/t06.50.jpg"),
                   ("phone05", "frames_a/t05.50.jpg"), ("tablet05", "frames_b/t05.50.jpg"),
                   ("tablet08", "frames_b/t08.00.jpg")]:
    p = os.path.join(ROOT, frame)
    if not os.path.isfile(p):
        continue
    im = Image.open(p).convert("L")
    a = np.asarray(im).astype(np.int16)
    h, w = a.shape
    dark = a < 120
    rows = np.where(dark.any(axis=1))[0]
    cols = np.where(dark.any(axis=0))[0]
    # 忽略状态栏/系统 UI 区域（顶部 60px）
    rows2 = rows[rows > 60]
    print("%-9s %dx%d inkbox y=%s..%s x=%s..%s | 高度占比 %.0f%% 宽度占比 %.0f%%"
          % (tag, w, h, rows2.min(), rows2.max(), cols.min(), cols.max(),
             100 * (rows2.max() - rows2.min()) / h, 100 * (cols.max() - cols.min()) / w))
    # 逐行墨量（每 5% 高度取一段）
    for i in range(20):
        y0, y1 = int(h * i / 20), int(h * (i + 1) / 20)
        frac = dark[y0:y1].mean()
        print("   y%02d-%02d %5.1f%%" % (i * 5, (i + 1) * 5, 100 * frac))
