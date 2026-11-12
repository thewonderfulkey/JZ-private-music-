# -*- coding: utf-8 -*-
"""统计 r.s 返回里 MVPIC 的可得率，判断酷我封面改造的收益。"""
import ast
import io
import re
import urllib.parse
import urllib.request

OUT = r"C:\Users\17948\DoubaoWork\chats\2026-10-22\new-chat-1\_tmp_build\re_mvpic_rate.txt"
UA = "Mozilla/5.0 (Linux; Android 13) AppleWebKit/537.36 Mobile Safari/537.36"
lines = []
for kw in ("周杰伦", "陈奕迅", "五月天"):
    url = ("https://search.kuwo.cn/r.s?all=" + urllib.parse.quote(kw)
           + "&ft=music&rn=20&pn=1&rformat=json&encoding=utf8&vipver=MUSIC_8.7.8.0_WX")
    req = urllib.request.Request(url, headers={"User-Agent": UA, "Referer": "https://www.kuwo.cn/"})
    with urllib.request.urlopen(req, timeout=12) as r:
        txt = r.read().decode("utf-8", "ignore")
    body = txt[txt.find("{"): txt.rfind("}") + 1]
    data = ast.literal_eval(body)
    rows = data.get("abslist", [])
    filled = sum(1 for x in rows if str(x.get("MVPIC", "")).strip())
    lines.append("%s: %d 条, MVPIC 非空 %d 条" % (kw, len(rows), filled))
    for x in rows[:3]:
        lines.append("   %s | %s" % (x.get("NAME"), x.get("MVPIC")))
io.open(OUT, "w", encoding="utf-8").write("\n".join(lines) + "\n")
print("\n".join(lines))
