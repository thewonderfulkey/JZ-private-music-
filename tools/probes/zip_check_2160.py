# -*- coding: utf-8 -*-
"""v2.1.60 APK 交付前静态核对：完整性 / 条目数 / 版本串命中 / 体积对比 / 关键资源。"""
import os, zipfile

mode = "a"
apk = r"C:\Users\17948\DoubaoWork\chats\2026-10-22\new-chat-1\JZMusicHelperAndroid\app\build\outputs\apk\release\app-release.apk"
prev = r"C:\Users\17948\DoubaoWork\chats\2026-10-22\new-chat-1\_tmp_fb3\JZ音乐助手-v2.1.59.apk"
out = r"C:\Users\17948\DoubaoWork\chats\2026-10-22\new-chat-1\_tmp_build\zipcheck_2160.txt"

lines = []
size = os.path.getsize(apk)
lines.append("apk=%s" % apk)
lines.append("size=%d (%.2f MB)" % (size, size / 1048576))
if os.path.exists(prev):
    psize = os.path.getsize(prev)
    lines.append("prev_v2159=%d (%.2f MB) delta=%+d (%+.2f%%)" % (
        psize, psize / 1048576, size - psize, (size - psize) / psize * 100))

with zipfile.ZipFile(apk) as z:
    bad = z.testzip()
    names = z.namelist()
lines.append("testzip=%s" % ("OK" if bad is None else "BAD:" + str(bad)))
lines.append("entries=%d" % len(names))

hits = []
with zipfile.ZipFile(apk) as z:
    for n in names:
        if n.endswith(".dex") and b"2.1.60" in z.read(n):
            hits.append(n)
lines.append("dex_with_2160=%s" % hits)

want = ["ink_bg_player", "mashanzheng", "editor_chinese", "search_ink"]
for k in want:
    lines.append("res[%s]=%s" % (k, [n for n in names if k in n][:2]))

open(out, "w", encoding="utf-8").write("\n".join(lines))
print("written", out, "bad=", bad)
