# -*- coding: utf-8 -*-
"""试酷我另一族官方取流：antiserver 的 anti.s（老客户端/开放项目常用），以及 www 的 /url 通道。"""
import io
import urllib.request

OUT = r"C:\Users\17948\DoubaoWork\chats\2026-10-22\new-chat-1\_tmp_build\re_anti.txt"
RID = "456593448"
UA_KW = "kwplayer_ar_12.0.6.4"
UA_WEB = "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/120 Safari/537.36"
lines = []

URLS = [
    ("anti convert_url rid", "https://antiserver.kuwo.cn/anti.s?type=convert_url&format=mp3&response=url&rid=%s" % RID),
    ("anti convert_url MUSIC_", "https://antiserver.kuwo.cn/anti.s?type=convert_url&format=mp3&response=url&rid=MUSIC_%s" % RID),
    ("anti convert_url3 br", "https://antiserver.kuwo.cn/anti.s?type=convert_url3&format=mp3&response=url&br=320kmp3&rid=%s" % RID),
    ("anti convert_url aac", "https://antiserver.kuwo.cn/anti.s?type=convert_url&format=aac&response=url&rid=%s" % RID),
    ("www /url convert_url3", "https://www.kuwo.cn/url?format=mp3&rid=%s&response=url&type=convert_url3&br=128kmp3&from=web" % RID),
    ("www /url convert_url", "https://www.kuwo.cn/url?format=mp3&rid=%s&response=url&type=convert_url&br=320kmp3&from=web" % RID),
]

for name, url in URLS:
    ua = UA_KW if "antiserver" in url else UA_WEB
    try:
        req = urllib.request.Request(url, headers={"User-Agent": ua, "Referer": "https://www.kuwo.cn/"})
        with urllib.request.urlopen(req, timeout=15) as r:
            body = r.read(500).decode("utf-8", "ignore")
        lines.append("%-26s %s :: %s" % (name, r.status, body.replace("\n", " ")[:300]))
    except Exception as e:
        lines.append("%-26s ERR %s" % (name, e))

io.open(OUT, "w", encoding="utf-8").write("\n".join(lines) + "\n")
print("\n".join(lines))
