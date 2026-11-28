# -*- coding: utf-8 -*-
"""2026-11-28 取证（最终组）：把 App 对《BABY ANGEL / 林娜琏》实际调用的 5 条腿逐条复现。

trace.log 只写「候选 X 超时/失败 Nms」，看不到"为什么空"。这里按 `SourceAdapters.swift`
里的真实端点与参数，逐条打出返回体，定性每一条腿的死因。
"""
import json
import time
import urllib.parse

import requests

UA = ("Mozilla/5.0 (iPhone; CPU iPhone OS 17_0 like Mac OS X) "
      "AppleWebKit/605.1.15 (KHTML, like Gecko) Version/17.0 Mobile/15E148 Safari/604.1")
NAME, ARTIST = "BABY ANGEL", "林娜琏"


def enc(s):
    return urllib.parse.quote(s)


def get(url, headers=None, timeout=12):
    h = {"User-Agent": UA}
    if headers:
        h.update(headers)
    try:
        return requests.get(url, headers=h, timeout=timeout, allow_redirects=True)
    except Exception as e:  # noqa: BLE001
        return e


def show(tag, obj):
    print("  [%s]" % tag, obj)


# ---------- 先拿网易 songID ----------
r = get("https://music.163.com/api/search/get?s=%s&type=1&offset=0&limit=3"
        % enc("%s %s" % (NAME, ARTIST)), {"Referer": "https://music.163.com/"}, 8)
sid, sname, sart, sdur = None, "", "", 0
try:
    rows = ((r.json().get("result") or {}).get("songs")) or []
    if rows:
        it = rows[0]
        sid = it["id"]
        sname = it["name"]
        sart = "/".join(a["name"] for a in (it.get("artists") or []))
        sdur = (it.get("duration") or 0) / 1000
        print("网易官方搜索 top1：%s | %s | %.0fs | id=%s" % (sname, sart, sdur, sid))
except Exception:
    print("搜索解析失败", r.text[:100] if not isinstance(r, Exception) else r)

if not sid:
    raise SystemExit("拿不到 songID，停止")

print()
print("=" * 78)
print("腿① 网易官方  music.163.com/api/song/enhance/player/url")
print("=" * 78)
for br in [320000, 128000, 999000]:
    rr = get("https://music.163.com/api/song/enhance/player/url?ids=[%s]&br=%d" % (sid, br),
             {"Referer": "https://music.163.com/"}, 10)
    try:
        d = (rr.json().get("data") or [{}])[0]
        show("br=%d" % br, "code=%s url=%s fee=%s" %
             (d.get("code"), "有" if d.get("url") else "空", d.get("fee")))
    except Exception:
        show("br=%d" % br, "非JSON %s" % (rr.text[:80] if not isinstance(rr, Exception) else rr))
    time.sleep(0.8)

print()
print("=" * 78)
print("腿② oiapi 网易  oiapi.net/api/Music_163")
print("=" * 78)
for level in ["exhigh", "lossless", "standard"]:
    url = ("https://oiapi.net/api/Music_163"
           "?key=oiapi-ef6133b7-ac2f-dc7d-878c-d3e207a82575"
           "&type=json&level=%s&n=1&id=%s" % (level, sid))
    rr = get(url, timeout=12)
    if isinstance(rr, Exception):
        show(level, "异常 %s" % type(rr).__name__)
        continue
    try:
        j = rr.json()
        u = ""
        data = j.get("data")
        if isinstance(data, dict):
            items = data.get("items") or []
            if items and isinstance(items[0], dict):
                u = items[0].get("url") or ""
            u = u or (data.get("url") or "")
        show(level, "code=%s msg=%s url=%s" %
             (j.get("code"), str(j.get("msg"))[:30], (u[:70] or "<空>")))
    except Exception:
        show(level, "非JSON %s" % rr.text[:80])
    time.sleep(1.0)

print()
print("=" * 78)
print("腿③ gdstudio 网易  music-api.gdstudio.xyz")
print("=" * 78)
rr = get("https://music-api.gdstudio.xyz/api.php?types=url&source=netease&id=%s&br=320" % sid)
if isinstance(rr, Exception):
    show("url", "异常 %s" % type(rr).__name__)
else:
    try:
        j = rr.json()
        u = (j.get("url") or "") if isinstance(j, dict) else ""
        show("url", "HTTP %s url=%s" % (rr.status_code, (u[:70] or "<空>")))
    except Exception:
        show("url", "非JSON %s" % rr.text[:80])
time.sleep(1.0)

print()
print("=" * 78)
print("腿④ meting 网易  api.qijieya.cn/meting")
print("=" * 78)
rr = get("https://api.qijieya.cn/meting/?server=netease&type=url&id=%s" % sid)
if isinstance(rr, Exception):
    show("meting", "异常 %s" % type(rr).__name__)
else:
    try:
        j = rr.json()
        u = (j[0].get("url") or "") if isinstance(j, list) and j else ""
        show("meting", "HTTP %s len=%d url=%s" %
             (rr.status_code, len(j) if isinstance(j, list) else -1, (u[:70] or "<空>")))
    except Exception:
        show("meting", "HTTP %s 非JSON/空 %s" % (rr.status_code, rr.text[:60]))
time.sleep(1.0)

print()
print("=" * 78)
print("腿⑤ 妖狐酷我  api.yaohud.cn/api/music/kuwo")
print("=" * 78)
for key in ["%s %s" % (NAME, ARTIST), NAME]:
    url = ("https://api.yaohud.cn/api/music/kuwo"
           "?key=nvgKtvzw7CFSNFrDhA6&action=search&msg=%s&n=1" % enc(key))
    rr = get(url, {"X-Client-Software": "lx"}, 12)
    if isinstance(rr, Exception):
        show(key, "异常 %s" % type(rr).__name__)
        continue
    try:
        j = rr.json()
        show(key, "HTTP %s code=%s msg=%s" % (rr.status_code, j.get("code"),
                                             str(j.get("msg") or j.get("message"))[:40]))
    except Exception:
        show(key, "HTTP %s 非JSON %s" % (rr.status_code, rr.text[:60]))
    time.sleep(1.5)
