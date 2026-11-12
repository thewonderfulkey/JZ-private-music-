# -*- coding: utf-8 -*-
"""检查 libcenbridge.so 是否是酷我接口的 native 桥（q 的拼装与加密可能在这里）。"""
import io
import re

DIR = r"C:\Users\17948\DoubaoWork\chats\2026-10-22\new-chat-1\_tmp_build\re_libs"
OUT = r"C:\Users\17948\DoubaoWork\chats\2026-10-22\new-chat-1\_tmp_build\re_cenbridge.txt"
lines = []

FILES = ["libcenbridge.so", "libMflacCrypto.so"]
KEYS = ["kuwo", "corp", "mobi", "convert", "des", "encrypt", "decrypt", "sign", "token", "ylzs", "q=", "base64"]

for f in FILES:
    data = open(DIR + "\\" + f, "rb").read()
    lines.append("== %s  (%d B) ==" % (f, len(data)))
    strs = [m.group().decode("latin-1") for m in re.finditer(rb"[ -~]{3,}", data)]
    uniq = sorted(set(strs), key=len, reverse=True)
    hit = [s for s in uniq if any(k in s.lower() for k in KEYS)]
    for s in hit[:120]:
        lines.append("  " + repr(s))
    for probe in (b"corp", b"mobi", b"ylzsxkwm", b"kuwo"):
        idx = data.find(probe)
        lines.append("  probe %-10s %s" % (probe.decode(), hex(idx) if idx >= 0 else "none"))
    lines.append("")

io.open(OUT, "w", encoding="utf-8").write("\n".join(lines) + "\n")
print("\n".join(lines))
