# -*- coding: utf-8 -*-
import zipfile, os, hashlib, re
apk = r"C:\Users\17948\DoubaoWork\chats\2026-10-22\new-chat-1\JZMusicHelperAndroid\app\build\outputs\apk\release\app-release.apk"
out = []
z = zipfile.ZipFile(apk)
bad = z.testzip()
out.append("zip_testzip=%s" % ("OK" if bad is None else "BAD:" + str(bad)))
names = z.namelist()
out.append("entries=%d  size=%d" % (len(names), os.path.getsize(apk)))
out.append("md5=%s" % hashlib.md5(open(apk, 'rb').read()).hexdigest())
res = [n for n in names if re.search(r'res/[A-Za-z0-9_\-]*/', n) and any(k in n for k in
        ('splash_ink', 'splash_tree', 'splash_flow', 'splash_pool'))]
out.append("-- splash 资源条目 --")
for n in sorted(res):
    info = z.getinfo(n)
    out.append("  %-60s %d B" % (n, info.file_size))
out.append("-- AndroidManifest 组件 --")
mani = z.read('AndroidManifest.xml')
out.append("manifest bytes=%d" % len(mani))
dx = [n for n in names if n.endswith('.dex')]
out.append("dex: " + ", ".join("%s=%d" % (n, z.getinfo(n).file_size) for n in dx))
open(r"C:\Users\17948\DoubaoWork\chats\2026-10-22\new-chat-1\_tmp_build\v2152_zip.txt", "w", encoding="utf-8").write("\n".join(out))
print("\n".join(out))
