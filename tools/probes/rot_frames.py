# -*- coding: utf-8 -*-
"""把疑似带旋转标记的帧转正，判断横屏真实观感。"""
import os

from PIL import Image

ROOT = r"C:\Users\17948\DoubaoWork\chats\2026-10-22\new-chat-1\_tmp_fb3"
for t in ["t16.00", "t17.00", "t18.00"]:
    p = os.path.join(ROOT, "frames_a", t + ".jpg")
    if not os.path.isfile(p):
        continue
    im = Image.open(p)
    for ang, name in [(-90, "ccw"), (90, "cw")]:
        im.rotate(ang, expand=True).save(os.path.join(ROOT, "rot_%s_%s.jpg" % (t.replace(".", ""), name)),
                                         quality=92)
print("done")
