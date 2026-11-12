# -*- coding: utf-8 -*-
"""端点邻域字符串，用于还原 query 参数名。"""
import io
import os
import re

TMP = r"C:\Users\17948\DoubaoWork\chats\2026-10-22\new-chat-1\_tmp_build\re_libs"
OUT = r"C:\Users\17948\DoubaoWork\chats\2026-10-22\new-chat-1\_tmp_build\re_ep_neighbors.txt"

ANCHORS = ["/openapi/v1/www/search/searchKey", "/openapi/v1/www/lyric/getlyric",
           "/openapi/v1/recommend/discover/v0", "/newh5app/wapi/api/www/playlist/playListInfo",
           "/api/www/album/albumInfo", "/api/pc/classify/playlist/getRcmPlayList",
           "/api/pc/classify/playlist/getTagPlayList", "/api/playlist/detail", "/openapi/",
           "searchKey", "getLyric", "KwComment", "KwCatalogItem", "KwMvInfo", "KwAlbumDetail"]
W = 600
tok = re.compile(rb"[ -~]{3,}")
data = open(os.path.join(TMP, "libapp.so"), "rb").read()

lines = []
for a in ANCHORS:
    for m in re.finditer(re.escape(a.encode()), data):
        lines.append("===== %s @ %06x" % (a, m.start()))
        lo, hi = max(0, m.start() - W), min(len(data), m.end() + W)
        row = []
        for t in tok.finditer(data, lo, hi):
            s = t.group().decode("latin-1").strip()
            if len(s) >= 4 and not s.startswith(("package:", "dart:", "assets/")):
                row.append(s)
        lines.append(" | ".join(row))
        lines.append("")

io.open(OUT, "w", encoding="utf-8").write("\n".join(lines) + "\n")
print("lines", len(lines))
