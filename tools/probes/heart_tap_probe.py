# -*- coding: utf-8 -*-
"""一次性取证脚本（2026-11-23，v2.4.86）：爱心点击到底有没有变色。

做法：
  1. 逐帧在**爱心那一列**（右侧固定 x 带）统计"朱砂红"像素，按行带聚类 → 每帧的红色行中心 y。
  2. 逐帧找"整行按压高亮"（大片亮度抬升、且横跨整行）→ 点按时刻 + 被点那一行的 y。
  3. 把"点按时该行是空心 / 点按后 0.5–2s 该行有没有变红"对出来，直接给出成功/失败清单。
"""
import sys, glob, os
import numpy as np
import cv2

frames = sorted(glob.glob(sys.argv[1] + "/*.png"))
fps = float(sys.argv[2]) if len(sys.argv) > 2 else 2.0

HEART_X0, HEART_X1 = 0.88, 0.94      # 爱心横向范围（占帧宽比例）
ROW_MIN_BAND = 20

def load(p):
    img = cv2.imread(p, cv2.IMREAD_COLOR)
    return img  # BGR

def red_mask(img):
    b, g, r = img[:, :, 0].astype(int), img[:, :, 1].astype(int), img[:, :, 2].astype(int)
    return (r > 140) & (r - g > 40) & (r - b > 30)

def heart_rows(img):
    """返回该帧「红色爱心」所在行的中心 y（按行带聚类）"""
    h, w = img.shape[:2]
    m = red_mask(img[:, int(w * HEART_X0):int(w * HEART_X1)])
    ys = np.where(m.sum(axis=1) >= 6)[0]
    if len(ys) == 0:
        return []
    bands, cur = [], [ys[0]]
    for y in ys[1:]:
        if y - cur[-1] <= 4:
            cur.append(y)
        else:
            bands.append(cur); cur = [y]
    bands.append(cur)
    return [int(np.mean(b)) for b in bands if len(b) >= 4 and (max(b) - min(b)) >= 6]

def press_band(img, prev):
    """找整行按压高亮：与上一帧差分的行带（横向几乎整行变亮）"""
    if prev is None:
        return None
    h, w = img.shape[:2]
    d = cv2.absdiff(img, prev).astype(int).sum(axis=2)
    rowdelta = (d[:, int(w * 0.1):int(w * 0.75)] > 24).sum(axis=1)
    ys = np.where(rowdelta > (w * 0.5))[0]
    if len(ys) < ROW_MIN_BAND:
        return None
    return int(np.mean(ys))

prev = None
timeline = []
for i, f in enumerate(frames):
    img = load(f)
    t = i / fps
    timeline.append((t, heart_rows(img), press_band(img, prev)))
    prev = img

print("t     red-hearts(y)                      press-row")
for t, rows, press in timeline:
    print("%5.2f  %-34s %s" % (t, str(rows)[:34], press if press else ""))

# 对每个"点按"，看该行在 0.5~2s 内有没有变红/变空
print("\n— 点按判定 —")
for idx, (t, rows, press) in enumerate(timeline):
    if press is None:
        continue
    before = [r for r in rows if abs(r - press) < 40]
    after_rows = []
    for j in range(idx + 1, min(len(timeline), idx + int(fps * 2) + 1)):
        after_rows += [r for r in timeline[j][1] if abs(r - press) < 40]
    state_before = "红" if before else "空"
    state_after = "红" if after_rows else "空"
    ok = "没变" if state_before == state_after else "变了"
    print("t=%5.2f 行y=%4d 点按前=%s 点按后2s=%s → %s" % (t, press, state_before, state_after, ok))
