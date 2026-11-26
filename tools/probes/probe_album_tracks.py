"""测「按专辑名+歌手能不能拿到整张专辑的曲目」（2026-11-26）。

老板口径：新碟点进去要能像导入歌单那样拿到**这张专辑全部的歌**，且正确；
拿不到就退回"直接播第一首"。所以先把四家的专辑接口都试一遍。

做法：先用各平台自己的搜索找一个属于该专辑的 song，
从结果里读出 album id / albumMid / album_id / ALBUMID，再调各自的专辑曲目接口，
比"返回条数"和"是否全是这张碟的歌"。

跑法：python tools/probes/probe_album_tracks.py
"""
import json
import ssl
import sys
import time
import urllib.parse
import urllib.request

ctx = ssl.create_default_context()
UA = ("Mozilla/5.0 (iPhone; CPU iPhone OS 16_6 like Mac OS X) "
      "AppleWebKit/605.1.15 Mobile/15E148")

ALBUMS = [
    ("叶惠美", "周杰伦", 11),
    ("U87", "陈奕迅", 12),
    ("山歌寥哉", "刀郎", 11),
    ("1989", "Taylor Swift", 13),
]


def get(u, h=None, timeout=15, raw=False):
    r = urllib.request.Request(u)
    r.add_header("User-Agent", UA)
    r.add_header("Referer", "https://music.163.com/")
    for k, v in (h or {}).items():
        r.add_header(k, v)
    with urllib.request.urlopen(r, timeout=timeout, context=ctx) as x:
        body = x.read()
        return body if raw else json.loads(body.decode("utf-8", "ignore"))


def post(u, payload, h=None, timeout=15):
    data = json.dumps(payload).encode()
    r = urllib.request.Request(u, data=data, method="POST")
    r.add_header("User-Agent", UA)
    r.add_header("Content-Type", "application/json")
    r.add_header("Referer", "https://y.qq.com/")
    for k, v in (h or {}).items():
        r.add_header(k, v)
    with urllib.request.urlopen(r, timeout=timeout, context=ctx) as x:
        return json.loads(x.read().decode("utf-8", "ignore"))


# ---------------- 网易 ----------------
def netease_ids(album, artist):
    kw = urllib.parse.quote(f"{album} {artist}")
    j = get(f"https://music.163.com/api/search/get?s={kw}&type=10&limit=5")
    items = ((j.get("result") or {}).get("albums")) or []
    out = []
    for a in items:
        out.append((str(a.get("id")), a.get("name"), a.get("size") or a.get("songCount")))
    return out


def netease_tracks(album_id):
    results = {}
    for path in (f"https://music.163.com/api/album/{album_id}",
                 f"https://music.163.com/api/v1/album/{album_id}",
                 f"https://music.163.com/api/v2/album/{album_id}"):
        try:
            j = get(path)
            al = j.get("album") or {}
            songs = al.get("songs") or j.get("songs") or []
            results[path.rsplit("/api", 1)[1]] = (j.get("code"), len(songs),
                                                  [s.get("name") for s in songs[:4]])
        except Exception as e:
            results[path.rsplit("/api", 1)[1]] = ("ERR", type(e).__name__, str(e)[:40])
    return results


# ---------------- QQ ----------------
def qq_album_id(album, artist):
    kw = urllib.parse.quote(f"{album} {artist}")
    j = get(f"https://c.y.qq.com/soso/fcgi-bin/client_search_cp?p=1&n=10&w={kw}&format=json",
            {"Referer": "https://y.qq.com/"})
    lst = (((j.get("data") or {}).get("song") or {}).get("list")) or []
    for s in lst:
        if s.get("albummid"):
            return s["albummid"], s.get("albumname")
    return None, None


