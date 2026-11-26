"""对「酷我榜单歌」（发现页真实内容）跑封面兜底链，看看到底是没图还是图不对。

用法：python tools/probes/probe_cover_kuwo.py <lines_xxx.json>

背景：发现页（每日最新单曲/热门音乐/歌单广场）全是酷我来源的歌，
它们自带图恒为 nil，封面完全靠 QQ→酷狗→网易→iTunes 四级兜底。
40 首主流歌实测四级都命中 QQ；真正会出问题的是这批"榜单歌"。
"""
import io
import json
import os
import sys

from PIL import Image
import numpy as np

sys.path.insert(0, os.path.join(os.path.dirname(__file__), "lines"))
import probe_lines as P  # noqa: E402


def strict(name, singer, cname, csinger):
    if P.norm_title(name) != P.norm_title(cname):
        return False
    if not singer:
        return True
    return bool(P.norm_singers(singer) & P.norm_singers(csinger))


def stats(img):
    small = img.convert("RGB").resize((64, 64))
    hsv = np.asarray(small.convert("HSV")).astype(float)
    sat = hsv[:, :, 1].mean() / 255.0
    val = hsv[:, :, 2].mean() / 255.0
    arr = (np.asarray(small).astype(float) / 255.0 * 31).astype(int).reshape(-1, 3)
    return sat, val, len(np.unique(arr, axis=0))


def legs(name, singer):
    out = []
    kw = f"{name} {singer}"
    try:
        for c in P.search_qq(kw, 10):
            if strict(name, singer, c["name"], c["singer"]) and c.get("pic"):
                out.append(("QQ", c["pic"]))
                break
    except Exception as e:
        out.append(("QQ-ERR", str(e)[:30]))
    try:
        for c in P.search_kugou(kw, 10):
            pic = c.get("pic") or ""
            low = pic.lower()
            if not pic or "singerimg" in low or "softhead" in low or "imgessl" in low:
                continue
            if strict(name, singer, c["name"], c["singer"]):
                out.append(("酷狗", pic))
                break
    except Exception as e:
        out.append(("酷狗-ERR", str(e)[:30]))
    try:
        for c in P.search_netease(kw, 10):
            if strict(name, singer, c["name"], c["singer"]) and c.get("pic"):
                out.append(("网易", c["pic"]))
                break
    except Exception as e:
        out.append(("网易-ERR", str(e)[:30]))
    return out


def main():
    src = sys.argv[1]
    doc = json.load(open(src, encoding="utf-8"))
    songs = doc["selected"]["kuwo"]
    print(f"酷我样本 {len(songs)} 首\n")
    ok = 0
    for s in songs:
        cands = legs(s["name"], s["singer"])
        if not cands:
            print(f"{s['name'][:18]:<18} ❌ 四级全空（无封面）")
            continue
        leg, url = cands[0]
        try:
            img = Image.open(io.BytesIO(P.http(url, timeout=10).body))
            sat, val, n = stats(img)
            print(f"{s['name'][:18]:<18} {leg:<3} {img.size[0]}x{img.size[1]} "
                  f"sat={sat:.2f} val={val:.2f} colors={n}")
            ok += 1
        except Exception as e:
            print(f"{s['name'][:18]:<18} {leg:<3} 下载失败 {type(e).__name__}")
    print(f"\n拿到图 {ok}/{len(songs)}")


if __name__ == "__main__":
    main()
