# -*- coding: utf-8 -*-
"""看酷我 r.s 搜索返回里封面字段的形态（app 的 kwNormalizePic 处理对象）。"""
import io
import re
import urllib.parse
import urllib.request

OUT = r"C:\Users\17948\DoubaoWork\chats\2026-10-22\new-chat-1\_tmp_build\re_probe_search.txt"
UA = "Mozilla/5.0 (Linux; Android 13) AppleWebKit/537.36 Mobile Safari/537.36"
url = ("https://search.kuwo.cn/r.s?all=" + urllib.parse.quote("晴天")
       + "&ft=music&rn=5&pn=1&rformat=json&encoding=utf8&vipver=MUSIC_8.7.8.0_WX")
req = urllib.request.Request(url, headers={"User-Agent": UA, "Referer": "https://www.kuwo.cn/"})
with urllib.request.urlopen(req, timeout=12) as r:
    txt = r.read().decode("utf-8", "ignore")

lines = ["len=%d" % len(txt)]
# 找 pic 相关键值
for kw in ["web_albumpic_short", "web_artistpic_short", "pic", "artistpic", "albumpic"]:
    for m in re.finditer(kw + r"\s*=\s*([^,\r\n]+)", txt):
        lines.append("%s = %s" % (kw, m.group(1)))
lines.append("")
lines.append(txt[:1200])
io.open(OUT, "w", encoding="utf-8").write("\n".join(lines) + "\n")
print("\n".join(lines[:40]))
