# -*- coding: utf-8 -*-
"""把老板的网易「我喜欢的音乐」歌单里含 DARK 的条目找出来，并按 App 的取流链逐个试。

输出：歌单里这几首的真实元数据 + gdstudio 三个档位返回的直链「实测时长」，
用来判断「点击后被跳过」到底是"取不到源"还是"拿到的是试听/别的版本（时长对不上）"。
"""
import json
import urllib.error
import urllib.request

UA = ("Mozilla/5.0 (iPhone; CPU iPhone OS 16_6 like Mac OS X) AppleWebKit/605.1.15 "
      "(KHTML, like Gecko) Version/16.6 Mobile/15E148 Safari/604.1")
PLAYLIST_ID = "7547299268"


def get(url, headers=None, timeout=25, raw=False):
    h = {"User-Agent": UA, "Referer": "https://music.163.com/"}
    if headers:
        h.update(headers)
    req = urllib.request.Request(url, headers=h)
    with urllib.request.urlopen(req, timeout=timeout) as r:
        data = r.read()
    return data if raw else json.loads(data.decode("utf-8", "replace"))


def fetch_range(url, headers=None, n=65536):
    h = {"User-Agent": UA, "Range": f"bytes=0-{n-1}"}
    if headers:
        h.update(headers)
    req = urllib.request.Request(url, headers=h)
    with urllib.request.urlopen(req, timeout=30) as r:
        return r.read()


def flac_seconds(buf):
    i = buf.find(b"fLaC")
    if i < 0:
        return None
    p = i + 4
    if p + 4 > len(buf) or (buf[p] & 0x7F) != 0:
        return None
    length = int.from_bytes(buf[p + 1:p + 4], "big")
    body = buf[p + 4:p + 4 + length]
    if len(body) < 18:
        return None
    bits = int.from_bytes(body[10:18], "big")
    rate = (bits >> 44) & 0xFFFFF
    total = bits & ((1 << 36) - 1)
    return round(total / rate, 2) if rate else None


def mp3_seconds(buf):
    """读第一个 MPEG 帧头 + Xing/Info 帧数；拿不到就返回 None。"""
    i = 0
    if buf[:3] == b"ID3":
        size = ((buf[6] & 0x7F) << 21) | ((buf[7] & 0x7F) << 14) | ((buf[8] & 0x7F) << 7) | (buf[9] & 0x7F)
        i = 10 + size
    while i + 4 < len(buf):
        if buf[i] == 0xFF and (buf[i + 1] & 0xE0) == 0xE0:
            break
        i += 1
    if i + 4 >= len(buf):
        return None
    ver_bits = (buf[i + 1] >> 3) & 0x03
    layer = (buf[i + 1] >> 1) & 0x03
    br_idx = (buf[i + 2] >> 4) & 0x0F
    sr_idx = (buf[i + 2] >> 2) & 0x03
    rates = {3: [44100, 48000, 32000], 2: [22050, 24000, 16000], 0: [11025, 12000, 8000]}
    srs = rates.get(ver_bits, [44100])
    if sr_idx >= len(srs):
        return None
    sr = srs[sr_idx]
    brs = {1: [0, 32, 40, 48, 56, 64, 80, 96, 112, 128, 160, 192, 224, 256, 320]}
    table = brs.get(layer, brs[1])
    kbps = table[br_idx] if br_idx < len(table) else 0
    return {"sample_rate": sr, "kbps": kbps}


print("=== 拉歌单详情 ===")
detail = get(f"https://music.163.com/api/v6/playlist/detail?id={PLAYLIST_ID}&n=1000&s=8")
pl = detail.get("playlist", {})
print("name=", pl.get("name"), "trackCount=", pl.get("trackCount"),
      "tracks=", len(pl.get("tracks") or []), "trackIds=", len(pl.get("trackIds") or []))
ids = [t["id"] for t in (pl.get("trackIds") or []) if t.get("id")]
print("前 10 个 id:", ids[:10])

# 歌单里的 tracks 只有 6 首，先看这 6 首里有没有 DARK
hits = []
for t in pl.get("tracks") or []:
    nm = t.get("name", "")
    if "dark" in nm.lower():
        hits.append({"id": t.get("id"), "name": nm,
                     "singer": "/".join(a.get("name", "") for a in t.get("ar") or []),
                     "dur_ms": t.get("dt")})

# 全量按 id 批量查（200 个一批）
all_songs = []
for i in range(0, len(ids), 200):
    chunk = ids[i:i + 200]
    enc = urllib.parse.quote("[" + ",".join(str(x) for x in chunk) + "]", safe="")
    js = get(f"https://music.163.com/api/song/detail?ids={enc}")
    all_songs.extend(js.get("songs") or [])

print("song/detail 取回", len(all_songs), "首")
for s in all_songs:
    nm = s.get("name", "")
    if "dark" in nm.lower():
        hits.append({"id": s.get("id"), "name": nm,
                     "singer": "/".join(a.get("name", "") for a in s.get("artists") or []),
                     "dur_ms": s.get("duration")})

print("\n=== 含 DARK 的条目 ===")
for h in hits:
    print(h)

print("\n=== 逐个按 App 的 gdstudio 链取流，看实测时长 ===")
for h in hits:
    sid = h["id"]
    for br in ("740", "320"):
        u = ("https://music-api.gdstudio.xyz/api.php?use_xbridge3=true&loader_name=forest"
             "&need_sec_link=1&sec_link_scene=im&theme=light&types=url&source=netease"
             f"&id={sid}&br={br}")
        try:
            j = get(u, {"User-Agent": "LX-Music-Mobile"}, timeout=30)
            url = j.get("url") or ""
            if not url:
                print(f"  id={sid} br={br} 没有 URL：{j}")
                continue
            buf = fetch_range(url)
            sec = flac_seconds(buf) if buf.find(b"fLaC") >= 0 else None
            mp3 = mp3_seconds(buf) if sec is None else None
            print(f"  id={sid} br={br} api_br={j.get('br')} size={j.get('size')} "
                  f"flac_sec={sec} mp3={mp3} 目标={h['dur_ms']}ms")
        except Exception as e:  # noqa: BLE001
            print(f"  id={sid} br={br} 失败 {e!r}")
