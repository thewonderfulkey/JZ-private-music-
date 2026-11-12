# -*- coding: utf-8 -*-
"""从 Flutter AOT 快照与原生库里抽 API 线索。"""
import io
import os
import re
import zipfile

APK = r"C:\Users\17948\DoubaoWork\chats\2026-10-22\new-chat-1\lark-im-resources\file_v3_0017b_7d1a3d77-04bb-49d2-b75c-8f0330b1745g.apk"
TMP = r"C:\Users\17948\DoubaoWork\chats\2026-10-22\new-chat-1\_tmp_build\re_libs"
OUT = r"C:\Users\17948\DoubaoWork\chats\2026-10-22\new-chat-1\_tmp_build\re_strings.txt"

if not os.path.isdir(TMP):
    os.makedirs(TMP)

z = zipfile.ZipFile(APK)
targets = [n for n in z.namelist() if n.endswith("libapp.so") or n.endswith("libcenbridge.so")
           or n.endswith("libMflacCrypto.so")]
paths = []
for n in targets:
    p = os.path.join(TMP, os.path.basename(n))
    with open(p, "wb") as f:
        f.write(z.read(n))
    paths.append(p)
    print("extracted", n, os.path.getsize(p))

# 可读 ASCII 串（>=6 字符），Dart AOT 的字符串常量多在这里
STR = re.compile(rb"[ -~]{6,}")
HOST = re.compile(rb"^(?:https?://)?([a-z0-9][a-z0-9.\-]+\.(?:com|cn|net|org|io|xyz|top|vip|cc|me|app|tv))(?::\d+)?(.*)$", re.I)

urls, hosts, paths_like = set(), {}, set()
for p in paths:
    data = open(p, "rb").read()
    for m in STR.finditer(data):
        s = m.group().decode("latin-1")
        if "://" in s or s.startswith("/") or "?" in s:
            if s.startswith("http") or s.startswith("//"):
                urls.add(s[:400])
                hm = HOST.match(s.encode("latin-1"))
                if hm:
                    h = hm.group(1).decode().lower()
                    hosts.setdefault(h, 0)
                    hosts[h] += 1
            elif s.startswith("/") and len(s) < 200:
                paths_like.add(s)

lines = []
lines.append("== URLs (%d) ==" % len(urls))
for u in sorted(urls)[:200]:
    lines.append(u)
lines.append("")
lines.append("== hosts ==")
for h, c in sorted(hosts.items(), key=lambda x: -x[1]):
    lines.append("%5d  %s" % (c, h))
lines.append("")
lines.append("== path-like (%d) ==" % len(paths_like))
for s in sorted(paths_like)[:300]:
    lines.append(s)

io.open(OUT, "w", encoding="utf-8").write("\n".join(lines) + "\n")
print("written", OUT, len(lines))
