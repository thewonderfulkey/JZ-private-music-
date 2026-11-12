# -*- coding: utf-8 -*-
"""v2.1.57 出包核对：zip 完整性 / dex 命中版本串 / 关键素材在 / 无多余调试文件"""
import zipfile, re, sys, os

APK = r"C:\Users\17948\DoubaoWork\chats\2026-10-22\new-chat-1\JZMusicHelperAndroid\app\build\outputs\apk\release\app-release.apk"
out = []
z = zipfile.ZipFile(APK)

bad = z.testzip()
out.append("testzip=%s" % ("OK" if bad is None else bad))
names = z.namelist()
out.append("entries=%d" % len(names))

# dex 里找版本串
dexes = [n for n in names if n.endswith(".dex")]
hit = []
for d in dexes:
    data = z.read(d)
    if b"2.1.57" in data:
        hit.append(d)
out.append("dex=%s ver_hit=%s" % (",".join(dexes), ",".join(hit) or "NONE"))

# 素材（APK 内已改名）
need = ["res/1q.jpg", "res/RE.png", "res/q1.png", "res/ms.png", "res/I6.png", "res/n2.png", "res/Px.png"]
for n in need:
    out.append("asset %-12s %s" % (n, "OK" if n in names else "MISSING"))

for n in ("res/drawable/splash_blank.xml", "resources.arsc", "AndroidManifest.xml"):
    out.append("has %-32s %s" % (n, "OK" if n in names else "MISSING"))

# 不该有的调试物
junk = [n for n in names if re.search(r"(_dbg|_micro|__MACOSX|\.DS_Store|\.py$|\.log$)", n)]
out.append("junk=%s" % (",".join(junk) or "none"))

txt = "\n".join(out)
open(r"C:\Users\17948\DoubaoWork\chats\2026-10-22\new-chat-1\_tmp_build\v2157_zipcheck.txt", "w", encoding="utf-8").write(txt)
print(txt)
