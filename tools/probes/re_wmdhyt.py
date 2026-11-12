# -*- coding: utf-8 -*-
"""复算「我们都一样」在网易/QQ 下：查询词怎么写才把张杰原唱带进候选池。
   —— 用于判断 v2.1.89（歌名+第一位歌手）是否真能解决问题，以及识别命中翻唱时会不会仍落翻唱。
"""
import json
import urllib.parse
import urllib.request

OUT = r"C:\Users\17948\DoubaoWork\chats\2026-10-22\new-chat-1\_tmp_build\re_wmdhyt.txt"
L = []
UA_I = "Mozilla/5.0 (iPhone; CPU iPhone OS 16_6 like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/16.6 Mobile/15E148 Safari/604.1"


def get(url, ua=UA_I, ref="", timeout=20):
    req = urllib.request.Request(url, headers={"User-Agent": ua, "Referer": ref})
    with urllib.request.urlopen(req, timeout=timeout) as r:
        return r.read().decode("utf-8", "ignore")


def netease(kw):
    body = urllib.parse.urlencode({"s": kw, "type": 1, "limit": 10, "offset": 0}).encode()
    req = urllib.request.Request("https://music.163.com/api/search/get",
                                 data=body, headers={"User-Agent": UA_I, "Referer": "https://music.163.com/"})
    with urllib.request.urlopen(req, timeout=20) as r:
        js = json.loads(r.read().decode("utf-8", "ignore"))
    out = []
    for s in ((js.get("result") or {}).get("songs") or []):
        out.append((s.get("name", ""), "/".join(a.get("name", "") for a in (s.get("artists") or [])),
                    (s.get("album") or {}).get("name", ""), (s.get("duration") or 0) // 1000))
    return out


def qq(kw):
    u = "https://c.y.qq.com/soso/fcgi-bin/client_search_cp?p=1&n=10&w=%s&format=json" % urllib.parse.quote(kw)
    js = json.loads(get(u, ref="https://y.qq.com/"))
    out = []
    for s in (((js.get("data") or {}).get("song") or {}).get("list") or []):
        out.append((s.get("songname", ""), "/".join((x.get("name") or "") for x in (s.get("singer") or [])),
                    s.get("albumname", ""), s.get("interval", 0)))
    return out


for kw in ("我们都一样", "我们都一样 张杰", "我们都一样 神仙哥哥", "我们都一样 张杰、胡迪、范如臣"):
    L.append("== 网易  s=%r ==" % kw)
    try:
        for i, (n, a, al, d) in enumerate(netease(kw), 1):
            L.append("   %2d. %-34s | %-22s | %-18s | %ss" % (i, n[:32], a[:20], al[:16], d))
    except Exception as e:
        L.append("   ERR %s" % e)
    L.append("== QQ    w=%r ==" % kw)
    try:
        for i, (n, a, al, d) in enumerate(qq(kw), 1):
            L.append("   %2d. %-34s | %-22s | %-18s | %ss" % (i, n[:32], a[:20], al[:16], d))
    except Exception as e:
        L.append("   ERR %s" % e)
    L.append("")

open(OUT, "w", encoding="utf-8").write("\n".join(L) + "\n")
print("done")
