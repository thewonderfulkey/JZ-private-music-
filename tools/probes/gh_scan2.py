# -*- coding: utf-8 -*-
"""第二轮定向扫描：酷狗/QQ/网易 识曲实现、以及可在 Android 上生成 Shazam 指纹的项目"""
import json, time, urllib.parse, urllib.request

QUERIES = [
    "kugou fingerprint", "酷狗 识曲", "QQ音乐 听歌识曲", "shazam fingerprint android",
    "shazam signature kotlin", "music recognition android shazam", "vibra music recognition",
]

def gh(q):
    u = ("https://api.github.com/search/repositories?q=" + urllib.parse.quote(q) +
         "&sort=stars&order=desc&per_page=10")
    req = urllib.request.Request(u, headers={"User-Agent": "probe", "Accept": "application/vnd.github+json"})
    try:
        with urllib.request.urlopen(req, timeout=30) as r:
            return json.loads(r.read().decode("utf-8"))
    except Exception as e:
        return {"error": f"{type(e).__name__}: {e}"}

for q in QUERIES:
    j = gh(q)
    print(f"\n=== 「{q}」 total={j.get('total_count', '?')} ===")
    if "items" not in j:
        print("  失败:", j.get("error")); continue
    for it in j["items"][:8]:
        print(f"  {it['stargazers_count']:>5}★ {it['full_name']:<44s} {(it.get('description') or '')[:70]}")
    time.sleep(1.2)
