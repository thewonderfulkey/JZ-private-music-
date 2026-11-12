# -*- coding: utf-8 -*-
"""从群录屏抽帧（每 0.6s 一帧，最多 40 帧），供逐帧读图定位「全标录音室版」。"""
import os
import cv2

SRC = r"C:\Users\17948\DoubaoWork\chats\2026-10-22\new-chat-1\lark-im-resources\file_v3_0017c_20545359-785c-414a-80fb-5a05f18a78fg.mp4"
DST = r"C:\Users\17948\DoubaoWork\chats\2026-10-22\new-chat-1\_tmp_fb6"
os.makedirs(DST, exist_ok=True)

cap = cv2.VideoCapture(SRC)
fps = cap.get(cv2.CAP_PROP_FPS) or 30
total = int(cap.get(cv2.CAP_PROP_FRAME_COUNT) or 0)
w = int(cap.get(cv2.CAP_PROP_FRAME_WIDTH))
h = int(cap.get(cv2.CAP_PROP_FRAME_HEIGHT))
print("fps=%.1f frames=%d %dx%d dur=%.1fs" % (fps, total, w, h, total / fps if fps else 0))

step = max(1, int(round(fps * 0.6)))
idx = 0
n = 0
while True:
    ok, frame = cap.read()
    if not ok:
        break
    if idx % step == 0 and n < 40:
        p = os.path.join(DST, "f_%02d.jpg" % n)
        cv2.imwrite(p, frame, [int(cv2.IMWRITE_JPEG_QUALITY), 92])
        n += 1
    idx += 1
cap.release()
print("saved %d frames -> %s" % (n, DST))
