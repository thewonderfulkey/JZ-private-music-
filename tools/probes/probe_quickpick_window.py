# -*- coding: utf-8 -*-
"""量「primary 三个后端并发跑完」要多久 —— 这就是 `DownloadResolver.quickPick` 的真实窗口占用。

quickPick 的实现（URLResolver.swift `collect`）是**等齐**：三个后端（gdstudio 网易 / oiapi 网易 /
妖狐酷我）全部返回或撞到 1.8s 才收工。所以只要有一个慢，播放链就必然吃满 1.8 秒空档。
"""
import json
import random
import time
import urllib.parse
import urllib.request
from concurrent.futures import ThreadPoolExecutor

UA = ("Mozilla/5.0 (iPhone; CPU iPhone OS 16_6 like Mac OS X) AppleWebKit/605.1.15 "
      "(KHTML, like Gecko) Version/16.6 Mobile/15E148 Safari/604.1")
PLAYLIST_ID = "7547299268"


def get(url, headers=None, timeout=12):
    h = {"User-Agent": UA, "Referer": "https://music.163.com/"}
    if headers:
        h.update(headers)
    req = urllib.request.Request(url, headers=h)
    with urllib.request.urlopen(req, timeout=timeout) as r:
        return json.loads(r.read().decode("utf-8", "replace"))


def gdstudio(sid):
    t = time.time()
    try:
        j = get("https://music-api.gdstudio.xyz/api.php?use_xbridge3=true&loader_name=forest"
                "&need_sec_link=1&sec_link_scene=im&theme=light&types=url&source=netease"
                "&id=%s&br=740" % sid, {"User-Agent": "LX-Music-Mobile"}, timeout=8)
        ok = bool(j.get("url"))
    except Exception:  # noqa: BLE001
        ok = False
    return "gdstudio", int((time.time() - t) * 1000), ok


def oiapi(sid):
    t = time.time()
    try:
        j = get("https://oiapi.net/api/Music_163"
                "?key=oiapi-ef6133b7-ac2f-dc7d-878c-d3e207a82575&type=json&level=lossless&n=1&id=%s" % sid)
        ok = bool(j.get("url"))
    except Exception:  # noqa: BLE001
        ok = False
    return "oiapi", int((time.time() - t) * 1000), ok


def yaohu(name, singer):
    t = time.time()
    key = ("%s %s" % (name, singer)).strip()
    try:
        j = get("https://api.yaohud.cn/api/music/kuwo?key=nvgKtvzw7CFSNFrDhA6&action=search&msg=%s&n=1"
                % urllib.parse.quote(key), {"X-Client-Software": "lx"})
        ok = j.get("code") == 200
    except Exception:  # noqa: BLE001
        ok = False
    return "yaohu", int((time.time() - t) * 1000), ok


pl = get("https://music.163.com/api/v6/playlist/detail?id=%s&n=1000&s=8" % PLAYLIST_ID).get("playlist", {})
ids = [t["id"] for t in (pl.get("trackIds") or []) if t.get("id")]
random.seed(7)
picked = random.sample(ids[:400], 4)
enc = urllib.parse.quote("[" + ",".join(str(x) for x in picked) + "]", safe="")
songs = get("https://music.163.com/api/song/detail?ids=%s" % enc).get("songs") or []

print("%-26s %9s %9s %9s %10s" % ("歌名", "gdstudio", "oiapi", "yaohu", "等齐(quickPick)"))
alls = []
for s in songs:
    sid, name = s.get("id"), (s.get("name") or "")[:24]
    singer = "/".join(a.get("name", "") for a in s.get("artists") or [])
    t0 = time.time()
    with ThreadPoolExecutor(max_workers=3) as ex:
        fs = [ex.submit(gdstudio, sid), ex.submit(oiapi, sid), ex.submit(yaohu, name, singer)]
        res = [f.result() for f in fs]
    together = int((time.time() - t0) * 1000)
    by = {r[0]: r[1] for r in res}
    print("%-28s %7dms %7dms %7dms %8dms" % (name, by["gdstudio"], by["oiapi"], by["yaohu"], together))
    alls.append(together)

alls.sort()
print("\n三个后端等齐（= 播放链空档下限）：中位 %d ms，最快 %d，最慢 %d"
      % (alls[len(alls) // 2], alls[0], alls[-1]))
print("超过 1800 ms 窗口的：%d/%d（超了就走 plan()，空档直接变 15s 起）"
      % (len([a for a in alls if a > 1800]), len(alls)))
