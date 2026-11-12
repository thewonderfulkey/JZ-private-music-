# -*- coding: utf-8 -*-
"""v2.1.64 出包静态验证：完整性 / 版本 / 字体 / dex 内新增逻辑命中。"""
import io, hashlib, os, zipfile

APK = r"C:\Users\17948\DoubaoWork\chats\2026-10-22\new-chat-1\JZMusicHelperAndroid\app\build\outputs\apk\release\app-release.apk"
OUT = r"C:\Users\17948\DoubaoWork\chats\2026-10-22\new-chat-1\_tmp_build\verify_2164.txt"

log = []
with zipfile.ZipFile(APK) as z:
    bad = z.testzip()
    names = z.namelist()
    log.append("zip_test=%s entries=%d" % ("OK" if bad is None else "BAD:" + str(bad), len(names)))
    log.append("has_font=%s(%d) has__S=%s(%d)" % (
        "res/35.ttf" in names, z.getinfo("res/35.ttf").file_size if "res/35.ttf" in names else -1,
        "res/_S.ttf" in names, z.getinfo("res/_S.ttf").file_size if "res/_S.ttf" in names else -1))
    dex_blob = b""
    for n in names:
        if n.startswith("classes") and n.endswith(".dex"):
            dex_blob += z.read(n)
    for s in ["2.1.64", "256..600", "48..255", "体积校验", "换源中", "requestedQuality"]:
        log.append("dex_has(%s)=%s" % (s, s.encode("utf-8") in dex_blob))

md5 = hashlib.md5(open(APK, "rb").read()).hexdigest().upper()
log.append("size=%d md5=%s" % (os.path.getsize(APK), md5))
io.open(OUT, "w", encoding="utf-8").write("\n".join(log))
print("\n".join(log))
