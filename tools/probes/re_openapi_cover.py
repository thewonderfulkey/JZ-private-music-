# -*- coding: utf-8 -*-
"""openapi music/playUrl 覆盖率：多歌手取样，统计成功/付费/下线，并核验返回 URL 是否为整曲。"""
import io
import json
import re
import urllib.parse
import urllib.request

OUT = r"C:\Users\17948\DoubaoWork\chats\2026-10-22\new-chat-1\_tmp_build\re_openapi_cover.txt"
UA_WEB = "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/120 Safari/537.36"
lines = []


def fetch(url, headers=None, timeout=12):
    h = {"User-Agent": UA_WEB, "Referer": "https://www.kuwo.cn/", "Accept": "application/json"}
    if headers:
        h.update(headers)
    with urllib.request.urlopen(urllib.request.Request(url, headers=h), timeout=timeout) as r:
        return r.read().decode("utf-8", "ignore")


def search(keyword, rn=20):
    u = ("https://search.kuwo.cn/r.s?all=%s&ft=music&rn=%d&pn=1&rformat=json&encoding=utf8"
         "&vipver=MUSIC_8.7.8.0_WX" % (urllib.parse.quote(keyword), rn))
    t = fetch(u, headers={"User-Agent": "kwplayer_ar_12.0.6.4"})
    rids = re.findall(r"MUSICRID':'MUSIC_(\d+)", t)
    names = re.findall(r"SONGNAME':'([^']*)'", t) or re.findall(r"NAME':'([^']*)'", t)
    return list(zip(rids, names))


def play_url(rid):
    u = "https://www.kuwo.cn/openapi/v1/www/music/playUrl?mid=%s&type=music&httpsStatus=1" % rid
    t = fetch(u)
    try:
        return json.loads(t)
    except Exception:
        return {"raw": t[:120]}


def audio_total(url):
    req = urllib.request.Request(url, headers={"User-Agent": UA_WEB, "Range": "bytes=0-0"})
    with urllib.request.urlopen(req, timeout=12) as r:
        cr = r.headers.get("Content-Range") or ""
        return int(cr.split("/")[-1]) if "/" in cr else -1


stats = {"ok": 0, "vip": 0, "off": 0, "other": 0}
for singer in ("周杰伦", "陈奕迅", "五月天", "林俊杰"):
    pairs = search(singer)[:10]
    lines.append("-- %s：解析 %d 条 --" % (singer, len(pairs)))
    for rid, name in pairs:
        obj = play_url(rid)
        code = obj.get("code")
        if code == 200 and obj.get("data", {}).get("url"):
            url = obj["data"]["url"]
            try:
                total = audio_total(url)
            except Exception as e:
                total = "取流失败:%s" % e
            stats["ok"] += 1
            lines.append("   %-16s rid=%-10s OK %s %sB" % (name[:16], rid, url.split("?")[0][-24:], total))
        elif code == -1:
            stats["vip"] += 1
            lines.append("   %-16s rid=%-10s 付费" % (name[:16], rid))
        elif code == -1001:
            stats["off"] += 1
            lines.append("   %-16s rid=%-10s 已下线" % (name[:16], rid))
        else:
            stats["other"] += 1
            lines.append("   %-16s rid=%-10s 其它 %s" % (name[:16], rid, obj))

lines.append("")
lines.append("统计：成功 %(ok)d / 付费 %(vip)d / 下线 %(off)d / 其它 %(other)d" % stats)

io.open(OUT, "w", encoding="utf-8").write("\n".join(lines) + "\n")
print("\n".join(lines))