def qq_tracks(album_mid):
    payload = {"comm": {"ct": 24, "cv": 0},
               "req_1": {"module": "music.musichallAlbum.AlbumSongList",
                         "method": "GetAlbumSongList",
                         "param": {"albumMid": album_mid, "begin": 0, "num": 100, "order": 2}}}
    j = post("https://u.y.qq.com/cgi-bin/musicu.fcg", payload)
    data = ((j.get("req_1") or {}).get("data")) or {}
    songs = data.get("songList") or []
    names = []
    for s in songs:
        info = s.get("songInfo") or s
        names.append(info.get("name") or info.get("title"))
    return ((j.get("req_1") or {}).get("code"), len(songs), names[:4])


# ---------------- 酷狗 ----------------
def kugou_album_id(album, artist):
    kw = urllib.parse.quote(f"{album} {artist}")
    j = get(f"https://mobiles.kugou.com/api/v3/search/song?format=json&keyword={kw}"
            "&page=1&pagesize=10&showtype=1", {"Referer": "https://m.kugou.com/"})
    lst = ((j.get("data") or {}).get("info")) or []
    for s in lst:
        if s.get("album_id"):
            return str(s["album_id"]), s.get("album_name")
    return None, None


def kugou_tracks(album_id):
    j = get(f"https://mobiles.kugou.com/api/v3/album/song?albumid={album_id}"
            "&page=1&pagesize=100&plat=0&version=8000", {"Referer": "https://m.kugou.com/"})
    info = ((j.get("data") or {}).get("info")) or []
    names = [s.get("songname") for s in info]
    return (j.get("status"), len(info), names[:4])


# ---------------- 酷我 ----------------
def kuwo_album_id(album, artist):
    kw = urllib.parse.quote(f"{album} {artist}")
    txt = get(f"https://search.kuwo.cn/r.s?all={kw}&ft=music&rn=10&pn=0&rformat=json"
              "&encoding=utf8&vipver=MUSIC_8.7.8.0_WX", {"Referer": "https://www.kuwo.cn/"},
              raw=True).decode("utf-8", "ignore")
    import re
    m = re.findall(r"'ALBUMID':\s*'(\d+)'", txt)
    return (m[0] if m else None)


def kuwo_tracks(album_id):
    j = get(f"https://wapi.kuwo.cn/api/www/album/albumInfo?albumId={album_id}"
            "&pn=1&rn=100&httpsStatus=1", {"Referer": "https://www.kuwo.cn/"})
    d = j.get("data") or {}
    songs = d.get("musicList") or d.get("songs") or []
    return (j.get("code"), len(songs), [s.get("name") for s in songs[:4]], d.get("total"))


def main():
    for album, artist, known in ALBUMS:
        print(f"\n=== 《{album}》/ {artist}（官方曲目数约 {known}）")
        # 网易
        try:
            ids = netease_ids(album, artist)
            print("  网易专辑候选:", ids[:3])
            if ids:
                print("  网易曲目:", netease_tracks(ids[0][0]))
        except Exception as e:
            print("  网易 ERR", type(e).__name__, str(e)[:50])
        time.sleep(0.3)
        # QQ
        try:
            mid, name = qq_album_id(album, artist)
            print("  QQ albumMid:", mid, name)
            if mid:
                print("  QQ 曲目:", qq_tracks(mid))
        except Exception as e:
            print("  QQ ERR", type(e).__name__, str(e)[:50])
        time.sleep(0.3)
        # 酷狗
        try:
            aid, name = kugou_album_id(album, artist)
            print("  酷狗 album_id:", aid, name)
            if aid:
                print("  酷狗曲目:", kugou_tracks(aid))
        except Exception as e:
            print("  酷狗 ERR", type(e).__name__, str(e)[:50])
        time.sleep(0.3)
        # 酷我
        try:
            kid = kuwo_album_id(album, artist)
            print("  酷我 albumId:", kid)
            if kid:
                print("  酷我曲目:", kuwo_tracks(kid))
        except Exception as e:
            print("  酷我 ERR", type(e).__name__, str(e)[:50])
        time.sleep(0.3)


if __name__ == "__main__":
    main()
