# -*- coding: utf-8 -*-
"""验证封面三种 base 的真实拼法。"""
import io
import urllib.request

OUT = r"C:\Users\17948\DoubaoWork\chats\2026-10-22\new-chat-1\_tmp_build\re_probe_cover2.txt"
UA = "Mozilla/5.0 (Linux; Android 13) AppleWebKit/537.36 Mobile Safari/537.36"
lines = []


def head(url):
    req = urllib.request.Request(url, headers={"User-Agent": UA, "Referer": "https://www.kuwo.cn/"})
    try:
        with urllib.request.urlopen(req, timeout=10) as r:
            b = r.read(48)
            return "OK  %s  %s  %r  %s" % (r.status, r.headers.get("Content-Type"), b[:8], url)
    except Exception as e:
        return "ERR %s  %s" % (e, url)


urls = [
    "http://img2.kuwo.cn/star/albumcover/300/s4s60/3/1960699163.jpg",
    "https://img1.kuwo.cn/wmvpic/324/s4s36/41/926857763.jpg",
    "https://img1.kuwo.cn/wmvpic/240/324/s4s36/41/926857763.jpg",
    "https://img4.kuwo.cn/star/albumcover/324/s4s36/41/926857763.jpg",
    "https://img4.kuwo.cn/star/albumcover/240/324/s4s36/41/926857763.jpg",
    "https://img1.kuwo.cn/star/starheads/5357.jpg",
    "https://img1.kuwo.cn/star/starheads/240/5357.jpg",
]
for u in urls:
    lines.append(head(u))

io.open(OUT, "w", encoding="utf-8").write("\n".join(lines) + "\n")
print("\n".join(lines))
