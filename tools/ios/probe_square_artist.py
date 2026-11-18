# -*- coding: utf-8 -*-
"""酷我「歌单广场 / 歌手大全」接口体检（2026-11-18 实测口径，方案见 docs/ios/IOS-SQUARE-ARTIST-PLAN.md）。

跑法：python tools/ios/probe_square_artist.py
输出：各接口 total、字段、分类 id 含义、以及"标签歌单不可用"的证据。
不写任何文件、不改仓库。
"""
import json
import urllib.request

UA = ("Mozilla/5.0 (iPhone; CPU iPhone OS 16_6 like Mac OS X) "
      "AppleWebKit/605.1.15 Mobile/15E148 Safari/604.1")
HEADERS = {"User-Agent": UA, "Referer": "https://www.kuwo.cn/",
           "Accept": "application/json, text/javascript, */*; q=0.01"}


def get(url):
    req = urllib.request.Request(url, headers=HEADERS)
    with urllib.request.urlopen(req, timeout=20) as r:
        return json.loads(r.read())


def playlist_total(order):
    j = get("https://wapi.kuwo.cn/api/pc/classify/playlist/getRcmPlayList"
            f"?pn=1&rn=3&order={order}&pay=0&pow=0&kbps=0")
    d = j["data"]
    print(f"歌单 order={order}: total={d['total']} 字段={list(d['data'][0].keys())[:8]}")
    for it in d["data"]:
        print("   ", it["name"], "|", it["uname"], "|", it["total"], "首 |", it["listencnt"], "播放")


def artist_total(category, prefix=""):
    j = get("https://wapi.kuwo.cn/api/www/artist/artistInfo"
            f"?pn=1&rn=3&category={category}&prefix={prefix}")
    d = j["data"]
    names = [a["name"] for a in d["artistList"]]
    return d["total"], names


def main():
    print("== 歌单广场")
    playlist_total("hot")
    playlist_total("new")

    print("\n== 歌单详情（取热门第一张）")
    pid = get("https://wapi.kuwo.cn/api/pc/classify/playlist/getRcmPlayList"
              "?pn=1&rn=1&order=hot")["data"]["data"][0]["id"]
    d = get(f"https://wapi.kuwo.cn/api/www/playlist/playListInfo?pid={pid}&pn=0&rn=3&httpsStatus=1")["data"]
    print(f"  {d['name']} | {d.get('userName')} | {d['total']} 首 | {d.get('listencnt')} 播放")
    print("  歌曲字段:", list(d["musicList"][0].keys())[:12])

    print("\n== 歌手分类 id → total（样本 3 位）")
    for c in (0, 1, 2, 3, 4, 5, 6, 7, 8, 9, 11, 12, 13):
        total, names = artist_total(c)
        print(f"  category={c:<3} total={total:<6} {names}")

    print("\n== A–Z 与分类叠加")
    for c, p in ((0, "A"), (11, "Z")):
        total, names = artist_total(c, p)
        print(f"  category={c} prefix={p}: total={total} {names}")

    print("\n== 歌手歌曲")
    j = get("https://wapi.kuwo.cn/api/www/artist/artistMusic?artistid=336&pn=1&rn=3")["data"]
    print(f"  周杰伦 total={j['total']} 歌曲字段={list(j['list'][0].keys())[:12]}")

    print("\n== 标签歌单（匿名不可用，证据）")
    for tag_id in ("211", "87", "8"):
        j = get("https://wapi.kuwo.cn/api/pc/classify/playlist/getTagPlayList"
                f"?id={tag_id}&pn=1&rn=5&order=hot&httpsStatus=1")
        print(f"  id={tag_id}: total={j['data']['total']}（0 = 取不到分类歌单）")


if __name__ == "__main__":
    main()
