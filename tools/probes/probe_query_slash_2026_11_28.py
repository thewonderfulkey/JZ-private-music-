# -*- coding: utf-8 -*-
"""2026-11-28 取证（第二组）：歌手串用 `/` 拼接后拼进搜索词，各平台还认不认。

网易歌单解析把多个歌手用 "/" 连成一个字符串（`NeteaseDiscover.song(fromTrack:)`），
`SearchQueryVariants.queries` 又原样拼成「歌名 + 歌手」当搜索词。
这里量的是"带斜杠 vs 不带斜杠"在同一批平台上的命中差异。
"""
import json
import re
import time
import urllib.parse

import requests

UA = ("Mozilla/5.0 (iPhone; CPU iPhone OS 17_0 like Mac OS X) "
      "AppleWebKit/605.1.15 (KHTML, like Gecko) Version/17.0 Mobile/15E148 Safari/604.1")

QUERIES = [
    "BABY ANGEL 林娜琏/NAYEON",     # App 实际会拼出来的（斜杠连歌手）
    "BABY ANGEL 林娜琏",            # 只取第一位歌手
    "BABY ANGEL NAYEON",
]


def enc(s):
    return urllib.parse.quote(s)


def get(url, headers=None, timeout=10):
    h = {"User-Agent": UA}
    if headers:
        h.update(headers)
    try:
        r = requests.get(url, headers=h, timeout=timeout)
        return r.status_code, r.text
    except Exception as e:  # noqa: BLE001
        return -1, "EXC %s" % type(e).__name__


def qq(q):
    url = "https://c.y.qq.com/soso/fcgi-bin/client_search_cp?p=1&n=10&w=%s&format=json" % enc(q)
    code, text = get(url, {"Referer": "https://y.qq.com/"}, 10)
    try:
        body = text.strip()
        if body.startswith("callback("):
            body = body[len("callback("):-1]
        j = json.loads(body)
        rows = (((j.get("data") or {}).get("song") or {}).get("list")) or []
        return code, ["%s | %s | %ss" % (it.get("songname"),
                                         "/".join(s.get("name", "") for s in (it.get("singer") or [])),
                                         it.get("interval")) for it in rows[:5]]
    except Exception:
        return code, ["<parse fail> %s" % text[:90]]


def kugou(q):
    url = ("https://mobiles.kugou.com/api/v3/search/song?format=json&keyword=%s&page=1"
           "&pagesize=10&showtype=1" % enc(q))
    code, text = get(url, {"Referer": "https://www.kugou.com/"}, 12)
    try:
        j = json.loads(text)
        rows = ((j.get("data") or {}).get("info")) or []
        return code, ["%s | %s | %ss" % (it.get("songname"), it.get("singername"),
                                         it.get("duration")) for it in rows[:5]]
    except Exception:
        return code, ["<parse fail> %s" % text[:90]]


def netease_official(q):
    url = "https://music.163.com/api/search/get?s=%s&type=1&offset=0&limit=10" % enc(q)
    code, text = get(url, {"Referer": "https://music.163.com/"}, 8)
    try:
        j = json.loads(text)
        rows = ((j.get("result") or {}).get("songs")) or []
        return code, ["%s | %s" % (it.get("name"),
                                   "/".join(a.get("name", "") for a in (it.get("artists") or [])))
                      for it in rows[:5]]
    except Exception:
        return code, ["<parse fail> %s" % text[:90]]


def kuwo(q):
    url = ("https://search.kuwo.cn/r.s?all=%s&ft=music&rn=10&pn=1&encoding=utf8"
           "&plat=web_www&rformat=json&mobi=1" % enc(q))
    code, text = get(url, {"Referer": "https://www.kuwo.cn/"}, 10)
    if code != 200:
        return code, ["<no response>"]
    try:
        j = json.loads(text)
        rows = j.get("abslist") or []
        return code, ["%s | %s" % (r.get("SONGNAME"), r.get("ARTIST")) for r in rows[:5]]
    except Exception:
        return code, ["<parse fail> %s" % text[:90]]


LEGS = [("QQ", qq), ("酷狗", kugou), ("网易官方", netease_official), ("酷我", kuwo)]

for q in QUERIES:
    print("=" * 80)
    print("搜索词：%r" % q)
    print("=" * 80)
    for name, fn in LEGS:
        code, rows = fn(q)
        print("  [%s] HTTP %s  共 %d 条" % (name, code, len(rows)))
        for r in rows:
            print("      %s" % r)
        time.sleep(1.0)
    time.sleep(1.2)
