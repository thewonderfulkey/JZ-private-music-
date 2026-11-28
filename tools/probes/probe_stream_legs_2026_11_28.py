# -*- coding: utf-8 -*-
"""2026-11-28 取证（第三组）：候选的取流腿能不能真出直链。

场景：BANNER 网易歌单《一周韩语上新》第 04 首《BABY ANGEL / 林娜琏》。
网易四条腿全挂（trace.log 实测），跨平台补位是唯一活路。
这里按 App 的同一批端点，拿真实 mid / hash 去试 QQ 与酷狗。
"""
import json
import time
import urllib.parse

import requests

UA = ("Mozilla/5.0 (iPhone; CPU iPhone OS 17_0 like Mac OS X) "
      "AppleWebKit/605.1.15 (KHTML, like Gecko) Version/17.0 Mobile/15E148 Safari/604.1")


def enc(s):
    return urllib.parse.quote(s)


def get(url, headers=None, timeout=15):
    h = {"User-Agent": UA}
    if headers:
        h.update(headers)
    try:
        r = requests.get(url, headers=h, timeout=timeout, allow_redirects=True)
        return r.status_code, r.text, r
    except Exception as e:  # noqa: BLE001
        return -1, "EXC %s" % type(e).__name__, None


def head_probe(url):
    """Range 取前 2KB，量真实体积与容器魔数（不信接口自报）"""
    try:
        r = requests.get(url, headers={"User-Agent": UA, "Range": "bytes=0-2047"},
                         timeout=15, allow_redirects=True)
        cr = r.headers.get("Content-Range", "")
        total = cr.split("/")[-1] if "/" in cr else "?"
        magic = r.content[:4].hex() if r.content else ""
        return "%s bytes=%s magic=%s" % (r.status_code, total, magic)
    except Exception as e:  # noqa: BLE001
        return "HEAD EXC %s" % type(e).__name__


print("=" * 78)
print("① QQ：搜 mid")
print("=" * 78)
code, text, _ = get("https://c.y.qq.com/soso/fcgi-bin/client_search_cp?p=1&n=5&w=%s&format=json"
                    % enc("BABY ANGEL 林娜琏"), {"Referer": "https://y.qq.com/"})
mids = []
try:
    body = text.strip()
    if body.startswith("callback("):
        body = body[len("callback("):-1]
    j = json.loads(body)
    for it in ((j.get("data") or {}).get("song") or {}).get("list") or []:
        ar = "/".join(s.get("name", "") for s in (it.get("singer") or []))
        print("   %-22s | %-20s | %ss | mid=%s" % (it.get("songname"), ar,
                                                   it.get("interval"), it.get("songmid")))
        mids.append((it.get("songmid"), it.get("songname"), it.get("interval")))
except Exception:
    print("   <parse fail>", text[:120])

print()
print("=" * 78)
print("② QQ 取流：cyapi → 落月 v3")
print("=" * 78)
for mid, nm, iv in mids[:3]:
    if not mid:
        continue
    print("  -- %s (mid=%s, %ss)" % (nm, mid, iv))
    url = ("https://cyapi.top/API/qq_music.php"
           "?apikey=1ffdf5733f5d538760e63d7e46ba17438d9f7b9dfc18c51be1109386fd74c3a1"
           "&type=json&mid=%s" % mid)
    c, t, _ = get(url, {"Referer": "https://y.qq.com/"})
    try:
        jj = json.loads(t)
        u = jj.get("url") or ""
        print("     cyapi HTTP %s  url=%s" % (c, (u[:70] + "...") if u else "<空>"))
        if u:
            print("     cyapi 实测 %s" % head_probe(u))
    except Exception:
        print("     cyapi HTTP %s  <非JSON> %s" % (c, t[:90]))
    time.sleep(1.0)
    c, t, _ = get("https://api.vkeys.cn/music/tencent/song/link?mid=%s&quality=8" % mid,
                  {"Referer": "https://y.qq.com/"})
    try:
        jj = json.loads(t)
        d = jj.get("data") or {}
        u = d.get("url") or d.get("link") or ""
        print("     落月 HTTP %s code=%s url=%s" % (c, jj.get("code"),
                                                 (u[:70] + "...") if u else "<空>"))
        if u:
            print("     落月 实测 %s" % head_probe(u))
    except Exception:
        print("     落月 HTTP %s  <非JSON> %s" % (c, t[:90]))
    time.sleep(1.0)

print()
print("=" * 78)
print("③ 酷狗：搜 hash → getSongInfo playInfo")
print("=" * 78)
code, text, _ = get("https://mobiles.kugou.com/api/v3/search/song?format=json&keyword=%s"
                    "&page=1&pagesize=5&showtype=1" % enc("BABY ANGEL 林娜琏"),
                    {"Referer": "https://www.kugou.com/"})
hashes = []
try:
    j = json.loads(text)
    for it in ((j.get("data") or {}).get("info")) or []:
        print("   %-38s | %-20s | %ss | hash=%s" % (it.get("songname"), it.get("singername"),
                                                    it.get("duration"), it.get("hash")))
        hashes.append((it.get("hash"), it.get("songname"), it.get("duration")))
except Exception:
    print("   <parse fail>", text[:120])

print()
for h, nm, iv in hashes[:3]:
    if not h:
        continue
    print("  -- %s (hash=%s, %ss)" % (nm, h[:12], iv))
    c, t, _ = get("https://m.kugou.com/app/i/getSongInfo.php?cmd=playInfo&hash=%s" % h,
                  {"Referer": "https://m.kugou.com/"})
    try:
        jj = json.loads(t)
        u = jj.get("url") or ""
        print("     playInfo HTTP %s errcode=%s url=%s" % (c, jj.get("errcode"),
                                                          (u[:70] + "...") if u else "<空>"))
        if u:
            print("     playInfo 实测 %s" % head_probe(u))
    except Exception:
        print("     playInfo HTTP %s  <非JSON> %s" % (c, t[:90]))
    time.sleep(1.0)
