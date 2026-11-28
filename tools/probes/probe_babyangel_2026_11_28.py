# -*- coding: utf-8 -*-
"""2026-11-28 取证：BANNER 韩语歌单里《BABY ANGEL / 林娜琏》被跳过。

对照两组搜索词：
  A. 网易给的原样：「BABY ANGEL 林娜琏」（App 的跨平台搜索就是这么拼的）
  B. 各平台真实索引名：「BABY ANGEL NAYEON」
看的是"搜不到"还是"搜到了但身份闸丢了"。
"""
import json
import re
import sys
import time
import urllib.parse

import requests

UA = ("Mozilla/5.0 (iPhone; CPU iPhone OS 17_0 like Mac OS X) "
      "AppleWebKit/605.1.15 (KHTML, like Gecko) Version/17.0 Mobile/15E148 Safari/604.1")

QUERIES = ["BABY ANGEL 林娜琏", "BABY ANGEL NAYEON", "BABY ANGEL"]


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
        return -1, "EXC %s" % e


def netease_official(q):
    url = ("https://music.163.com/api/search/get?s=%s&type=1&offset=0&limit=10" % enc(q))
    code, text = get(url, {"Referer": "https://music.163.com/"}, 8)
    out = []
    try:
        j = json.loads(text)
        for it in ((j.get("result") or {}).get("songs") or [])[:8]:
            ar = "/".join(a.get("name", "") for a in (it.get("artists") or []))
            out.append("%s | %s | %sms" % (it.get("name"), ar, it.get("duration")))
    except Exception:
        return code, ["<parse fail> %s" % text[:80]]
    return code, out


def gdstudio(q, source="netease"):
    url = ("https://music-api.gdstudio.xyz/api.php?types=search&source=%s&name=%s&count=10&pages=1"
           % (enc(source), enc(q)))
    code, text = get(url, timeout=12)
    out = []
    try:
        j = json.loads(text)
        for it in (j if isinstance(j, list) else [])[:8]:
            out.append("%s | %s | %ss" % (it.get("name"), it.get("artist"), it.get("duration")))
    except Exception:
        return code, ["<parse fail> %s" % text[:80]]
    return code, out


def meting(q):
    url = "https://api.qijieya.cn/meting/?type=search&id=%s" % enc(q)
    code, text = get(url, timeout=12)
    out = []
    try:
        j = json.loads(text)
        for it in (j if isinstance(j, list) else [])[:8]:
            out.append("%s | %s" % (it.get("name"), it.get("artist")))
    except Exception:
        return code, ["<parse fail> %s" % text[:80]]
    return code, out


def kuwo(q):
    url = ("https://search.kuwo.cn/r.s?all=%s&ft=music&rn=10&pn=1&pcmp4=1&encoding=utf8"
           "&plat=web_www&from=&rformat=json&mobi=1" % enc(q))
    code, text = get(url, {"Referer": "https://www.kuwo.cn/"}, 12)
    out = []
    txt = text.replace("'", '"')
    for m in re.finditer(r'"SONGNAME"\s*:\s*"([^"]*)"\s*,\s*"ARTIST"\s*:\s*"([^"]*)"', txt):
        out.append("%s | %s" % (m.group(1), m.group(2)))
    if not out:
        # 老格式：SONGNAME: xxx ... ARTIST: yyy
        for m in re.finditer(r"SONGNAME:([^,]*).*?ARTIST:([^,]*)", txt):
            out.append("%s | %s" % (m.group(1).strip(), m.group(2).strip()))
    if not out:
        out = ["<no rows> %s" % text[:120].replace("\n", " ")]
    return code, out[:8]


def kugou(q):
    url = ("https://mobiles.kugou.com/api/v3/search/song?format=json&keyword=%s&page=1"
           "&pagesize=10&showtype=1" % enc(q))
    code, text = get(url, {"Referer": "https://www.kugou.com/"}, 12)
    out = []
    try:
        j = json.loads(text)
        for it in (((j.get("data") or {}).get("info")) or [])[:8]:
            out.append("%s | %s | %ss" % (it.get("songname"), it.get("singername"),
                                          it.get("duration")))
    except Exception:
        return code, ["<parse fail> %s" % text[:80]]
    return code, out


def qq(q):
    url = ("https://c.y.qq.com/soso/fcgi-bin/client_search_cp?p=1&n=10&w=%s&format=json"
           % enc(q))
    code, text = get(url, {"Referer": "https://y.qq.com/"}, 10)
    out = []
    try:
        body = text.strip()
        if body.startswith("callback("):
            body = body[len("callback("):-1]
        j = json.loads(body)
        for it in (((j.get("data") or {}).get("song") or {}).get("list")) or []:
            ar = "/".join(s.get("name", "") for s in (it.get("singer") or []))
            out.append("%s | %s | %ss" % (it.get("songname"), ar, it.get("interval")))
    except Exception:
        return code, ["<parse fail> %s" % text[:100]]
    return code, out


LEGS = [
    ("网易官方", netease_official),
    ("gdstudio 网易", gdstudio),
    ("meting 网易", meting),
    ("酷我", kuwo),
    ("酷狗", kugou),
    ("QQ", qq),
]

for q in QUERIES:
    print("=" * 78)
    print("搜索词：%s" % q)
    print("=" * 78)
    for name, fn in LEGS:
        code, rows = fn(q)
        print("  [%s] HTTP %s  共 %d 条" % (name, code, len(rows)))
        for r in rows:
            print("      %s" % r)
        time.sleep(1.2)
    time.sleep(1.5)
