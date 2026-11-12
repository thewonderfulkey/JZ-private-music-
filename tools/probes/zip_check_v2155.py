# -*- coding: utf-8 -*-
"""v2.1.55 交付前静态检查：zip 完整性/条目数/dex 版本字符串/关键素材条目。"""
import zipfile

APK = r"C:\Users\17948\DoubaoWork\chats\2026-10-22\new-chat-1\JZMusicHelperAndroid\app\build\outputs\apk\release\app-release.apk"
OUT = r"C:\Users\17948\DoubaoWork\chats\2026-10-22\new-chat-1\_tmp_build\v2155_zipcheck.txt"

zf = zipfile.ZipFile(APK)
names = zf.namelist()
lines = ["testzip=%s" % (zf.testzip() or "OK"), "entries=%d" % len(names)]
hits = 0
for n in names:
    if n.endswith(".dex"):
        d = zf.read(n)
        if "2.1.55".encode("utf-8") in d or "2.1.55".encode("utf-16-le") in d:
            hits += 1
lines.append("dex 命中 2.1.55 次数=%d" % hits)
for n in ("res/1q.jpg", "res/RE.png", "res/q1.png", "res/ms.png", "res/I6.png", "res/n2.png", "res/Px.png"):
    lines.append("%s 存在=%s" % (n, n in names))
lines.append("AndroidManifest 存在=%s" % ("AndroidManifest.xml" in names))
open(OUT, "w", encoding="utf-8").write("\n".join(lines))
print("\n".join(lines))
