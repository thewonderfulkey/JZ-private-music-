# -*- coding: utf-8 -*-
"""生成「最新单曲」模块的预览稿（浏览器直接打开，用来对版式）。

数据现取酷我歌单 1082685104 前 9 首（匿名接口，与 App 同源）；取不到时用内置样例，
保证这个脚本在没网时也能跑。只做视觉预览，不进 App。
"""
import html
import json
import urllib.request
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]

FALLBACK = [
    {"name": "涌泉相报", "artist": "刘惜君", "album": "涌泉相报",
     "pic": "https://img4.kuwo.cn/star/albumcover/500/s4s43/68/2072169166.jpg",
     "date": "2026-11-18"},
    {"name": "宝珠", "artist": "李佳薇", "album": "宝珠 影视剧原声带",
     "pic": "https://img4.kuwo.cn/star/albumcover/500/s4s43/68/2072169166.jpg",
     "date": "2026-11-18"},
    {"name": "棠棣赋", "artist": "五月天 阿信", "album": "棠棣赋",
     "pic": "https://img4.kuwo.cn/star/albumcover/500/s4s43/68/2072169166.jpg",
     "date": "2026-11-18"},
]


def fetch_rows(limit=9):
    url = ("https://wapi.kuwo.cn/api/www/playlist/playListInfo"
           "?pid=1082685104&pn=0&rn=100&httpsStatus=1")
    headers = {
        "User-Agent": ("Mozilla/5.0 (iPhone; CPU iPhone OS 16_6 like Mac OS X) "
                       "AppleWebKit/605.1.15 Mobile/15E148 Safari/604.1"),
        "Referer": "https://www.kuwo.cn/",
    }
    try:
        req = urllib.request.Request(url, headers=headers)
        data = json.load(urllib.request.urlopen(req, timeout=20))
        items = data["data"]["musicList"]
        items.sort(key=lambda x: x.get("releaseDate") or "", reverse=True)
        return [{
            "name": x["name"],
            "artist": x["artist"],
            "album": x.get("album") or "",
            "pic": x.get("pic") or x.get("albumpic") or "",
            "date": x.get("releaseDate") or "",
        } for x in items[:limit]]
    except Exception as e:  # 没网 / 接口挂了：用样例，不阻塞预览稿生成
        print(f"取数失败（{e}），用内置样例")
        return FALLBACK


rows = fetch_rows()

cards = []
for i, r in enumerate(rows[:5]):
    album = f"收录于《{r['album']}》" if r["album"] else ""
    cards.append(f"""
      <div class="card">
        <div class="cover" style="background-image:url('{html.escape(r['pic'])}')"></div>
        <div class="panel">
          <div class="blur" style="background-image:url('{html.escape(r['pic'])}')"></div>
          <div class="scrim"></div>
          <div class="text">
            <span class="chip">新单曲</span>
            <div class="spacer"></div>
            <div class="song">{html.escape(r['name'])}</div>
            <div class="artist">{html.escape(r['artist'])}</div>
            <div class="album">{html.escape(album)}</div>
          </div>
          <span class="play">▶</span>
        </div>
      </div>""")

avatars = "".join(
    f"<span class='avatar' style=\"background-image:url('{html.escape(r['pic'])}')\"></span>"
    for r in rows[:3])

