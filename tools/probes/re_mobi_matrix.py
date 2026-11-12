# -*- coding: utf-8 -*-
"""对 mobi.kuwo.cn/mobi.s 的 q 形态做小矩阵试探（只读 GET），看哪种能被服务端解析。"""
import base64
import io
import urllib.parse
import urllib.request

OUT = r"C:\Users\17948\DoubaoWork\chats\2026-10-22\new-chat-1\_tmp_build\re_mobi_matrix.txt"
UA = "kwplayer_ar_12.0.6.4"
lines = []

RID = "456593448"
PLAIN = ("corp=kuwo&source=kwplayer_ar_12.0.6.4&type=convert_url"
         "&br=320kmp3&rid=%s&format=mp3&response=url" % RID)


def des_ecb_b64(text, key=b"ylzsxkwm"):
    from Crypto.Cipher import DES
    from Crypto.Util.Padding import pad
    c = DES.new(key, DES.MODE_ECB)
    return base64.b64encode(c.encrypt(pad(text.encode("utf-8"), 8))).decode()


VARIANTS = [
    ("plain-urlencoded", PLAIN, "raw"),
    ("b64-std", PLAIN, "b64"),
    ("b64-url", PLAIN, "b64url"),
    ("des-ecb-ylzsxkwm-b64", PLAIN, "desb64"),
    ("des-ecb-无padding-b64", PLAIN, "desnopad"),
]


def call(name, q):
    url = "https://mobi.kuwo.cn/mobi.s?f=kuwo&q=" + urllib.parse.quote(q, safe="")
    req = urllib.request.Request(url, headers={"User-Agent": UA})
    try:
        with urllib.request.urlopen(req, timeout=12) as r:
            body = r.read(600).decode("utf-8", "ignore")
        return "%-26s %s len<=600 :: %s" % (name, r.status, body.replace("\n", " ")[:260])
    except Exception as e:
        return "%-26s ERR %s" % (name, e)


# 对照组
lines.append(call("empty-q", ""))
for name, plain, mode in VARIANTS:
    if mode == "raw":
        q = plain
    elif mode == "b64":
        q = base64.b64encode(plain.encode()).decode()
    elif mode == "b64url":
        q = base64.urlsafe_b64encode(plain.encode()).decode().rstrip("=")
    elif mode == "desb64":
        q = des_ecb_b64(plain)
    else:
        from Crypto.Cipher import DES
        c = DES.new(b"ylzsxkwm", DES.MODE_ECB)
        q = base64.b64encode(c.encrypt(plain.encode().ljust(64, b"\0")[:64])).decode()
    lines.append(call(name, q))

io.open(OUT, "w", encoding="utf-8").write("\n".join(lines) + "\n")
print("\n".join(lines))
