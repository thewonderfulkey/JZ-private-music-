# -*- coding: utf-8 -*-
"""抓取参数名与签名相关线索。"""
import io
import os
import re

TMP = r"C:\Users\17948\DoubaoWork\chats\2026-10-22\new-chat-1\_tmp_build\re_libs"
OUT = r"C:\Users\17948\DoubaoWork\chats\2026-10-22\new-chat-1\_tmp_build\re_params.txt"

KEYS = ["httpsStatus", "reqId", "musicId", "musicid", "vipver", "ft=", "cluster", "rformat",
        "mobi.s", "f=kuwo", "csrf", "sign", "signature", "secret", "appid", "app_id", "token",
        "key=", "pn=", "rn=", "plat", "client", "userid", "uid=", "type=", "query", "keyword",
        "songId", "albumId", "artistId", "cover", "pic", "img", "lyric", "songurl", "playurl",
        "br=", "format", "quality", "level", "hq", "sq", "lossless", "mflac", "mgg", "qrc",
        "krc", "encrypt", "decrypt", "aes", "rsa", "md5", "sha"]

lines = []
for name in ["libapp.so", "libcenbridge.so", "libMflacCrypto.so"]:
    p = os.path.join(TMP, name)
    if not os.path.exists(p):
        continue
    data = open(p, "rb").read()
    lines.append("### %s (%d B)" % (name, len(data)))
    for k in KEYS:
        n = 0
        for m in re.finditer(re.escape(k).encode(), data, re.I):
            n += 1
            if n > 6:
                break
            a = max(0, m.start() - 70)
            b = min(len(data), m.end() + 70)
            txt = "".join(chr(c) if 32 <= c < 127 else "." for c in data[a:b])
            lines.append("[%-11s] %06x %s" % (k, m.start(), txt))
    lines.append("")

io.open(OUT, "w", encoding="utf-8").write("\n".join(lines) + "\n")
print("ok", len(lines))
