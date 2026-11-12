# -*- coding: utf-8 -*-
"""围绕关键 token 取上下文，重建完整 endpoint 与参数名。"""
import io
import os
import re

TMP = r"C:\Users\17948\DoubaoWork\chats\2026-10-22\new-chat-1\_tmp_build\re_libs"
OUT = r"C:\Users\17948\DoubaoWork\chats\2026-10-22\new-chat-1\_tmp_build\re_context.txt"

KEYS = ["kuwo", "openapi", "mobi", "searchKey", "getlyric", "getLyric", "lyric", "cover",
        "albumcover", "wmvpic", "songinfo", "songurl", "vkey", "playUrl", "xwang", "encrypt",
        "sign", "token", "source", "163", "qqmusic", "c.y.qq", "u.y.qq", "si.qq"]

lines = []
files = [os.path.join(TMP, n) for n in os.listdir(TMP)]
for p in files:
    data = open(p, "rb").read()
    lines.append("### %s  (%d B)" % (os.path.basename(p), len(data)))
    for k in KEYS:
        for m in re.finditer(re.escape(k).encode("utf-8"), data, re.I):
            a = max(0, m.start() - 90)
            b = min(len(data), m.end() + 90)
            chunk = data[a:b]
            txt = "".join(chr(c) if 32 <= c < 127 else "." for c in chunk)
            lines.append("[%s] %06x  %s" % (k, m.start(), txt))
    lines.append("")

io.open(OUT, "w", encoding="utf-8").write("\n".join(lines) + "\n")
print("lines", len(lines))
