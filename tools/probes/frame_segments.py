"""把 1fps 抽出来的帧切成「屏幕状态段」：连续相似的帧归一段，给出代表帧。

用途：9 分钟录屏 500+ 帧，人眼看不完。先按画面相似度分段（每次切屏/弹窗/列表滚动都算一段），
再只挑每段的代表帧细看；同时把段内音频电平带上，方便判断"这一段有没有声音"。

用法：
  python tools/probes/frame_segments.py <frames_dir> [--out segs.json] [--thresh 8]
"""
import argparse
import json
import os
import sys

import numpy as np
from PIL import Image


def dhash(path, size=16):
    im = Image.open(path).convert("L").resize((size + 1, size), Image.BILINEAR)
    a = np.asarray(im, dtype=np.int16)
    return (a[:, 1:] > a[:, :-1]).flatten()


def hamming(a, b):
    return int(np.count_nonzero(a != b))


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("frames")
    ap.add_argument("--out", default=None)
    ap.add_argument("--thresh", type=int, default=10, help="相邻帧汉明距离阈值，超过就算切屏")
    ap.add_argument("--min_len", type=int, default=2, help="短于这么多帧的段并入上一段")
    a = ap.parse_args()

    files = sorted(f for f in os.listdir(a.frames) if f.lower().endswith((".jpg", ".png")))
    if not files:
        print("没有帧")
        return 2
    hashes = [dhash(os.path.join(a.frames, f)) for f in files]

    segs = []
    cur = {"start": 1, "end": 1, "rep": files[0], "files": [files[0]]}
    for i in range(1, len(files)):
        d = hamming(hashes[i], hashes[i - 1])
        if d > a.thresh:
            segs.append(cur)
            cur = {"start": i + 1, "end": i + 1, "rep": files[i], "files": [files[i]]}
        else:
            cur["end"] = i + 1
            cur["files"].append(files[i])
    segs.append(cur)

    # 合并过短的段
    merged = []
    for s in segs:
        if merged and (s["end"] - s["start"] + 1) < a.min_len:
            merged[-1]["end"] = s["end"]
            merged[-1]["files"].extend(s["files"])
        else:
            merged.append(s)

    for s in merged:
        s["dur"] = s["end"] - s["start"] + 1
        s["rep"] = os.path.join(a.frames, s["rep"])
        s.pop("files", None)

    out = a.out or os.path.join(os.path.dirname(a.frames.rstrip("\\/")), "segs.json")
    json.dump(merged, open(out, "w", encoding="utf-8"), ensure_ascii=False, indent=2)
    print(f"{len(files)} 帧 → {len(merged)} 段，最长 {max(s['dur'] for s in merged)}s")
    for s in merged:
        print(f"  {s['start']:4d}-{s['end']:4d}s  ({s['dur']:4d}s)  {os.path.basename(s['rep'])}")
    print("→", out)
    return 0


if __name__ == "__main__":
    sys.exit(main())
