# -*- coding: utf-8 -*-
"""抽样统计酷我歌词接口的命中率（按 r.s 搜索结果逐条查歌词）。"""
import ast
import io
import json
import time
import urllib.parse
import urllib.request

OUT = r"C:\Users\17948\DoubaoWork\chats\2026-10-22\new-chat-1\_tmp_build\re_lyric_rate.txt"
UA = "Mozilla/5.0 (Linux; Android 13) AppleWebKit/537.36 Mobile Safari/537.36"
lines = []
hit = total = 0
for kw in ("周杰伦", "陈奕迅", "五月天", "林俊杰"):
    url = ("https://search.kuwo.cn/r.s?all=" + urllib.parse.quote(kw)
           + "&ft=music&rn=10&pn=1&rformat=json&encoding=utf8&vipver=MUSIC_8.7.8.0_WX")
    req = urllib.request.Request(url, headers={"User-Agent": UA, "Referer": "https://www.kuwo.cn/"})
    with urllib.request.urlopen(req, timeout=12) as r:
        txt = r.read().decode("utf-8", "ignore")
    body = txt[txt.find("{"): txt.rfind("}") + 1]
    rows = ast.literal_eval(body).get("abslist", [])[:10]
    for x in rows:
        rid = str(x.get("MUSICRID", "")).replace("MUSIC_", "")
        name = str(x.get("NAME", ""))[:18]
        if not rid:
            continue
        total += 1
        u = "https://www.kuwo.cn/openapi/v1/www/lyric/getlyric?musicId=%s&httpsStatus=1" % rid
        try:
            d = json.loads(urllib.request.urlopen(
                urllib.request.Request(u, headers={"User-Agent": UA, "Referer": "https://www.kuwo.cn/"}),
                timeout=8).read().decode("utf-8", "ignore"))
            ll = (d.get("data") or {}).get("lrclist") or []
        except Exception as e:
            ll = []
        if ll:
            hit += 1
            lines.append("OK   %-6s %-20s lines=%d" % (kw, name, len(ll)))
        else:
            lines.append("MISS %-6s %-20s rid=%s" % (kw, name, rid))
        time.sleep(0.15)
lines.append("")
lines.append("命中 %d / %d = %.0f%%" % (hit, total, 100.0 * hit / total if total else 0))
io.open(OUT, "w", encoding="utf-8").write("\n".join(lines) + "\n")
print("\n".join(lines[-6:]))
