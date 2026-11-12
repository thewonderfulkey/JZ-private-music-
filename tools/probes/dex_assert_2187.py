# -*- coding: utf-8 -*-
"""校验交付 APK 里确实含有 v2.1.87 改动（不是旧包重命名）。"""
import hashlib
import io
import zipfile

APK = r"C:\Users\17948\DoubaoWork\chats\2026-10-22\new-chat-1\JZMusicHelperAndroid\app\build\outputs\apk\release\app-release.apk"
OUT = r"C:\Users\17948\DoubaoWork\chats\2026-10-22\new-chat-1\_tmp_build\dex_assert_2187.txt"
lines = []

with open(APK, "rb") as f:
    data = f.read()
lines.append("apk size=%d md5=%s" % (len(data), hashlib.md5(data).hexdigest().upper()))

with zipfile.ZipFile(APK) as z:
    dexes = [n for n in z.namelist() if n.endswith(".dex")]
    lines.append("dex=%s" % dexes)
    blob = b"".join(z.read(n) for n in dexes)

for token in (b"wmvpic", b"openapi/v1/www/lyric/getlyric", b"httpsStatus", b"MVPIC",
              b"KwLyrics", b"2.1.87", b"img1.kuwo.cn"):
    lines.append("%-32s %s" % (token.decode("latin-1"), "FOUND" if token in blob else "MISSING"))

io.open(OUT, "w", encoding="utf-8").write("\n".join(lines) + "\n")
print("\n".join(lines))
