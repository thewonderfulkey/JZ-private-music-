# -*- coding: utf-8 -*-
"""离线复算「原唱」判定 D 口径：拿真实池子（QQ+网易 我们都一样）跑一遍，
   确认只有张杰被标、翻唱不被标。"""
import json
import re
import urllib.parse
import urllib.request

OUT = r"C:\Users\17948\DoubaoWork\chats\2026-10-22\new-chat-1\_tmp_build\re_origin_rule.txt"
UA = "Mozilla/5.0 (iPhone; CPU iPhone OS 16_6 like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/16.6 Mobile/15E148 Safari/604.1"

VARIANT_TITLE = re.compile("伴奏|伴唱|纯音乐|instrumental|钢琴|翻唱|cover|remix|live|现场|演唱会|片段|剪辑|ktv|dj|消音|合唱", re.I)
LIVE_ALBUM = re.compile("现场|演唱会|live|巡演|音乐会|音乐节", re.I)


def norm(s):
    return re.sub(r"[^\w\u4e00-\u9fff]", "", s.lower())


def same_album_as_title(album, title):
    a, t = norm(album), norm(title)
    return bool(a) and (a == t or a.startswith(t))


pool = []
q = "我们都一样"
u = "https://c.y.qq.com/soso/fcgi-bin/client_search_cp?p=1&n=50&w=%s&format=json" % urllib.parse.quote(q)
r = urllib.request.Request(u, headers={"User-Agent": UA, "Referer": "https://y.qq.com/"})
js = json.loads(urllib.request.urlopen(r, timeout=20).read().decode("utf-8", "ignore"))
for s in (((js.get("data") or {}).get("song") or {}).get("list") or []):
    pool.append({"name": s.get("songname", ""),
                 "singer": "/".join(x.get("name", "") for x in (s.get("singer") or [])),
                 "album": s.get("albumname", ""), "dur": s.get("interval", 0), "pf": "QQ"})

body = urllib.parse.urlencode({"s": q, "type": 1, "limit": 50, "offset": 0}).encode()
r = urllib.request.Request("https://music.163.com/api/search/get", data=body,
                           headers={"User-Agent": UA, "Referer": "https://music.163.com/"})
js = json.loads(urllib.request.urlopen(r, timeout=20).read().decode("utf-8", "ignore"))
for s in ((js.get("result") or {}).get("songs") or []):
    pool.append({"name": s.get("name", ""),
                 "singer": "/".join(a.get("name", "") for a in (s.get("artists") or [])),
                 "album": (s.get("album") or {}).get("name", ""),
                 "dur": (s.get("duration") or 0) // 1000, "pf": "网易"})

title = "我们都一样"
tn = norm(title)
same = [p for p in pool if tn in norm(p["name"])]
# 参与原唱判定的只能是“歌名就是它”的行（原来我们都一样/我也很想他（我们都一样）这类不算）
exact = [p for p in same if norm(p["name"]) == tn]
clean = [p for p in exact if not VARIANT_TITLE.search(p["name"]) and not LIVE_ALBUM.search(p["album"])]

groups = {}
for p in clean:
    groups.setdefault(norm(p["singer"]), []).append(p)

canon = {}
for singer, items in groups.items():
    formal = [p for p in items if p["album"] and not same_album_as_title(p["album"], title)]
    # 时长聚簇：±3s 内算同一条录音；要求这一簇至少跨 2 张不同正式专辑
    clusters = []
    for p in sorted(formal, key=lambda x: x["dur"]):
        if clusters and p["dur"] - clusters[-1][-1]["dur"] <= 3:
            clusters[-1].append(p)
        else:
            clusters.append([p])
    for c in clusters:
        if len({norm(x["album"]) for x in c}) >= 2:
            canon.setdefault(singer, []).extend(c)

L = ["池子 %d 条（QQ+网易），同曲 %d 条，干净 %d 条" % (len(pool), len(same), len(clean)), ""]
L.append("判定为原唱的歌手：")
for singer, items in canon.items():
    for p in items:
        L.append("  OK %-16s %-28s %-18s %ss" % (p["singer"], p["name"][:26], p["album"][:16], p["dur"]))
if not canon:
    L.append("  （无）")
L.append("")
L.append("抽查：专辑名像正式专辑但未判原唱的条目")
for p in same:
    if canon.get(norm(p["singer"])):
        continue
    if p["album"] and not same_album_as_title(p["album"], title) and not LIVE_ALBUM.search(p["album"]):
        L.append("  · %-16s %-28s %-18s %ss" % (p["singer"], p["name"][:26], p["album"][:16], p["dur"]))

open(OUT, "w", encoding="utf-8").write("\n".join(L) + "\n")
print("\n".join(L))
