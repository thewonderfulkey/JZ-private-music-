# -*- coding: utf-8 -*-
"""复现两条真实查询（逐个 try，网络抖动不影响整体）：酷我英文查询 / 酷狗搜索通道现状。"""
import io
import re
import urllib.parse
import urllib.request

OUT = r"C:\Users\17948\DoubaoWork\chats\2026-10-22\new-chat-1\_tmp_build\re_search_probe.txt"
lines = []


def get(url, ua="kwplayer_ar_12.0.6.4", ref="https://www.kuwo.cn/", timeout=15, limit=1400):
    req = urllib.request.Request(url, headers={"User-Agent": ua, "Referer": ref})
    with urllib.request.urlopen(req, timeout=timeout) as r:
        return r.status, r.read().decode("utf-8", "ignore")[:limit]


def probe(name, url, ua="kwplayer_ar_12.0.6.4", ref="https://www.kuwo.cn/"):
    try:
        st, body = get(url, ua=ua, ref=ref)
        lines.append("OK   %-22s %s len=%d" % (name, st, len(body)))
        return body
    except Exception as e:
        lines.append("ERR  %-22s %s" % (name, e))
        return ""


KW = "IVORY TOWER"
BASE = ("https://search.kuwo.cn/r.s?all=%s&ft=music&rn=20&pn=1&rformat=json&encoding=utf8"
        "&vipver=MUSIC_8.7.8.0_WX")

body = probe("kuwo r.s 大写", BASE % urllib.parse.quote(KW))
rids = re.findall(r"MUSICRID':'MUSIC_(\d+)", body)
names = re.findall(r"SONGNAME':'([^']*)'", body)
artists = re.findall(r"ARTIST':'([^']*)'", body)
lines.append("   rid=%d name=%d artist=%d；头部：%s" %
             (len(rids), len(names), len(artists),
              body[:body.find("MUSICRID") if "MUSICRID" in body else 200].replace("\r", " ")[:400]))
for i in range(min(10, len(rids))):
    lines.append("   %s | %s | %s" % (rids[i], names[i] if i < len(names) else "?", artists[i] if i < len(artists) else "?"))

body2 = probe("kuwo r.s 小写", BASE % urllib.parse.quote("ivory tower"))
lines.append("   小写命中 rid=%d" % len(re.findall(r"MUSICRID':'MUSIC_(\d+)", body2)))

lines.append("-- 酷狗 --")
for name, url, ua, ref in [
    ("kg mobilecdn", "https://mobilecdn.kugou.com/api/v3/search/song?format=json&keyword=%s&page=1&pagesize=10" % urllib.parse.quote(KW),
     "Mozilla/5.0 (Linux; Android 10)", "https://m.kugou.com/"),
    ("kg songsearch", "https://songsearch.kugou.com/song_search_v2?keyword=%s&page=1&pagesize=10" % urllib.parse.quote(KW),
     "Mozilla/5.0 (Linux; Android 10)", "https://www.kugou.com/"),
]:
    b = probe(name, url, ua=ua, ref=ref)
    if b:
        lines.append("   " + b.replace("\n", " ")[:220])

io.open(OUT, "w", encoding="utf-8").write("\n".join(lines) + "\n")
print("\n".join(lines))
