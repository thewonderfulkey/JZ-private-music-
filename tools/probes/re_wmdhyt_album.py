# -*- coding: utf-8 -*-
"""验证「原唱判定靠专辑名」是否可行：拉 QQ/网易 我们都一样 前 50 条，打印 歌名/歌手/专辑/时长。"""
import json
import urllib.parse
import urllib.request

OUT = r"C:\Users\17948\DoubaoWork\chats\2026-10-22\new-chat-1\_tmp_build\re_wmdhyt_album.txt"
UA = "Mozilla/5.0 (iPhone; CPU iPhone OS 16_6 like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/16.6 Mobile/15E148 Safari/604.1"


def qq(kw, n=50):
    u = "https://c.y.qq.com/soso/fcgi-bin/client_search_cp?p=1&n=%d&w=%s&format=json" % (n, urllib.parse.quote(kw))
    r = urllib.request.Request(u, headers={"User-Agent": UA, "Referer": "https://y.qq.com/"})
    js = json.loads(urllib.request.urlopen(r, timeout=20).read().decode("utf-8", "ignore"))
    out = []
    for s in (((js.get("data") or {}).get("song") or {}).get("list") or []):
        out.append((s.get("songname", ""), "/".join(x.get("name", "") for x in (s.get("singer") or [])),
                    s.get("albumname", ""), s.get("interval", 0)))
    return out


def netease(kw, n=50):
    body = urllib.parse.urlencode({"s": kw, "type": 1, "limit": n, "offset": 0}).encode()
    r = urllib.request.Request("https://music.163.com/api/search/get", data=body,
                               headers={"User-Agent": UA, "Referer": "https://music.163.com/"})
    js = json.loads(urllib.request.urlopen(r, timeout=20).read().decode("utf-8", "ignore"))
    out = []
    for s in ((js.get("result") or {}).get("songs") or []):
        out.append((s.get("name", ""), "/".join(a.get("name", "") for a in (s.get("artists") or [])),
                    (s.get("album") or {}).get("name", ""), (s.get("duration") or 0) // 1000))
    return out


L = []
for tag, fn in (("QQ", qq), ("网易", netease)):
    L.append("=== %s 我们都一样（前 50）===" % tag)
    try:
        for i, (n, a, al, d) in enumerate(fn("我们都一样"), 1):
            L.append("%2d. %-30s | %-20s | %-24s | %ss" % (i, n[:28], a[:18], al[:22], d))
    except Exception as e:
        L.append("ERR %s" % e)
    L.append("")
open(OUT, "w", encoding="utf-8").write("\n".join(L) + "\n")
print("\n".join(L[:70]))
