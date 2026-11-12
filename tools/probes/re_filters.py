# -*- coding: utf-8 -*-
"""把快照里的可读字符串逐条切开，按关键词筛选并完整输出。"""
import io
import os
import re

TMP = r"C:\Users\17948\DoubaoWork\chats\2026-10-22\new-chat-1\_tmp_build\re_libs"
OUT = r"C:\Users\17948\DoubaoWork\chats\2026-10-22\new-chat-1\_tmp_build\re_filters.txt"

FILTERS = ["kuwo", "playUrl", "antiserver", "mobi", "wapi", "openapi", "api/", "/api", "163",
           "qq", "cover", "albumcover", "starheads", "wmvpic", "pic", "lyric", "song", "search",
           "album", "artist", "playlist", "rank", "recommend", "vip", "quality", "br", "format",
           "url", "http", "kw", "sign", "token", "encrypt", "decrypt", "mflac", "qrc", "krc"]

TOKEN = re.compile(rb"[ -~]{4,}")
lines = []
for name in ["libapp.so", "libcenbridge.so"]:
    p = os.path.join(TMP, name)
    data = open(p, "rb").read()
    lines.append("#### %s" % name)
    for m in TOKEN.finditer(data):
        s = m.group().decode("latin-1")
        low = s.lower()
        if len(s) < 4:
            continue
        if any(f.lower() in low for f in FILTERS):
            lines.append("%06x\t%s" % (m.start(), s))
    lines.append("")

io.open(OUT, "w", encoding="utf-8").write("\n".join(lines) + "\n")
print("lines", len(lines))
