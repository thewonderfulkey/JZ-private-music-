# -*- coding: utf-8 -*-
"""2026-11-28 取证（第四组）：一张 BANNER 歌单里，哪些歌拿得到直链。

歌单：网易「一周韩语上新 | 温柔凝视内心最深处」（BANNER 点进去的那张）。
判据（不看接口自报，只看有没有真直链 + Range 真实状态）：
  · 网易官方 player/url  → 有没有 url
  · QQ cyapi             → 回的是不是真 CDN（stream.qqmusic.qq.com），Range 是不是 206
  · 酷狗 playInfo        → url 是否为空
目的：区分「BABY ANGEL 一首的偶发」与「这类新发行/韩语曲目整类没有免费直链」。
"""
import json
import time
import urllib.parse

import requests

UA = ("Mozilla/5.0 (iPhone; CPU iPhone OS 17_0 like Mac OS X) "
      "AppleWebKit/605.1.15 (KHTML, like Gecko) Version/17.0 Mobile/15E148 Safari/604.1")

SONGS = [
    ("Beurre Sale", "WENDY", 200),
    ("Janga", "hyukoh", 253),
    ("Greedy", "KISS OF LIFE", 196),
    ("BABY ANGEL", "林娜琏", 135),
    ("필사적 필사", "윤하", 243),
    ("Polaroid", "Yves", 152),
    ("Just Because", "Christopher", 190),
]


def enc(s):
    return urllib.parse.quote(s)


def get(url, headers=None, timeout=15):
    h = {"User-Agent": UA}
    if headers:
        h.update(headers)
    try:
        return requests.get(url, headers=h, timeout=timeout, allow_redirects=True)
    except Exception:
        return None


def netease_url(name, artist):
    r = get("https://music.163.com/api/search/get?s=%s&type=1&offset=0&limit=5"
            % enc("%s %s" % (name, artist)), {"Referer": "https://music.163.com/"}, 8)
    if r is None or r.status_code != 200:
        return "搜索失败"
    try:
        rows = ((r.json().get("result") or {}).get("songs")) or []
    except Exception:
        return "解析失败"
    if not rows:
        return "搜不到"
    sid = rows[0].get("id")
    r2 = get("https://music.163.com/api/song/enhance/player/url?ids=[%s]&br=320000" % sid,
             {"Referer": "https://music.163.com/"}, 10)
    if r2 is None:
        return "取流失败"
    try:
        d = (r2.json().get("data") or [{}])[0]
    except Exception:
        return "取流解析失败"
    url = d.get("url") or ""
    if not url:
        return "无直链（code=%s）" % d.get("code")
    return "有直链 %dkbps" % ((d.get("br") or 0) // 1000)


def qq_url(name, artist):
    r = get("https://c.y.qq.com/soso/fcgi-bin/client_search_cp?p=1&n=5&w=%s&format=json"
            % enc("%s %s" % (name, artist)), {"Referer": "https://y.qq.com/"}, 10)
    if r is None:
        return "搜索失败"
    body = r.text.strip()
    if body.startswith("callback("):
        body = body[len("callback("):-1]
    try:
        rows = ((json.loads(body).get("data") or {}).get("song") or {}).get("list") or []
    except Exception:
        return "解析失败"
    if not rows:
        return "搜不到"
    mid = rows[0].get("songmid")
    if not mid:
        return "无 mid"
    r2 = get("https://cyapi.top/API/qq_music.php?apikey="
             "1ffdf5733f5d538760e63d7e46ba17438d9f7b9dfc18c51be1109386fd74c3a1"
             "&type=json&mid=%s" % mid, {"Referer": "https://y.qq.com/"}, 15)
    if r2 is None:
        return "取流失败"
    try:
        url = (r2.json().get("url") or "")
    except Exception:
        return "取流解析失败"
    if not url:
        return "无直链"
    if "stream.qqmusic.qq.com" not in url:
        return "假链（fcg_pyq_play，实测 403）"
    r3 = get(url, {"Range": "bytes=0-1023"}, 15)
    if r3 is None:
        return "直链取不到"
    return "有直链 HTTP %s" % r3.status_code


def kugou_url(name, artist):
    r = get("https://mobiles.kugou.com/api/v3/search/song?format=json&keyword=%s&page=1"
            "&pagesize=5&showtype=1" % enc("%s %s" % (name, artist)),
            {"Referer": "https://www.kugou.com/"}, 12)
    if r is None:
        return "搜索失败"
    try:
        rows = ((r.json().get("data") or {}).get("info")) or []
    except Exception:
        return "解析失败"
    if not rows:
        return "搜不到"
    h = rows[0].get("hash")
    if not h:
        return "无 hash"
    r2 = get("https://m.kugou.com/app/i/getSongInfo.php?cmd=playInfo&hash=%s" % h,
             {"Referer": "https://m.kugou.com/"}, 12)
    if r2 is None:
        return "取流失败"
    try:
        j = r2.json()
    except Exception:
        return "取流解析失败"
    url = j.get("url") or ""
    if not url:
        return "无直链（errcode=%s）" % j.get("errcode")
    return "有直链"


print("%-20s %-16s %-24s %-26s %s" % ("歌名", "歌手", "网易官方", "QQ cyapi", "酷狗 playInfo"))
print("-" * 108)
for name, artist, dur in SONGS:
    ne = netease_url(name, artist)
    time.sleep(1.0)
    qq = qq_url(name, artist)
    time.sleep(1.0)
    kg = kugou_url(name, artist)
    time.sleep(1.0)
    print("%-20s %-16s %-24s %-26s %s" % (name[:19], artist[:15], ne, qq, kg))
