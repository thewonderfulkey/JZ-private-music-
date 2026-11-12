# -*- coding: utf-8 -*-
"""探活酷我歌词接口。"""
import io
import urllib.request

OUT = r"C:\Users\17948\DoubaoWork\chats\2026-10-22\new-chat-1\_tmp_build\re_probe_lyric.txt"
UA = "Mozilla/5.0 (Linux; Android 13) AppleWebKit/537.36 Mobile Safari/537.36"
lines = []
for mid in ("398013033",):
    url = "https://www.kuwo.cn/openapi/v1/www/lyric/getlyric?musicId=%s&httpsStatus=1" % mid
    req = urllib.request.Request(url, headers={"User-Agent": UA, "Referer": "https://www.kuwo.cn/"})
    try:
        with urllib.request.urlopen(req, timeout=12) as r:
            body = r.read().decode("utf-8", "ignore")
        lines.append("### %s status=%s len=%d" % (mid, r.status, len(body)))
        lines.append(body[:1200])
    except Exception as e:
        lines.append("### %s ERR %s" % (mid, e))
    lines.append("")
io.open(OUT, "w", encoding="utf-8").write("\n".join(lines) + "\n")
print("\n".join(lines))
