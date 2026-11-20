# -*- coding: utf-8 -*-
"""统计：老板那张网易「我喜欢的音乐」里，gdstudio 回的 FLAC 都是什么规格。

用途：判断《DARK ARIA》(1610kbps / 48k / 24bit) 是不是**这张歌单里唯一的 24bit 母带**。
如果整张歌单里 24bit 很多、而老板只报了这一首被跳过，那"24bit 播不了"的假设就要打折扣。
"""
import json
import time
import urllib.parse
import urllib.request

UA = ("Mozilla/5.0 (iPhone; CPU iPhone OS 16_6 like Mac OS X) AppleWebKit/605.1.15 "
      "(KHTML, like Gecko) Version/16.6 Mobile/15E148 Safari/604.1")
PLAYLIST_ID = "7547299268"
SAMPLE = 30


def get(url, headers=None, timeout=25, raw=False):
    h = {"User-Agent": UA, "Referer": "https://music.163.com/"}
    if headers:
        h.update(headers)
    req = urllib.request.Request(url, headers=h)
    with urllib.request.urlopen(req, timeout=timeout) as r:
        data = r.read()
    return data if raw else json.loads(data.decode("utf-8", "replace"))


def flac_info(url):
    h = {"User-Agent": UA, "Range": "bytes=0-131071"}
    req = urllib.request.Request(url, headers=h)
    with urllib.request.urlopen(req, timeout=30) as r:
        buf = r.read()
    i = buf.find(b"fLaC")
    if i < 0:
        return None
    p = i + 4
    if p + 4 > len(buf) or (buf[p] & 0x7F) != 0:
        return None
    ln = int.from_bytes(buf[p + 1:p + 4], "big")
    body = buf[p + 4:p + 4 + ln]
    if len(body) < 18:
        return None
    bits = int.from_bytes(body[10:18], "big")
    return {"rate": (bits >> 44) & 0xFFFFF,
            "ch": ((bits >> 41) & 0x7) + 1,
            "bps": ((bits >> 36) & 0x1F) + 1,
            "sec": round((bits & ((1 << 36) - 1)) / max(1, (bits >> 44) & 0xFFFFF), 2)}


detail = get(f"https://music.163.com/api/v6/playlist/detail?id={PLAYLIST_ID}&n=1000&s=8")
ids = [t["id"] for t in (detail.get("playlist", {}).get("trackIds") or []) if t.get("id")]
all_songs = []
for i in range(0, len(ids), 200):
    enc = urllib.parse.quote("[" + ",".join(str(x) for x in ids[i:i + 200]) + "]", safe="")
    all_songs.extend(get(f"https://music.163.com/api/song/detail?ids={enc}").get("songs") or [])
by_id = {s["id"]: s for s in all_songs}

step = max(1, len(ids) // SAMPLE)
sample = ids[::step][:SAMPLE]
rows = []
for sid in sample:
    meta = by_id.get(sid) or {}
    name = meta.get("name", "?")
    try:
        u = ("https://music-api.gdstudio.xyz/api.php?use_xbridge3=true&loader_name=forest"
             f"&need_sec_link=1&sec_link_scene=im&theme=light&types=url&source=netease&id={sid}&br=740")
        j = get(u, {"User-Agent": "LX-Music-Mobile"}, timeout=30)
        url = j.get("url") or ""
        info = flac_info(url) if url else None
        rows.append({"id": sid, "name": name, "api_br": j.get("br"), "size": j.get("size"),
                     "flac": info})
        print(f"{sid} {name[:24]:<26} api_br={j.get('br')} size={j.get('size')} "
              f"flac={info}")
    except Exception as e:  # noqa: BLE001
        print(f"{sid} {name[:24]:<26} 失败 {e!r}")
    time.sleep(0.4)

hires = [r for r in rows if (r.get("flac") or {}).get("bps", 0) > 16]
print(f"\n采样 {len(rows)} 首：24bit 的有 {len(hires)} 首 → " +
      "、".join(r["name"] for r in hires))
