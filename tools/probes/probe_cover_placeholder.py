"""查封面「占位图」是从哪条腿来的（2026-11-26）。

现象：补了酷狗/网易两条腿之后，仍有歌显示一个"灰色音符 + 黑底"的方块。
怀疑某条腿返回的**就是**这张占位图（HTTP 200 / image/jpeg），
于是 `CoverResolver` 认为"拿到封面了"，不再往下一级兜底。

做法：按真实兜底链（QQ → 酷狗 → 网易 → iTunes）给每首歌算出封面 URL，
逐张下载，用像素统计判"像不像占位图"：
  · 饱和度极低（灰）
  · 整体很暗
  · 颜色种类很少
命中的直接把图存到 out/cover_placeholder/，供人工确认。

跑法：python tools/probes/probe_cover_placeholder.py
"""
import io
import os

from PIL import Image, ImageStat
import numpy as np

import sys
sys.path.insert(0, os.path.join(os.path.dirname(__file__), "lines"))
import probe_lines as P  # noqa: E402

OUT = os.path.join(os.path.dirname(__file__), "out", "cover_placeholder")
os.makedirs(OUT, exist_ok=True)

TARGETS = [
    ("晴天", "周杰伦"), ("七里香", "周杰伦"), ("稻香", "周杰伦"), ("夜曲", "周杰伦"),
    ("演员", "薛之谦"), ("大鱼", "周深"), ("孤勇者", "陈奕迅"), ("海阔天空", "Beyond"),
    ("富士山下", "陈奕迅"), ("平凡之路", "朴树"), ("后来", "刘若英"),
    ("起风了", "买辣椒也用券"), ("漠河舞厅", "柳爽"), ("如愿", "王菲"),
    ("唯一", "告五人"), ("罗刹海市", "刀郎"),
    ("告白气球", "周杰伦"), ("青花瓷", "周杰伦"), ("十年", "陈奕迅"), ("红玫瑰", "陈奕迅"),
    ("光年之外", "邓紫棋"), ("泡沫", "邓紫棋"), ("消愁", "毛不易"), ("年少有为", "李荣浩"),
    ("吻别", "张学友"), ("忘情水", "刘德华"), ("倔强", "五月天"), ("突然好想你", "五月天"),
    ("小幸运", "田馥甄"), ("云烟成雨", "房东的猫"), ("奇妙能力歌", "陈粒"), ("成都", "赵雷"),
    ("山丘", "李宗盛"), ("月亮代表我的心", "邓丽君"), ("认真的雪", "薛之谦"),
    ("Shape of You", "Ed Sheeran"), ("Viva La Vida", "Coldplay"),
    ("Rolling in the Deep", "Adele"), ("Love Story", "Taylor Swift"), ("Lemon", "米津玄師"),
]


def strict(song_name, song_singer, cand_name, cand_singer):
    if P.norm_title(song_name) != P.norm_title(cand_name):
        return False
    if not song_singer:
        return True
    a, b = P.norm_singers(song_singer), P.norm_singers(cand_singer)
    return bool(a & b)


def cover_candidates(name, singer):
    """按真实顺序给出每一级的封面 URL（最多各一条）。"""
    out = []
    kw = f"{name} {singer}"
    # QQ
    try:
        for c in P.search_qq(kw, 10):
            if strict(name, singer, c["name"], c["singer"]) and c.get("pic"):
                out.append(("QQ", c["pic"]))
                break
    except Exception as e:
        out.append(("QQ-ERR", str(e)[:40]))
    # 酷狗
    try:
        for c in P.search_kugou(kw, 10):
            pic = c.get("pic") or ""
            if not pic:
                continue
            low = pic.lower()
            if "singerimg" in low or "softhead" in low or "imgessl" in low:
                continue
            if strict(name, singer, c["name"], c["singer"]):
                out.append(("酷狗", pic))
                break
    except Exception as e:
        out.append(("酷狗-ERR", str(e)[:40]))
    # 网易
    try:
        for c in P.search_netease(kw, 10):
            if strict(name, singer, c["name"], c["singer"]) and c.get("pic"):
                out.append(("网易", c["pic"]))
                break
    except Exception as e:
        out.append(("网易-ERR", str(e)[:40]))
    return out


def is_placeholder(img):
    """灰 + 暗 + 颜色少 → 像占位图。"""
    small = img.convert("RGB").resize((64, 64))
    arr = np.asarray(small).astype(float) / 255.0
    hsv = np.asarray(small.convert("HSV")).astype(float)
    sat = hsv[:, :, 1].mean() / 255.0
    val = hsv[:, :, 2].mean() / 255.0
    uniq = len(np.unique((arr * 31).astype(int).reshape(-1, 3), axis=0))
    bright_ratio = float((hsv[:, :, 2] > 150).mean())
    return (sat < 0.12 and val < 0.35 and uniq < 220 and bright_ratio < 0.25), sat, val, uniq


def main():
    rows = []
    flagged = 0
    for name, singer in TARGETS:
        cands = cover_candidates(name, singer)
        chosen = None
        for leg, url in cands[:3]:
            try:
                data = P.http(url, timeout=10).body
                img = Image.open(io.BytesIO(data))
                ph, sat, val, uniq = is_placeholder(img)
            except Exception as e:
                print(f"{name:<10} {leg:<4} ERR {type(e).__name__}")
                continue
            tag = "占位?" if ph else "ok"
            print(f"{name:<10} {leg:<4} {img.size[0]}x{img.size[1]} "
                  f"sat={sat:.2f} val={val:.2f} colors={uniq} {tag}")
            if ph:
                flagged += 1
                fn = os.path.join(OUT, f"{name}_{leg}.jpg")
                img.convert("RGB").save(fn, quality=85)
                chosen = (leg, url)
            break   # 采用链里第一张能下载的图像（不论好坏）就是 App 会用的那张
        rows.append((name, singer, chosen, [c[0] for c in cands]))
    print(f"\n共 {len(TARGETS)} 首，疑似占位图 {flagged} 张，已存到 {OUT}")


if __name__ == "__main__":
    main()
