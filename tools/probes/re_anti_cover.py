# -*- coding: utf-8 -*-
"""用项目里同款搜索参数取 rid，再逐曲看 anti.s 返回文件总字节数——判断是整曲还是试听片段。"""
import io
import json
import re
import urllib.parse
import urllib.request

OUT = r"C:\Users\17948\DoubaoWork\chats\2026-10-22\new-chat-1\_tmp_build\re_anti_cover.txt"
UA = "kwplayer_ar_12.0.6.4"
lines = []


def fetch(url, headers=None, timeout=15):
    h = {"User-Agent": UA, "Referer": "https://www.kuwo.cn/"}
    if headers:
        h.update(headers)
    with urllib.request.urlopen(urllib.request.Request(url, headers=h), timeout=timeout) as r:
        return r.read().decode("utf-8", "ignore"), r.headers


def search(keyword, rn=20):
    u = ("https://search.kuwo.cn/r.s?all=%s&ft=music&rn=%d&pn=1&rformat=json&encoding=utf8"
         "&vipver=MUSIC_8.7.8.0_WX" % (urllib.parse.quote(keyword), rn))
    text, _ = fetch(u)
    body = re.findall(r"MUSICRID':'MUSIC_(\d+)", text)
    names = re.findall(r"SONGNAME':'([^']*)'", text) or re.findall(r"NAME':'([^']*)'", text)
    return list(zip(body, names))


def anti(rid, fmt="mp3", br="320kmp3"):
    u = ("https://antiserver.kuwo.cn/anti.s?type=convert_url3&format=%s&response=url&br=%s&rid=%s"
         % (fmt, br, rid))
    text, _ = fetch(u, timeout=12)
    try:
        obj = json.loads(text)
    except Exception:
        return None, text[:80]
    return obj.get("url") or None, obj.get("msg")


def size_of(url):
    req = urllib.request.Request(url, headers={"User-Agent": UA, "Range": "bytes=0-0"})
    with urllib.request.urlopen(req, timeout=12) as r:
        cr = r.headers.get("Content-Range") or ""
    return int(cr.split("/")[-1]) if "/" in cr else -1


lines.append("== 每曲 anti.s 320k 返回总字节数（< 500KB 视为试听片段）==")
ok = full = 0
for singer in ("周杰伦", "陈奕迅"):
    pairs = search(singer)[:8]
    lines.append("-- %s：解析 %d 条 --" % (singer, len(pairs)))
    for rid, name in pairs:
        try:
            url, msg = anti(rid)
            if not url:
                lines.append("   %-14s rid=%s 无url %s" % (name[:14], rid, msg))
                continue
            b = size_of(url)
            ok += 1
            if b > 500_000:
                full += 1
            lines.append("   %-14s rid=%-10s %8dB %s" % (name[:14], rid, b, "整曲" if b > 500_000 else "片段"))
        except Exception as e:
            lines.append("   %-14s rid=%s ERR %s" % (name[:14], rid, e))

lines.append("")
lines.append("成功取到 URL %d 条，其中整曲 %d 条" % (ok, full))

io.open(OUT, "w", encoding="utf-8").write("\n".join(lines) + "\n")
print("\n".join(lines))
