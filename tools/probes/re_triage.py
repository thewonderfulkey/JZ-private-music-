# -*- coding: utf-8 -*-
"""笒音 base.apk 静态分诊：dex 有效性 / 原生库 / 壳特征 / 资产清单。"""
import io
import os
import re
import zipfile

APK = r"C:\Users\17948\DoubaoWork\chats\2026-10-22\new-chat-1\lark-im-resources\file_v3_0017b_7d1a3d77-04bb-49d2-b75c-8f0330b1745g.apk"
OUT = r"C:\Users\17948\DoubaoWork\chats\2026-10-22\new-chat-1\_tmp_build\re_triage.txt"

lines = []


def w(s):
    lines.append(s)
    print(s)


z = zipfile.ZipFile(APK)
names = z.namelist()
w("entries=%d" % len(names))

dexs = [n for n in names if re.match(r"classes\d*\.dex$", n)]
so = [n for n in names if n.endswith(".so")]
w("dex: %s" % dexs)
for n in dexs:
    head = z.read(n)[:8]
    w("  %s size=%d magic=%r" % (n, z.getinfo(n).file_size, head))

w("so count=%d" % len(so))
libs = sorted({os.path.basename(n) for n in so})
for n in libs:
    w("  lib %s  (%d arch(s))" % (n, sum(1 for x in so if os.path.basename(x) == n)))

SUSPECT = ["libjiagu", "libshella", "libshellx", "libDexHelper", "libchaosvmp", "libexecso",
           "libmobisec", "libnesec", "libbaiduprotect", "librekiller", "libdptool", "libsgmain",
           "libsecexe", "libsecmain", "libprotect", "libapkprotect", "libnmmp", "libmsaoaidsec"]
hits = [n for n in libs if any(k.lower() in n.lower() for k in SUSPECT)]
w("packer-ish libs: %s" % (hits or "none"))

w("assets (%d):" % sum(1 for n in names if n.startswith("assets/")))
for n in [x for x in names if x.startswith("assets/")][:60]:
    w("  %s  %d" % (n, z.getinfo(n).file_size))

w("top-level dirs: %s" % sorted({n.split('/')[0] for n in names if '/' in n}))
w("manifest size=%d" % z.getinfo("AndroidManifest.xml").file_size)

io.open(OUT, "w", encoding="utf-8").write("\n".join(lines) + "\n")
