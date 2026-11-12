# -*- coding: utf-8 -*-
"""抽取所有像接口路径的字符串（/api、/openapi、/newh5app、/wapi、/v1…）。"""
import io
import os
import re

TMP = r"C:\Users\17948\DoubaoWork\chats\2026-10-22\new-chat-1\_tmp_build\re_libs"
OUT = r"C:\Users\17948\DoubaoWork\chats\2026-10-22\new-chat-1\_tmp_build\re_paths.txt"
data = open(os.path.join(TMP, "libapp.so"), "rb").read()
tok = re.compile(rb"[ -~]{4,}")
pat = re.compile(r"^(/(?:api|openapi|newh5app|wapi|mobi|m|www|v1|v2|v3|search|lyric|music|album|playlist|artist|mv|comment|star|resource|download|pic)[A-Za-z0-9_./\-]*)")
seen = set()
lines = []
for m in tok.finditer(data):
    s = m.group().decode("latin-1").strip()
    mm = pat.match(s)
    if mm and len(mm.group(1)) >= 4 and mm.group(1) not in seen:
        seen.add(mm.group(1))
        lines.append("%06x  %s" % (m.start(), mm.group(1)))
io.open(OUT, "w", encoding="utf-8").write("\n".join(lines) + "\n")
print(len(lines))