doc = f"""<!doctype html>
<html lang="zh-CN"><head>
<meta charset="utf-8">
<title>最新单曲 · 版式预览</title>
<style>
  :root {{
    --paper: #FAF8F3;
    --vermilion: #B03A2E;
    --ink: #16150F;
  }}
  * {{ box-sizing: border-box; }}
  body {{ margin: 0; background: #d9d5cc; font-family: -apple-system, "PingFang SC", "Microsoft YaHei", sans-serif; }}
  .phone {{
    width: 390px; background: var(--paper); padding: 64px 0 26px; color: var(--ink);
  }}
  .status {{ height: 24px; }}
  .row {{ display: flex; align-items: center; gap: 8px; padding: 0 16px; }}
  .stack {{ display: flex; }}
  .avatar {{ width: 22px; height: 22px; border-radius: 50%; background-size: cover; background-position: center;
            border: 1.5px solid var(--paper); margin-left: -8px; }}
  .avatar:first-child {{ margin-left: 0; }}
  h2 {{ font-size: 20px; font-weight: 600; margin: 0; letter-spacing: .2px; }}
  .meta {{ font-size: 12px; color: #8a8578; }}
  .more {{ margin-left: auto; font-size: 13px; color: var(--vermilion); }}
  .cards {{ display: flex; gap: 12px; overflow: hidden; padding: 10px 16px 2px; }}
  .card {{ flex: 0 0 300px; height: 100px; border-radius: 12px; overflow: hidden; display: flex;
           box-shadow: 0 1px 2px rgba(0,0,0,.10); }}
  .cover {{ width: 100px; height: 100px; background-size: cover; background-position: center; flex: 0 0 100px; }}
  .panel {{ position: relative; flex: 1; overflow: hidden; }}
  .blur {{ position: absolute; inset: -12px; background-size: cover; background-position: center;
           filter: blur(16px); transform: scale(1.2); }}
  .scrim {{ position: absolute; inset: 0; background: rgba(0,0,0,.42); }}
  .text {{ position: relative; height: 100%; padding: 8px 32px 8px 12px; display: flex; flex-direction: column; }}
  .chip {{ align-self: flex-start; font-size: 10px; font-weight: 600; color: #fff; background: rgba(255,255,255,.22);
           border-radius: 4px; padding: 2px 6px; }}
  .spacer {{ flex: 1; }}
  .song {{ font-size: 17px; font-weight: 600; color: #fff; white-space: nowrap; overflow: hidden; text-overflow: ellipsis; }}
  .artist {{ font-size: 13px; color: rgba(255,255,255,.72); white-space: nowrap; overflow: hidden; text-overflow: ellipsis; }}
  .album {{ font-size: 11px; color: rgba(255,255,255,.55); white-space: nowrap; overflow: hidden; text-overflow: ellipsis; }}
  .play {{ position: absolute; right: 12px; bottom: 12px; color: rgba(255,255,255,.92); font-size: 12px; }}
  .divider {{ height: 1px; background: rgba(0,0,0,.06); margin: 22px 16px 18px; }}
  .section-title {{ font-size: 20px; font-weight: 600; padding: 0 16px; }}
  .section-sub {{ font-size: 12px; color: #8a8578; padding: 2px 16px 0; }}
</style></head>
<body>
<div class="phone">
  <div class="status"></div>
  <div class="row" style="padding-bottom:12px">
    <h2 style="font-size:17px">最近播放</h2><span class="meta">8 首</span>
  </div>
  <div class="cards" style="padding-top:0;padding-bottom:14px">
    <div style="flex:0 0 104px"><div style="width:104px;height:104px;border-radius:12px;background:linear-gradient(135deg,#c9c2b4,#8d8577)"></div>
      <div style="font-size:13px;font-weight:600;margin-top:8px">心墙</div><div style="font-size:12px;color:#8a8578">林俊杰</div></div>
    <div style="flex:0 0 104px"><div style="width:104px;height:104px;border-radius:12px;background:linear-gradient(135deg,#b7c4c9,#6f8089)"></div>
      <div style="font-size:13px;font-weight:600;margin-top:8px">Departures</div><div style="font-size:12px;color:#8a8578">EGOIST</div></div>
  </div>

  <div class="row">
    <span class="stack">{avatars}</span>
    <h2>最新单曲</h2>
    <span class="meta">每日更新</span>
    <span class="more">查看全部</span>
  </div>
  <div class="cards">{''.join(cards)}</div>

  <div class="divider"></div>
  <div class="section-title">猜你喜欢</div>
  <div class="section-sub">根据你的播放</div>
</div>
</body></html>
"""

out = ROOT / "docs/ios/mockups/new-songs-v1.html"
out.write_text(doc, encoding="utf-8")
print(out)
