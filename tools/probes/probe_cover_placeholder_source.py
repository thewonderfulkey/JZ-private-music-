"""找出「占位封面」到底是哪条腿给的、URL 长什么样（2026-11-26）。

真机录屏里那几块「灰音符 + 深色圆角块」看起来是**图片**（有内层圆角边框），
不像我们自己的 SF Symbol 占位。所以怀疑某条腿返回了官方占位图。
做法：拿录屏里那几首没封面的歌，逐条腿看返回的 picUrl，再把图下下来比对；
如果不同歌拿到**同一个 URL / 同一张图**，那就是占位图（黑名单候选）。
"""
import hashlib
import io
import os
import sys

from PIL import Image
import numpy as np

sys.path.insert(0, os.path.join(os.path.dirname(__file__), "lines"))
import probe_lines as P  # noqa: E402

SONGS = [
    ("恋爱脑中", "阿肆"),
    ("Godspeed!!", "혁오"),
    ("JUST THE ST", "铁痕电台"),
    ("ちっちゃな無敵", ""),
    ("山海过客", "者来女"),
    ("晚风", "鹿晗"),
]

OUT = os.path.join(os.path.dirname(__file__), "out", "cover_placeholder")
os.makedirs(OUT, exist_ok=True)


def fetch(url):
    data = P.http(url, timeout=12).body
    img = Image.open(io.BytesIO(data)).convert("RGB")
    h = hashlib.sha256(np.asarray(img.resize((32, 32))).tobytes()).hexdigest()[:16]
    return img, data, h


for name, singer in SONGS:
    kw = f"{name} {singer}".strip()
    print("\n###", kw)
    for leg, fn in (("QQ", P.search_qq), ("酷狗", P.search_kugou), ("网易", P.search_netease)):
        try:
            cands = fn(kw, 10)
        except Exception as e:
            print(f"  {leg}: 搜索失败 {type(e).__name__}")
            continue
        best = None
        for c in cands:
            if P.norm_title(name) == P.norm_title(c["name"]) or (name and name in c["name"]):
                best = c
                break
        if not best:
            print(f"  {leg}: 无候选")
            continue
        pic = best.get("pic") or ""
        if not pic:
            print(f"  {leg}: 命中《{best['name']}》但没图")
            continue
        try:
            img, data, h = fetch(pic)
            sat = np.asarray(img.convert("HSV")).astype(float)[:, :, 1].mean() / 255
            val = np.asarray(img.convert("HSV")).astype(float)[:, :, 2].mean() / 255
            print(f"  {leg}: 《{best['name']}》 {img.size[0]}x{img.size[1]} "
                  f"sat={sat:.2f} val={val:.2f} hash={h} len={len(data)}")
            print(f"       {pic[:110]}")
            safe = name.replace("/", "_")[:10]
            img.save(os.path.join(OUT, f"{safe}_{leg}.jpg"), quality=90)
        except Exception as e:
            print(f"  {leg}: 下载失败 {type(e).__name__} {str(e)[:40]}")
