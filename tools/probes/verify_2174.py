# -*- coding: utf-8 -*-
import zipfile, sys, hashlib, os, re

apk = r"C:\Users\17948\DoubaoWork\chats\2026-10-22\new-chat-1\JZMusicHelperAndroid\app\build\outputs\apk\release\app-release.apk"
out = []

with zipfile.ZipFile(apk) as z:
    names = z.namelist()
    bad = z.testzip()
    out.append("zip_entries=%d" % len(names))
    out.append("zip_broken=%s" % (bad or "none"))
    dexes = [n for n in names if re.match(r"classes\d*\.dex$", n)]
    out.append("dex=%s" % ",".join(dexes))
    found_lyrics = False
    found_view = False
    found_ver = False
    for d in dexes:
        data = z.read(d)
        if b"Lcom/jz/musichelper/data/DesktopLyrics;" in data:
            found_lyrics = True
        if b"Lcom/jz/musichelper/ui/DesktopLyricsView;" in data:
            found_view = True
        if b"2.1.74" in data:
            found_ver = True
    out.append("dex_has_DesktopLyrics=%s" % found_lyrics)
    out.append("dex_has_DesktopLyricsView=%s" % found_view)
    out.append("dex_has_version_2.1.74=%s" % found_ver)

size = os.path.getsize(apk)
md5 = hashlib.md5(open(apk, "rb").read()).hexdigest().upper()
out.append("size=%d" % size)
out.append("md5=%s" % md5)

txt = "\n".join(out)
print(txt)
open(r"C:\Users\17948\DoubaoWork\chats\2026-10-22\new-chat-1\_tmp_build\verify_2174.txt", "w", encoding="utf-8").write(txt + "\n")
