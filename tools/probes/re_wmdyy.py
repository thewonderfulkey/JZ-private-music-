# -*- coding: utf-8 -*-
"""《我们都一样》张杰：识曲给的是综艺版（张杰、胡迪、范如臣 /《异口同声 第十二期》），
   但我们点播放落到网易的同名综艺条目、不是张杰 2008 录音室原唱。
   这里列出三个平台对「歌名」「歌名+识别歌手」两种查询各返回什么，供定位用。"""
import json
import re
import urllib.parse
import urllib.request

OUT = r"C:\Users\17948\DoubaoWork\chats\2026-10-22\new-chat-1\_tmp_build\re_wmdyy.txt"
L = []
UA = "Mozilla/5.0 (iPhone; CPU iPhone OS 16_6 like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/16.6 Mobile/15E148 Safari/604.1"


def get(url, ua=UA, ref="", timeout=20):
    req = urllib.request.Request(url, headers={"User-Agent": ua, "Referer": ref})
    with urllib.request.urlopen(req, timeout=timeout) as r:
        return r.read().decode("utf-8", "ignore")


# ---- QQ ----
def qq(kw, n=30):
    u = ("https://c.y.qq.com/soso/fcgi-bin/client_search_cp?p=1&n=%d&w=%s&format=json"
         % (n, urllib.parse.quote(kw)))
    js = json.loads(get(u, ref="https://y.qq.com/"))
    lst = ((js.get("data") or {}).get("song") or {}).get("list") or []
    out = []
    for it in lst:
        singers = "/".join((s.get("name") or "") for s in (it.get("singer") or []))
        out.append(("%s" % it.get("songname", ""), singers, it.get("albumname", ""), it.get("interval", 0)))
    return out


# ---- 网易 ----
def netease(kw, n=30):
    u = ("https://music.163.com/api/search/get?s=%s&type=1&limit=%d&offset=0"
         % (urllib.parse.quote(kw), n))
    js = json.loads(get(u, ref="https://music.163.com/"))
    res = ((js.get("result") or {}).get("songs") or [])
    out = []
    for it in res:
        singers = "/".join((a.get("name") or "") for a in (it.get("artists") or []))
        out.append((it.get("name", ""), singers, it.get("album", {}).get("name", ""),
                    int((it.get("duration") or 0) / 1000)))
    return out


for kw in ("我们都一样", "我们都一样 张杰", "我们都一样 张杰、胡迪、范如臣"):
    for tag, fn in (("QQ", qq), ("NETEASE", netease)):
        L.append("== %s kw=%r ==" % (tag, kw))
        try:
            rows = fn(kw)
            L.append("   返回 %d 条" % len(rows))
            for i, (name, singers, album, dur) in enumerate(rows[:12], 1):
                L.append("   %2d. %-26s | %-24s | %-26s | %ss" % (i, name[:24], singers[:22], album[:24], dur))
        except Exception as e:
            L.append("   ERR %s" % e)
        L.append("")

open(OUT, "w", encoding="utf-8").write("\n".join(L) + "\n")
print("done")
