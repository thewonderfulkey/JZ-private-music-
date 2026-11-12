# -*- coding: utf-8 -*-
"""v2.1.54 交付前静态检查：zip 完整性、条目数、dex 里是否真有新版本号、素材条目是否齐全。
   输出到 v2154_zipcheck.txt，避免与旧日志重名占用。
"""
import io, os, zipfile

APK = r"C:\Users\17948\DoubaoWork\chats\2026-10-22\new-chat-1\JZMusicHelperAndroid\app\build\outputs\apk\release\app-release.apk"
OUT = r"C:\Users\17948\DoubaoWork\chats\2026-10-22\new-chat-1\_tmp_build\v2154_zipcheck.txt"

lines = []
zf = zipfile.ZipFile(APK)
lines.append("testzip=%s" % (zf.testzip() or "OK"))
names = zf.namelist()
lines.append("entries=%d" % len(names))

# dex 是否含 v2.1.54 文案（UTF-8 与 UTF-16LE 双查）
dex_hits = 0
for n in names:
    if n.endswith(".dex"):
        data = zf.read(n)
        for tag in ("2.1.54", "v2.1.54"):
            if tag.encode("utf-8") in data or tag.encode("utf-16-le") in data:
                dex_hits += 1
lines.append("dex 命中 2.1.54 次数=%d" % dex_hits)

lines.append("splash_blank 资源存在=%s" % any("splash_blank" in n or n == "res/drawable/splash_blank.xml" for n in names))
lines.append("splash_blank.xml 文件=%s" % ("res/drawable/splash_blank.xml" in names or [n for n in names if n.startswith("res/") and n.endswith(".xml") and len(n) < 40])) 

for n in ("res/1q.jpg", "res/RE.png", "res/q1.png", "res/ms.png", "res/I6.png", "res/n2.png", "res/Px.png"):
    lines.append("%s 存在=%s%s" % (n, n in names, "" if n in names else "  ← 缺"))

lines.append("AndroidManifest 存在=%s" % ("AndroidManifest.xml" in names))
open(OUT, "w", encoding="utf-8").write("\n".join(str(l) for l in lines))
print("\n".join(str(l) for l in lines))
