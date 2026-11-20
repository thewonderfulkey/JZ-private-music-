# -*- coding: utf-8 -*-
"""排查：网易导入歌单里《DARK ARIA》(澤野弘之, 网易 id 2135545143) 点击后被自动跳过。

复刻 App 的取流链关键几步（Windows 侧直连，只做只读探测）：
  1. gdstudio 网易按 id 取流 → 拿直链，再从 FLAC STREAMINFO / MP3 帧头估真实时长；
  2. QQ / 酷我 / 酷狗 搜索「歌名 + 歌手」，看跨平台补源的候选到底长什么样
     （歌手是繁体「澤野弘之」还是简体/英文名、时长差多少）；
  3. 按 App 的同曲判定口径（NameMatch.sameRecording）逐条判候选能不能过。
"""
import json
import re
import struct
import sys
import urllib.parse
import urllib.request

UA = ("Mozilla/5.0 (iPhone; CPU iPhone OS 16_6 like Mac OS X) "
      "AppleWebKit/605.1.15 (KHTML, like Gecko) Version/16.6 Mobile/15E148 Safari/604.1")

TARGET = {"name": "DARK ARIA", "singer": "澤野弘之", "netease_id": "2135545143", "duration": 141.744}


def get(url, headers=None, timeout=20, raw=False):
    h = {"User-Agent": UA, "Accept": "application/json, text/javascript, */*; q=0.01",
         "Referer": "https://music.qq.com/"}
    if headers:
        h.update(headers)
    req = urllib.request.Request(url, headers=h)
    with urllib.request.urlopen(req, timeout=timeout) as r:
        data = r.read()
    return data if raw else data.decode("utf-8", "replace")


def flac_duration(url):
    """只用前 64KB 读 FLAC STREAMINFO：采样率 + 总样本数 → 时长"""
    h = {"Range": "bytes=0-65535", "Referer": "https://music.163.com/", "User-Agent": UA}
    req = urllib.request.Request(url, headers=h)
    with urllib.request.urlopen(req, timeout=30) as r:
        buf = r.read()
    i = buf.find(b"fLaC")
    if i < 0:
        return None
    p = i + 4
    if p + 4 > len(buf):
        return None
    header = buf[p]
    block_type = header & 0x7F
    length = int.from_bytes(buf[p + 1:p + 4], "big")
    if block_type != 0:
        return None
    body = buf[p + 4:p + 4 + length]
    if len(body) < 18:
        return None
    # STREAMINFO: 2+2+3+3 = 10 bytes，然后 8 字节装的 sample_rate(20) channels(3) bps(5) total(36)
    bits = int.from_bytes(body[10:18], "big")
    sample_rate = (bits >> 44) & 0xFFFFF
    total_samples = bits & ((1 << 36) - 1)
    if sample_rate <= 0:
        return None
    return {"sample_rate": sample_rate, "total_samples": total_samples,
            "seconds": round(total_samples / sample_rate, 2)}


def mp3_duration(url, approx_bytes=None, kbps=None):
    if approx_bytes and kbps:
        return round(approx_bytes * 8 / (kbps * 1000), 2)
    return None


print("=== ① gdstudio 网易按 id 取流 ===")
streams = {}
for br in ("740", "320", "128"):
    u = ("https://music-api.gdstudio.xyz/api.php?use_xbridge3=true&loader_name=forest"
         "&need_sec_link=1&sec_link_scene=im&theme=light&types=url&source=netease"
         f"&id={TARGET['netease_id']}&br={br}")
    try:
        j = json.loads(get(u, {"User-Agent": "LX-Music-Mobile"}, timeout=25))
        streams[br] = j
        print(f"br={br} url={j.get('url')} api_br={j.get('br')} size={j.get('size')}")
    except Exception as e:  # noqa: BLE001
        print(f"br={br} 失败 {e!r}")

for br, j in streams.items():
    url = j.get("url") or ""
    if not url:
        continue
    try:
        if url.lower().endswith(".flac") or "flac" in url.lower():
            print(f"  br={br} FLAC 实测 {flac_duration(url)} （目标 {TARGET['duration']}s）")
        else:
            size = j.get("size") or 0
            kbps = j.get("br") or 0
            if size and kbps:
                print(f"  br={br} MP3 由 size/br 推时长 {mp3_duration(url, size, kbps)}s")
    except Exception as e:  # noqa: BLE001
        print(f"  br={br} 时长探测失败 {e!r}")

kw = f"{TARGET['name']} {TARGET['singer']}"
print(f"\n=== ② 跨平台搜索「{kw}」（App 的 SameSongCrossResolver 就是拿这个串搜） ===")
enc = urllib.parse.quote(kw, safe="")


def show(platform, rows):
    print(f"\n-- {platform} --")
    for r in rows:
        print("  ", r)


# QQ
try:
    j = json.loads(get("https://c.y.qq.com/soso/fcgi-bin/client_search_cp"
                       f"?p=1&n=20&w={enc}&format=json", {"Referer": "https://y.qq.com/"}))
    rows = []
    for it in j.get("data", {}).get("song", {}).get("list", []):
        rows.append({"name": it.get("songname"), "mid": it.get("songmid"),
                     "singer": "/".join(s.get("name", "") for s in it.get("singer", [])),
                     "dur": it.get("interval")})
    show("QQ", rows)
except Exception as e:  # noqa: BLE001
    print("QQ 失败", e)

# 网易官方（App 的同平台名搜索）
try:
    j = json.loads(get("https://music.163.com/api/search/get"
                       f"?s={enc}&type=1&offset=0&limit=20", {"Referer": "https://music.163.com/"}))
    rows = [{"name": s.get("name"), "id": s.get("id"),
             "singer": "/".join(a.get("name", "") for a in s.get("artists", [])),
             "dur_ms": s.get("duration")} for s in j.get("result", {}).get("songs", [])]
    show("网易官方", rows)
except Exception as e:  # noqa: BLE001
    print("网易失败", e)

# 酷我
try:
    txt = get("https://search.kuwo.cn/r.s"
              f"?all={enc}&ft=music&rn=20&pn=1&rformat=json&encoding=utf8&vipver=MUSIC_8.7.8.0_WX",
              {"Referer": "https://www.kuwo.cn/"})
    # 酷我给的是 Python 风格单引号文本，粗取条目
    items = re.findall(r"\{'ABSID'.*?LONGDURATION':'\d+'\}", txt)
    rows = []
    for it in items[:20]:
        getv = lambda k: (re.search(k + r"':'([^']*)'", it) or [None, ""])[1]
        rows.append({"name": getv("SONGNAME"), "rid": getv("MUSICRID"),
                     "artist": getv("ARTIST"), "dur": getv("DURATION")})
    show("酷我", rows)
except Exception as e:  # noqa: BLE001
    print("酷我失败", e)

# 酷狗
try:
    j = json.loads(get("https://mobiles.kugou.com/api/v3/search/song"
                       f"?format=json&keyword={enc}&page=1&pagesize=20&showtype=1",
                       {"Referer": "https://www.kugou.com/"}))
    rows = [{"name": it.get("songname"), "hash": it.get("hash"),
             "singer": it.get("singername"), "dur": it.get("duration")}
            for it in j.get("data", {}).get("info", [])]
    show("酷狗", rows)
except Exception as e:  # noqa: BLE001
    print("酷狗失败", e)
