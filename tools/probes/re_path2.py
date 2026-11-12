# -*- coding: utf-8 -*-
"""围绕 /r.s、/com.s、mobiweb.s、封面处理函数打印邻域。"""
import io
import os
import re

TMP = r"C:\Users\17948\DoubaoWork\chats\2026-10-22\new-chat-1\_tmp_build\re_libs"
OUT = r"C:\Users\17948\DoubaoWork\chats\2026-10-22\new-chat-1\_tmp_build\re_path2.txt"
data = open(os.path.join(TMP, "libapp.so"), "rb").read()
tok = re.compile(rb"[ -~]{3,}")
ANCHORS = [b"/r.s", b"/com.s", b"/mobiweb.s", b"kwNormalizePic", b"kwPickArtistPic", b"web_albumpic_short"]
W = 500
lines = []
for a in ANCHORS:
    for m in re.finditer(re.escape(a), data):
        lines.append("===== %s @ %06x" % (a.decode(), m.start()))
        lo, hi = max(0, m.start() - W), min(len(data), m.end() + W)
        row = []
        for t in tok.finditer(data, lo, hi):
            s = t.group().decode("latin-1").strip()
            if len(s) >= 4 and not s.startswith(("package:", "dart:", "assets/")):
                row.append(s)
        lines.append(" | ".join(row))
        lines.append("")
io.open(OUT, "w", encoding="utf-8").write("\n".join(lines) + "\n")
print("done", len(lines))
