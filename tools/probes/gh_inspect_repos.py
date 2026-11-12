# -*- coding: utf-8 -*-
"""看这几个仓库里到底哪些文件在生成/调用指纹，判断 Android 侧能否复用"""
import json, urllib.request

REPOS = [
    "AudileTeam/Audile",
    "BayernMuller/vibra",
    "simoneraffaelli/songrec-fingerprint",
    "xqe-bkflda/aplayer-custom",
    "cjcxj/NCM-Fingerprint-Tagger",
]
KEY = ("shazam", "fingerprint", "recogni", "audio/match", "trackid", "audd", "acoustid", "chromaprint")

def get(url):
    req = urllib.request.Request(url, headers={"User-Agent": "probe", "Accept": "application/vnd.github+json"})
    with urllib.request.urlopen(req, timeout=40) as r:
        return json.loads(r.read().decode("utf-8"))

for repo in REPOS:
    print(f"\n=== {repo} ===")
    try:
        info = get(f"https://api.github.com/repos/{repo}")
        branch = info.get("default_branch", "main")
        lic = (info.get("license") or {}).get("spdx_id", "?")
        lang = info.get("language")
        print(f"  license={lic} language={lang} branch={branch} stars={info.get('stargazers_count')}")
        tree = get(f"https://api.github.com/repos/{repo}/git/trees/{branch}?recursive=1")
        paths = [t["path"] for t in tree.get("tree", []) if t["type"] == "blob"]
        hits = [p for p in paths if any(k in p.lower() for k in KEY)]
        print(f"  文件总数 {len(paths)}，命中关键词 {len(hits)}：")
        for p in hits[:14]:
            print("   -", p)
    except Exception as e:
        print("  失败:", type(e).__name__, e)
