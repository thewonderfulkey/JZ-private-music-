# -*- coding: utf-8 -*-
"""歌词反查探活：把"歌词片段"当关键词丢进现有免费搜索链，看能否捞回正确的歌"""
import json, urllib.parse, urllib.request

QUERIES = ["故事的小黄花", "从前从前有个人爱你很久", "雨下整夜我的爱溢出就像雨水"]
UA = {"User-Agent": "Mozilla/5.0"}

def gdstudio(name, source="netease"):
    u = ("https://music-api.gdstudio.xyz/api.php?types=search&source=" + source +
         "&name=" + urllib.parse.quote(name) + "&count=5&pages=1")
    try:
        d = json.loads(urllib.request.urlopen(urllib.request.Request(u, headers=UA), timeout=20).read().decode("utf-8", "replace"))
        return " / ".join(f"{s.get('name','')}-{(s.get('artist') or [''])[0]}" for s in d[:3]) if isinstance(d, list) else str(d)[:80]
    except Exception as e:
        return f"失败:{type(e).__name__}"

def kuwo(name):
    u = ("https://search.kuwo.cn/r.s?all=" + urllib.parse.quote(name) +
         "&ft=music&itemset=web_2013&client=kt&pn=0&rn=5&rformat=json&encoding=utf8&vipver=1")
    try:
        d = urllib.request.urlopen(urllib.request.Request(u, headers=UA), timeout=20).read().decode("utf-8", "replace")
        d = d.replace("'", '"')
        j = json.loads(d)
        return " / ".join(f"{x.get('SONGNAME','')}-{x.get('ARTIST','')}" for x in (j.get("abslist") or [])[:3])
    except Exception as e:
        return f"失败:{type(e).__name__}"

for q in QUERIES:
    print(f"「{q}」")
    print("  网易(gdstudio):", gdstudio(q))
    print("  酷我(r.s)     :", kuwo(q))
