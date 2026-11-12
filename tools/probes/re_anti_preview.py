# -*- coding: utf-8 -*-
"""两个判定：1) anti.s 那个 181521B 是不是所有曲目同一份试听样片（取首 64KB 算 md5）；
2) 酷我 openapi 族有没有匿名可用的 playUrl。"""
import hashlib
import io
import urllib.request

OUT = r"C:\Users\17948\DoubaoWork\chats\2026-10-22\new-chat-1\_tmp_build\re_anti_preview.txt"
UA = "kwplayer_ar_12.0.6.4"
RIDS = ["728676", "3197116", "126087"]
lines = []


def anti(rid):
    u = ("https://antiserver.kuwo.cn/anti.s?type=convert_url3&format=mp3&response=url&br=320kmp3&rid=%s" % rid)
    with urllib.request.urlopen(urllib.request.Request(u, headers={"User-Agent": UA}), timeout=12) as r:
        import json
        return json.loads(r.read().decode()).get("url", "")


lines.append("== anti.s 返回内容指纹 ==")
for rid in RIDS:
    u = anti(rid)
    req = urllib.request.Request(u, headers={"User-Agent": UA, "Range": "bytes=0-65535"})
    with urllib.request.urlopen(req, timeout=12) as r:
        head = r.read()
    lines.append("%s md5(first64K)=%s size16=%d" % (rid, hashlib.md5(head).hexdigest(), len(head)))

lines.append("")
lines.append("== openapi 族 playUrl 试探 ==")
CANDS = [
    "https://www.kuwo.cn/openapi/v1/www/music/playUrl?musicId=728676&httpsStatus=1",
    "https://www.kuwo.cn/openapi/v1/www/music/playUrl?mid=728676&httpsStatus=1",
    "https://www.kuwo.cn/openapi/v1/www/song/playUrl?mid=728676&httpsStatus=1",
    "https://www.kuwo.cn/openapi/v1/www/music/playUrl?rid=728676&type=music&httpsStatus=1",
]
for u in CANDS:
    try:
        req = urllib.request.Request(u, headers={"User-Agent": "Mozilla/5.0", "Referer": "https://www.kuwo.cn/"})
        with urllib.request.urlopen(req, timeout=12) as r:
            lines.append("%-70s %s :: %s" % (u.split("?")[0].split("/openapi")[-1], r.status,
                                             r.read(300).decode("utf-8", "ignore").replace("\n", " ")))
    except Exception as e:
        lines.append("%-70s ERR %s" % (u.split("?")[0], e))

io.open(OUT, "w", encoding="utf-8").write("\n".join(lines) + "\n")
print("\n".join(lines))
