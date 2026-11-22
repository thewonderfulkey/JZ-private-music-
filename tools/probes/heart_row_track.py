# -*- coding: utf-8 -*-
"""一次性取证（2026-11-23 v2.4.86）：逐帧按**封面指纹**跟踪每一行，看爱心到底哪一次没变。

为什么要按封面认行：列表会滚，按 y 追同一行会把上一行当成下一行（第一版 probe 就错在这）。
做法：
  1. 在封面那一列扫亮度带 → 每一行的 y 区间；
  2. 封面缩成 6x6 灰度当指纹（同一首歌跨帧稳定、不同的歌差别够大）；
  3. 爱心那一列取"红/空"，按行记录；
  4. 输出：每个封面指纹的时间线 —— 什么时候是空、什么时候变红、以及点按时它有没有变化。
"""
import sys, glob
import numpy as np
import cv2

frames = sorted(glob.glob(sys.argv[1] + "/*.png"))
fps = float(sys.argv[2]) if len(sys.argv) > 2 else 10.0

COVER_X0, COVER_X1 = 0.10, 0.28      # 封面横向范围（帧宽比例，540 宽时 ≈ 54~151）
HEART_X0, HEART_X1 = 0.86, 0.95

def bands(img):
    """返回每一行的 (y0, y1)：封面列上"亮"的连续段"""
    h, w = img.shape[:2]
    strip = cv2.cvtColor(img[:, int(w * COVER_X0):int(w * COVER_X1)], cv2.COLOR_BGR2GRAY)
    prof = strip.mean(axis=1)
    thr = max(28.0, prof.max() * 0.45)
    ys = np.where(prof > thr)[0]
    if len(ys) == 0:
        return []
    out, cur = [], [ys[0]]
    for y in ys[1:]:
        if y - cur[-1] <= 6:
            cur.append(y)
        else:
            out.append((cur[0], cur[-1])); cur = [y]
    out.append((cur[0], cur[-1]))
    return [(a, b) for a, b in out if (b - a) >= 25]

def fingerprint(img, y0, y1):
    h, w = img.shape[:2]
    patch = img[y0:y1, int(w * COVER_X0):int(w * COVER_X1)]
    g = cv2.cvtColor(patch, cv2.COLOR_BGR2GRAY)
    return cv2.resize(g, (6, 6), interpolation=cv2.INTER_AREA).astype(float)

def is_red(img, y0, y1):
    h, w = img.shape[:2]
    patch = img[y0:y1, int(w * HEART_X0):int(w * HEART_X1)].astype(int)
    b, g, r = patch[:, :, 0], patch[:, :, 1], patch[:, :, 2]
    m = (r > 140) & (r - g > 40) & (r - b > 30)
    return int(m.sum()) >= 8

known = []          # [(fp, first_t)]
track = {}          # fp index -> list of (t, red)
for i, f in enumerate(frames):
    img = cv2.imread(f)
    t = i / fps
    for (y0, y1) in bands(img):
        fp = fingerprint(img, y0, y1)
        red = is_red(img, y0, y1)
        # 找同指纹
        best, bestd = None, 1e9
        for k, (kfp, _) in enumerate(known):
            d = np.abs(kfp - fp).mean()
            if d < bestd:
                best, bestd = k, d
        if best is None or bestd > 14:
            known.append((fp, t))
            best = len(known) - 1
            track[best] = []
        track[best].append((t, red))

print("共跟踪 %d 个封面" % len(track))
print("\n— 只列出「爱心状态发生过变化 / 中途出现过红心」的行 —")
for k, (fp, t0) in enumerate(known):
    ev = track.get(k, [])
    if not ev:
        continue
    states = [r for _, r in ev]
    if not any(states):
        continue
    # 压缩成状态段
    segs = []
    for t, r in ev:
        if not segs or segs[-1][1] != r:
            segs.append([t, r])
    print("封面#%02d 首见 %.2fs  段：%s" % (k, t0, " ".join(("%.2f:%s" % (t, "红" if r else "空")) for t, r in segs)))
