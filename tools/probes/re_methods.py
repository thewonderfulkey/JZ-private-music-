# -*- coding: utf-8 -*-
"""枚举应用侧 API 方法名/字段名（Dart 字符串常量）。"""
import io
import os
import re

TMP = r"C:\Users\17948\DoubaoWork\chats\2026-10-22\new-chat-1\_tmp_build\re_libs"
OUT = r"C:\Users\17948\DoubaoWork\chats\2026-10-22\new-chat-1\_tmp_build\re_methods.txt"

pat = re.compile(r"^(Kw|Song|Cover|Album|Artist|Lyric|Playlist|Rank|Search|Recommend|Comment|Pic|Skin|Mflac|Qr)[A-Za-z0-9_]{2,60}$")
tok = re.compile(rb"[A-Za-z][A-Za-z0-9_]{3,64}")
lines = []
data = open(os.path.join(TMP, "libapp.so"), "rb").read()
seen = set()
for m in tok.finditer(data):
    s = m.group().decode("latin-1")
    if s in seen:
        continue
    seen.add(s)
    if pat.match(s):
        lines.append("%06x  %s" % (m.start(), s))
io.open(OUT, "w", encoding="utf-8").write("\n".join(lines) + "\n")
print("hits", len(lines))
