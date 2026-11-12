# -*- coding: utf-8 -*-
"""GitHub 仓库检索：找出所有"听歌识曲/音频指纹/音乐识别"相关的开源项目"""
import json, time, urllib.parse, urllib.request

QUERIES = ["听歌识曲", "音乐识别 接口", "音频指纹 识别", "song recognition api",
           "shazam api", "acoustid chromaprint", "music fingerprint"]

def gh(q):
    u = ("https://api.github.com/search/repositories?q=" + urllib.parse.quote(q) +
         "&sort=stars&order=desc&per_page=15")
    req = urllib.request.Request(u, headers={"User-Agent": "probe", "Accept": "application/vnd.github+json"})
    try:
        with urllib.request.urlopen(req, timeout=30) as r:
            return json.loads(r.read().decode("utf-8"))
    except Exception as e:
        return {"error": f"{type(e).__name__}: {e}"}

seen = {}
for q in QUERIES:
    j = gh(q)
    if "items" not in j:
        print(f"[{q}] 失败 {j.get('error')}")
        continue
    print(f"\n=== 关键词「{q}」 命中 {j.get('total_count')} 仓库 ===")
    for it in j["items"][:10]:
        full = it["full_name"]
        desc = (it.get("description") or "").replace("\n", " ")[:80]
        print(f"  {it['stargazers_count']:>6}★  {full:<42s} {desc}")
        seen[full] = (it["stargazers_count"], it.get("language"), desc)
    time.sleep(1.5)

print("\n=== 去重后合计 %d 个仓库 ===" % len(seen))
