# -*- coding: utf-8 -*-
"""对笒音里提取到的酷我端点做只读探活（不改动任何数据）。"""
import io
import json
import urllib.parse
import urllib.request

OUT = r"C:\Users\17948\DoubaoWork\chats\2026-10-22\new-chat-1\_tmp_build\re_probe.txt"
UA = "Mozilla/5.0 (Linux; Android 13) AppleWebKit/537.36 Mobile Safari/537.36"


def get(url, referer="https://www.kuwo.cn/"):
    req = urllib.request.Request(url, headers={"User-Agent": UA, "Referer": referer})
    try:
        with urllib.request.urlopen(req, timeout=12) as r:
            body = r.read()
            return r.status, body
    except Exception as e:
        return None, str(e).encode()


lines = []


def log(t):
    lines.append(t)
    print(t)


q = urllib.parse.quote("周杰伦")
cases = [
    ("searchKey-无cookie", "https://www.kuwo.cn/openapi/v1/www/search/searchKey?key=%s&pn=1&rn=5&httpsStatus=1" % q),
    ("searchKey-带reqId", "https://www.kuwo.cn/openapi/v1/www/search/searchKey?key=%s&pn=1&rn=5&httpsStatus=1&reqId=1" % q),
    ("discover-v0", "https://www.kuwo.cn/openapi/v1/recommend/discover/v0?httpsStatus=1"),
    ("mobi.s-裸", "https://mobi.kuwo.cn/mobi.s?f=kuwo&q="),
]
for name, url in cases:
    st, body = get(url)
    txt = body[:600].decode("utf-8", "ignore").replace("\n", " ")
    log("### %s  status=%s" % (name, st))
    log(txt)
    log("")

io.open(OUT, "w", encoding="utf-8").write("\n".join(lines) + "\n")
