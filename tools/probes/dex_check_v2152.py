# -*- coding: utf-8 -*-
import zipfile, os, shutil, hashlib
apk = r"C:\Users\17948\DoubaoWork\chats\2026-10-22\new-chat-1\JZMusicHelperAndroid\app\build\outputs\apk\release\app-release.apk"
z = zipfile.ZipFile(apk)
out = []
needles = [b"JZ\xe7\x9a\x84\xe9\x9f\xb3\xe4\xb9\x90\xe5\x8a\xa9\xe6\x89\x8b v2.1.52",
           b"v2.1.52", b"2.1.52"]
for n in [x for x in z.namelist() if x.endswith('.dex')]:
    data = z.read(n)
    for nd in needles:
        out.append("%-14s %-40s hit=%s" % (n, nd.decode('utf-8', 'ignore')[:38], data.count(nd)))

# 纯净版副本
dst = r"C:\Users\17948\DoubaoWork\chats\2026-10-22\new-chat-1\_tmp_fb3\JZ音乐助手-v2.1.52.apk"
shutil.copyfile(apk, dst)
out.append("copy=%s size=%d md5=%s" % (dst, os.path.getsize(dst),
           hashlib.md5(open(dst, 'rb').read()).hexdigest()))
open(r"C:\Users\17948\DoubaoWork\chats\2026-10-22\new-chat-1\_tmp_build\v2152_dex.txt", "w", encoding="utf-8").write("\n".join(out))
print("\n".join(out))
