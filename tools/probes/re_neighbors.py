# -*- coding: utf-8 -*-
"""打印锚点附近的全部字符串（按偏移排序），用于还原 URL 拼装与参数。"""
import io
import os
import re

TMP = r"C:\Users\17948\DoubaoWork\chats\2026-10-22\new-chat-1\_tmp_build\re_libs"
OUT = r"C:\Users\17948\DoubaoWork\chats\2026-10-22\new-chat-1\_tmp_build\re_neighbors.txt"

ANCHORS = ["img1.kuwo.cn/star/starheads/", "img1.kuwo.cn/wmvpic/", "img4.kuwo.cn/star/albumcover/",
           "KwMusicApi", "KwResolvedSongUrl", "com.cenmusic.app/mflac_crypto", "convert_url_with_sign",
           "/mobi.s", "/mobiweb.s", "wapi.kuwo.cn", "search.kuwo.cn", "comment.kuwo.cn", "kwcdn.kuwo.cn"]
WINDOW = 900
tok = re.compile(rb"[ -~]{3,}")

data = open(os.path.join(TMP, "libapp.so"), "rb").read()
lines = []
for a in ANCHORS:
    for m in re.finditer(re.escape(a.encode()), data):
        lines.append("===== %s @ %06x" % (a, m.start()))
        lo, hi = max(0, m.start() - WINDOW), min(len(data), m.end() + WINDOW)
        for t in tok.finditer(data, lo, hi):
            s = t.group().decode("latin-1")
            if len(s) >= 4 and sum(1 for c in s if c.isalnum()) >= 3:
                lines.append("  %06x  %s" % (t.start(), s))
        lines.append("")

io.open(OUT, "w", encoding="utf-8").write("\n".join(lines) + "\n")
print("lines", len(lines))
