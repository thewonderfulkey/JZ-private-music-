# -*- coding: utf-8 -*-
import zipfile, re, os, io

APK = r"C:\Users\17948\DoubaoWork\chats\2026-10-22\new-chat-1\JZMusicHelperAndroid\app\build\outputs\apk\release\app-release.apk"
OUT = r"C:\Users\17948\DoubaoWork\chats\2026-10-22\new-chat-1\_tmp_build"
lines = []

# 1) zip 完整性
z = zipfile.ZipFile(APK)
bad = z.testzip()
lines.append("zip entries=%d testzip=%s" % (len(z.namelist()), "OK" if bad is None else ("BAD:" + str(bad))))
dexes = [n for n in z.namelist() if n.endswith(".dex")]
lines.append("dex files=%s" % dexes)

# 2) dex 里找开场动画相关符号（上一版在 classes2.dex）
for d in dexes:
    data = z.read(d)
    marks = {}
    for s in [b"InkSplash", b"SplashGate", b"kenBurns", b"withFrameNanos", b"homeReady", b"markReady"]:
        marks[s.decode()] = data.count(s)
    lines.append("%s -> %s" % (d, marks))

# 3) 资源：webp 体积 + drawable-nodpi 条目
big = sorted(((i.file_size, i.filename) for i in z.infolist() if i.filename.endswith((".webp", ".jpg", ".png"))), reverse=True)
lines.append("media entries total=%d" % len(big))
for sz, nm in big[:10]:
    lines.append("  %8d %s" % (sz, nm))

with io.open(os.path.join(OUT, "v2151_zip_dex.txt"), "w", encoding="utf-8") as f:
    f.write("\n".join(lines))
print("\n".join(lines))
