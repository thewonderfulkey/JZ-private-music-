# -*- coding: utf-8 -*-
"""A 的取源证据：播放链改成 320k 后，网易/酷我两条主通道实际给出的到底是什么。

验收口径（老板 2026-11-20）：选中的 URL 后缀 / Content-Type / 实测码率，应为 320k mp3，不得出现 .flac。
这里按 App 新播放链的真实请求参数跑一遍：
  · 网易 gdstudio：`br=320`（旧代码是 br=740 = FLAC）
  · 酷我官方 anti.s：`format=mp3`（妖狐那条只回 740k FLAC，已被 `PlaybackQualityRules` 挡掉）
"""
import json
import urllib.parse
import urllib.request

UA = ("Mozilla/5.0 (iPhone; CPU iPhone OS 16_6 like Mac OS X) AppleWebKit/605.1.15 "
      "(KHTML, like Gecko) Version/16.6 Mobile/15E148 Safari/604.1")
PLAYLIST_ID = "7547299268"


def get(url, headers=None, timeout=20):
    h = {"User-Agent": UA, "Referer": "https://music.163.com/"}
    if headers:
        h.update(headers)
    req = urllib.request.Request(url, headers=h)
    with urllib.request.urlopen(req, timeout=timeout) as r:
        return json.loads(r.read().decode("utf-8", "replace"))


def head(url, timeout=15):
    h = {"User-Agent": UA, "Referer": "https://music.163.com/"}
    req = urllib.request.Request(url, headers=h, method="HEAD")
    with urllib.request.urlopen(req, timeout=timeout) as r:
        return r.headers, int(r.headers.get("Content-Length") or 0)


print("=== 网易 gdstudio：br=320（新播放链） vs br=740（旧播放链）===")
pl = get("https://music.163.com/api/v6/playlist/detail?id=%s&n=1000&s=8" % PLAYLIST_ID).get("playlist", {})
ids = [t["id"] for t in (pl.get("trackIds") or []) if t.get("id")][:4]
enc = urllib.parse.quote("[" + ",".join(str(i) for i in ids) + "]", safe="")
songs = get("https://music.163.com/api/song/detail?ids=%s" % enc).get("songs") or []

print("%-22s %-6s %-16s %-10s %8s %s" % ("歌名", "档", "URL后缀", "C-Type", "实测kbps", "结尾"))
for s in songs:
    sid = s.get("id")
    name = (s.get("name") or "")[:20]
    dur = int((s.get("duration") or 0) / 1000) or 1
    for br in ("320", "740"):
        try:
            j = get("https://music-api.gdstudio.xyz/api.php?use_xbridge3=true&loader_name=forest"
                    "&need_sec_link=1&sec_link_scene=im&theme=light&types=url&source=netease"
                    "&id=%s&br=%s" % (sid, br), {"User-Agent": "LX-Music-Mobile"}, 15)
        except Exception as e:  # noqa: BLE001
            print("  %-20s %-6s ERR %s" % (name, br, repr(e)[:50]))
            continue
        url = j.get("url") or ""
        if not url:
            print("  %-20s %-6s 无 URL" % (name, br))
            continue
        suffix = "." + url.rsplit(".", 1)[-1][:5] if "." in url else "(无后缀)"
        try:
            hd, n = head(url)
            ct = (hd.get("Content-Type") or "?").split(";")[0]
            kbps = round(n * 8 / dur / 1000)
        except Exception as e:  # noqa: BLE001
            ct, kbps = "HEAD失败", 0
        print("  %-20s %-6s %-16s %-10s %8s %s" % (name, br, suffix, ct, kbps, url[-22:]))
