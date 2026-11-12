# -*- coding: utf-8 -*-
"""确认封面 URL 形态：wmvpic / albumcover / starheads 的尺寸段与可用性。"""
import io
import json
import urllib.request

OUT = r"C:\Users\17948\DoubaoWork\chats\2026-10-22\new-chat-1\_tmp_build\re_probe_cover.txt"
UA = "Mozilla/5.0 (Linux; Android 13) AppleWebKit/537.36 Mobile Safari/537.36"
lines = []


def head(url):
    req = urllib.request.Request(url, headers={"User-Agent": UA})
    try:
        with urllib.request.urlopen(req, timeout=10) as r:
            b = r.read(64)
            return "%s  %s  %d bytes(first64)  %s" % (r.status, r.headers.get("Content-Type"), len(b), url)
    except Exception as e:
        return "ERR %s  %s" % (e, url)


# 1) discover 全量字段
req = urllib.request.Request("https://www.kuwo.cn/openapi/v1/recommend/discover/v0?httpsStatus=1",
                             headers={"User-Agent": UA, "Referer": "https://www.kuwo.cn/"})
with urllib.request.urlopen(req, timeout=12) as r:
    data = json.loads(r.read().decode("utf-8"))
lines.append("discover items=%d" % len(data))
first = data[0]
lines.append("keys=%s" % ",".join(sorted(first.keys())))
lines.append(json.dumps({k: first[k] for k in list(first)[:18]}, ensure_ascii=False)[:1500])
lines.append("")

rid = str(first.get("musicid") or first.get("id") or "1960699163")
for u in [
    "https://img1.kuwo.cn/wmvpic/%s" % rid,
    "https://img1.kuwo.cn/wmvpic/%s/240" % rid,
    "https://img4.kuwo.cn/star/albumcover/%s" % rid,
    "https://img1.kuwo.cn/star/starheads/1",
    "https://img2.kuwo.cn/star/albumcover/300/s4s60/3/%s.jpg" % rid,
]:
    lines.append(head(u))

io.open(OUT, "w", encoding="utf-8").write("\n".join(lines) + "\n")
print("\n".join(lines))
