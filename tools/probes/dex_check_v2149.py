# -*- coding: utf-8 -*-
import zipfile, io, os, sys
apk = r"JZMusicHelperAndroid\app\build\outputs\apk\release\app-release.apk"
z = zipfile.ZipFile(apk)
bad = z.testzip()
print("ZIP_BAD_ENTRY:", bad if bad else "none")
ents = z.namelist()
print("ENTRIES:", len(ents))
dexes = [n for n in ents if n.endswith(".dex")]
print("DEX:", dexes)
blob = b""
for n in dexes:
    blob += z.read(n)
need = ["妖狐酷我返回变体版本", "DownloadResolver", "resolveForDownload",
        "该曲最高只有", "已换源", "拿不到所选音质会自动换源", "2.1.49", "107"]
missing = []
for s in need:
    hit = s.encode("utf-8") in blob
    print("DEX_HAS %-32s %s" % (s, hit))
    if not hit: missing.append(s)
gone = ["SourceProbe"]
for s in gone:
    hit = s.encode("utf-8") in blob
    print("DEX_GONE %-31s %s" % (s, not hit))
# 类名清单里确认 DownloadResolver 类
cls = [n for n in ents if n.startswith("classes") and n.endswith(".dex")]
print("MISSING:", missing if missing else "none")
z.close()