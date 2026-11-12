# -*- coding: utf-8 -*-
import os, zipfile, hashlib, subprocess, sys
from PIL import Image
import io

APK = r"C:\Users\17948\DoubaoWork\chats\2026-10-22\new-chat-1\JZMusicHelperAndroid\app\build\outputs\apk\release\app-release.apk"
out = []

with zipfile.ZipFile(APK) as z:
    bad = z.testzip()
    out.append("testzip=%s entries=%d" % ("OK" if bad is None else bad, len(z.namelist())))
    out.append("apk_md5=%s" % hashlib.md5(open(APK, "rb").read()).hexdigest())
    # 素材：splash_pool / splash_flow / splash_flow_mask
    for name in ("splash_pool", "splash_flow", "splash_flow_mask", "splash_ink_main", "splash_ink_edge"):
        idx = z.read("resources.arsc")
        hit = [n for n in z.namelist() if n.startswith("res/") and n.rsplit("/", 1)[-1].split(".")[0] in
               ({"splash_pool": "ms", "splash_flow": "RE", "splash_flow_mask": "q1", "splash_ink_main": "1q", "splash_ink_edge": "7x"}[name],)]
        for n in hit:
            data = z.read(n)
            im = Image.open(io.BytesIO(data))
            a = im.convert("RGBA")
            alpha = a.getchannel("A")
            out.append("%s -> %s %dx%d mode=%s alpha_mean=%.1f size=%d" % (
                name, n, im.width, im.height, im.mode,
                (sum(alpha.getdata()) / (im.width * im.height)), len(data)))
            break

# dex 里的版本文案
dex = r"C:\Users\17948\DoubaoWork\chats\2026-10-22\new-chat-1\_tmp_build\dex_v2153"
if os.path.isdir(dex):
    pass
import zipfile as zf
with zf.ZipFile(APK) as z:
    blobs = [z.read(n) for n in z.namelist() if n.endswith(".dex")]

for tag in ("JZ的音乐助手 v2.1.53", "JZ的音乐助手 v2.1.52"):
    cnt = sum(1 for b in blobs if tag.encode("utf-8") in b)
    out.append("dex hits %s = %d" % (tag, cnt))

# adb
adb = r"C:\Users\17948\AppData\Local\Android\Sdk\platform-tools\adb.exe"
r = subprocess.run([adb, "devices"], capture_output=True, text=True)
out.append("adb devices -> " + repr(r.stdout.strip()))

p = os.path.join(os.path.dirname(APK), "..", "..", "..", "..", "..", "..", "_tmp_build", "v2153_zipcheck.txt")
txt = "\n".join(out)
open(r"C:\Users\17948\DoubaoWork\chats\2026-10-22\new-chat-1\_tmp_build\v2153_zipcheck.txt", "w", encoding="utf-8").write(txt)
print(txt)
