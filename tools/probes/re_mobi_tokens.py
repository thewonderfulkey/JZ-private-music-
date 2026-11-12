# -*- coding: utf-8 -*-
"""1) 看 libapp.so 里 mobi.s 请求参数的字面量线索；2) 看本机可用的 DES 实现。"""
import io
import re

SO = r"C:\Users\17948\DoubaoWork\chats\2026-10-22\new-chat-1\_tmp_build\re_libs\libapp.so"
OUT = r"C:\Users\17948\DoubaoWork\chats\2026-10-22\new-chat-1\_tmp_build\re_mobi_tokens.txt"
lines = []

data = open(SO, "rb").read()
tokens = [m.group().decode("latin-1") for m in re.finditer(rb"[ -~]{2,}", data)]
printable = set(tokens)

keys = ["corp", "source", "convert_url", "&br", "br=", "sig", "rid=", "response", "format=",
        "kuwo", "des", "3des", "base64", "encrypt", "crypt", "q="]
lines.append("== 命中 token（去重，按长度倒序）==")
hits = sorted((t for t in printable if any(k in t for k in keys) and len(t) <= 120),
              key=len, reverse=True)
for t in hits[:200]:
    lines.append(repr(t))

lines.append("")
lines.append("== 精确查找 ==")
for probe in (b"corp=", b"&source=", b"source=kwplayer", b"convert_url&", b"convert_url_with_sign&",
              b"&br=", b"&sig=", b"&rid=", b"&format=", b"&response=", b"&f="):
    idx = data.find(probe)
    lines.append("%-28s %s" % (probe.decode(), hex(idx) if idx >= 0 else "none"))

# DES 可用性
lines.append("")
lines.append("== 本机加密库 ==")
try:
    import Crypto
    from Crypto.Cipher import DES
    lines.append("pycryptodome: YES")
except Exception as e:
    lines.append("pycryptodome: NO (%s)" % e)
try:
    from cryptography.hazmat.primitives.ciphers import Cipher
    lines.append("cryptography: YES")
except Exception as e:
    lines.append("cryptography: NO (%s)" % e)

io.open(OUT, "w", encoding="utf-8").write("\n".join(lines) + "\n")
print("\n".join(lines[:60]))
