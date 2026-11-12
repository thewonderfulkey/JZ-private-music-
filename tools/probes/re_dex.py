# -*- coding: utf-8 -*-
"""扫描 classes.dex 与 manifest 里的域名与接口线索。"""
import io
import re
import zipfile

APK = r"C:\Users\17948\DoubaoWork\chats\2026-10-22\new-chat-1\lark-im-resources\file_v3_0017b_7d1a3d77-04bb-49d2-b75c-8f0330b1745g.apk"
OUT = r"C:\Users\17948\DoubaoWork\chats\2026-10-22\new-chat-1\_tmp_build\re_dex.txt"

z = zipfile.ZipFile(APK)
dex = z.read("classes.dex")
man = z.read("AndroidManifest.xml")

# dex 里的 MUTF-8 串：直接按可读序列扫
tok = re.compile(rb"[ -~]{5,}")
strings = [m.group().decode("latin-1") for m in tok.finditer(dex)]
dom = re.compile(r"(?:https?://)?((?:[a-z0-9\-]+\.)+(?:com|cn|net|org|io|xyz|top|vip|me|tv|app))", re.I)

lines = []
lines.append("== dex strings: domains ==")
seen = {}
for s in strings:
    for m in dom.finditer(s):
        d = m.group(1).lower()
        seen.setdefault(d, 0)
        seen[d] += 1
for d, c in sorted(seen.items(), key=lambda x: -x[1]):
    if any(k in d for k in ("cenmusic", "kuwo", "qq", "kugou", "163", "migu", "bilibili", "douyin", "soda")):
        lines.append("%4d  %s" % (c, d))
lines.append("")
lines.append("== dex strings with cenmusic ==")
for s in strings:
    if "cenmusic" in s.lower():
        lines.append(s)
lines.append("")
lines.append("== dex strings: http-ish ==")
for s in strings:
    if "http" in s.lower() and len(s) < 200:
        lines.append(s)

lines.append("")
lines.append("== manifest utf16 strings ==")
txt = man.decode("utf-16-le", "ignore")
for s in re.findall(r"[ -~]{4,}", txt):
    if any(k in s.lower() for k in ("permission", "activity", "service", "provider", "receiver", "cenmusic")):
        lines.append(s)

io.open(OUT, "w", encoding="utf-8").write("\n".join(lines) + "\n")
print("strings", len(strings), "out", len(lines))
