# -*- coding: utf-8 -*-
"""探测两段录屏的分辨率/时长，并按固定间隔抽帧。"""
import os

import cv2

ROOT = r"C:\Users\17948\DoubaoWork\chats\2026-10-22\new-chat-1\_tmp_fb3"
FILES = ["rec_1111_ipad_or_phone_a.mp4", "rec_1111_ipad_or_phone_b.mp4"]

for name in FILES:
    p = os.path.join(ROOT, name)
    cap = cv2.VideoCapture(p)
    w = int(cap.get(cv2.CAP_PROP_FRAME_WIDTH))
    h = int(cap.get(cv2.CAP_PROP_FRAME_HEIGHT))
    fps = cap.get(cv2.CAP_PROP_FPS)
    n = int(cap.get(cv2.CAP_PROP_FRAME_COUNT))
    print(name, "| %dx%d" % (w, h), "| fps %.2f" % fps, "| frames %d" % n,
          "| dur %.2fs" % (n / fps if fps else 0))
    tag = name.replace("rec_1111_ipad_or_phone_", "").replace(".mp4", "")
    out = os.path.join(ROOT, "frames_" + tag)
    os.makedirs(out, exist_ok=True)
    t = 0.0
    while t < (n / fps if fps else 0):
        cap.set(cv2.CAP_PROP_POS_MSEC, t * 1000)
        ok, img = cap.read()
        if ok:
            cv2.imwrite(os.path.join(out, "t%05.2f.jpg" % t), img)
        t += 0.5
    cap.release()
    print("saved:", out, len(os.listdir(out)))
