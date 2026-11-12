# -*- coding: utf-8 -*-
"""对专辑/歌单/榜单类端点做只读探活，记录是否可直接调用。"""
import io
import urllib.request

OUT = r"C:\Users\17948\DoubaoWork\chats\2026-10-22\new-chat-1\_tmp_build\re_probe_web.txt"
UA = "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 Chrome/120 Safari/537.36"
lines = []


def get(name, url):
    req = urllib.request.Request(url, headers={"User-Agent": UA, "Referer": "https://www.kuwo.cn/"})
    try:
        with urllib.request.urlopen(req, timeout=12) as r:
            body = r.read().decode("utf-8", "ignore")
        lines.append("### %s  %s  len=%d" % (name, r.status, len(body)))
        lines.append(body[:400].replace("\n", " "))
    except Exception as e:
        lines.append("### %s  ERR %s" % (name, e))
    lines.append("")


get("albumInfo", "https://www.kuwo.cn/api/www/album/albumInfo?albumId=64938100&pn=0&rn=10")
get("playListInfo", "https://www.kuwo.cn/newh5app/wapi/api/www/playlist/playListInfo?pid=22822504&pn=0&rn=10")
get("playlist-detail", "https://www.kuwo.cn/api/playlist/detail?id=22822504")
get("getRcmPlayList", "https://www.kuwo.cn/api/pc/classify/playlist/getRcmPlayList?pn=1&rn=10")
get("getTagPlayList", "https://www.kuwo.cn/api/pc/classify/playlist/getTagPlayList?id=100&pn=1&rn=10")
get("comment", "https://comment.kuwo.cn/com.s?f=kuwo&q=")

io.open(OUT, "w", encoding="utf-8").write("\n".join(lines) + "\n")
print("\n".join(lines))
