# -*- coding: utf-8 -*-
"""「歌单广场 + 歌手大全」方案预览稿生成器。

取酷我真实数据（歌单封面/播放量、歌手头像/粉丝数、歌单与歌手的前几首歌），
生成 docs/ios/mockups/square-artists.html（5 个 390pt 屏，浏览器直接打开），
并在 .build/ref/screens/ 里为每屏单独生成一个临时页（供截图，不进仓库）。
只做设计预览，不进 App。
"""
import json
import urllib.request
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
SCREENS = ROOT / ".build/ref/screens"
UA = ("Mozilla/5.0 (iPhone; CPU iPhone OS 16_6 like Mac OS X) "
      "AppleWebKit/605.1.15 Mobile/15E148 Safari/604.1")
H = {"User-Agent": UA, "Referer": "https://www.kuwo.cn/",
     "Accept": "application/json, text/javascript, */*; q=0.01"}


def get_json(url):
    req = urllib.request.Request(url, headers=H)
    with urllib.request.urlopen(req, timeout=25) as r:
        return json.loads(r.read())


def wan(n):
    n = int(n or 0)
    if n >= 100_000_000:
        return f"{n / 100_000_000:.1f}亿"
    if n >= 10_000:
        return f"{n / 10_000:.1f}万"
    return str(n)


def esc(s):
    return (s or "").replace("&", "&amp;").replace("<", "&lt;").replace(">", "&gt;").replace('"', "&quot;")


# ---------- 取数 ----------
hot = get_json("https://wapi.kuwo.cn/api/pc/classify/playlist/getRcmPlayList"
               "?pn=1&rn=10&order=hot&pay=0&pow=0&kbps=0")["data"]
new = get_json("https://wapi.kuwo.cn/api/pc/classify/playlist/getRcmPlayList"
               "?pn=1&rn=10&order=new")["data"]
artists = get_json("https://wapi.kuwo.cn/api/www/artist/artistInfo?pn=1&rn=12")["data"]
playlists = (hot["data"] + new["data"])[:10]
artist_list = artists["artistList"]

detail_pid = playlists[0]["id"]
detail = get_json(f"https://wapi.kuwo.cn/api/www/playlist/playListInfo"
                  f"?pid={detail_pid}&pn=0&rn=5&httpsStatus=1")["data"]
detail_songs = detail["musicList"]

jay = get_json("https://wapi.kuwo.cn/api/www/artist/artistMusic?artistid=336&pn=1&rn=5")["data"]
jay_artist = next(a for a in artist_list if a["id"] == 336)
jay_songs = jay["list"]

today = get_json("https://wapi.kuwo.cn/api/www/playlist/playListInfo"
                 "?pid=1082685104&pn=0&rn=6&httpsStatus=1")["data"]["musicList"]
today.sort(key=lambda x: x.get("releaseDate") or "", reverse=True)


# ---------- 组件 ----------
def playlist_card(p, w=132):
    return f"""
      <div class="pl" style="width:{w}px">
        <div class="cover" style="width:{w}px;height:{w}px">
          <img src="{esc(p['img'])}" alt="">
          <span class="count">♫ {wan(p['listencnt'])}</span>
        </div>
        <div class="pl-name">{esc(p['name'])}</div>
      </div>"""


def playlist_grid_card(p, w=171):
    return f"""
      <div class="pl grid" style="width:{w}px">
        <div class="cover" style="width:{w}px;height:{w}px">
          <img src="{esc(p['img'])}" alt="">
          <span class="count">♫ {wan(p['listencnt'])}</span>
        </div>
        <div class="pl-name">{esc(p['name'])}</div>
        <div class="pl-meta">{p['total']} 首 · {esc(p['uname'])}</div>
      </div>"""


def artist_cell(a, size=64, width=64):
    return f"""
      <div class="ar" style="width:{width}px">
        <img class="a-pic" style="width:{size}px;height:{size}px" src="{esc(a['pic120'])}" alt="">
        <div class="a-name">{esc(a['name'])}</div>
        <div class="a-fans">{wan(a['artistFans'])}</div>
      </div>"""


def song_row(s, idx=None):
    pic = esc(s.get("pic") or s.get("albumpic") or "")
    rank = f"<span class='idx'>{idx:02d}</span>" if idx else ""
    album = esc(s.get("album") or "")
    return f"""
      <div class="song">
        {rank}
        <img class="s-pic" src="{pic}" alt="">
        <div class="s-text">
          <div class="s-name">{esc(s.get('name'))}</div>
          <div class="s-sub">{esc(s.get('artist'))}{(' · ' + album) if album else ''}</div>
        </div>
        <span class="chip">酷我</span>
        <span class="s-dur">{s.get('songTimeMinutes') or ''}</span>
        <span class="heart">♡</span>
      </div>"""


def new_song_card(item):
    album = f"收录于《{esc(item.get('album'))}》" if item.get("album") else ""
    return f"""
      <div class="ns">
        <img class="ns-cover" src="{esc(item.get('pic'))}" alt="">
        <div class="ns-panel">
          <img class="ns-blur" src="{esc(item.get('pic'))}" alt="">
          <div class="ns-scrim"></div>
          <div class="ns-text">
            <span class="ns-chip">新单曲</span>
            <div class="spacer"></div>
            <div class="ns-name">{esc(item.get('name'))}</div>
            <div class="ns-artist">{esc(item.get('artist'))}</div>
            <div class="ns-album">{album}</div>
          </div>
          <span class="ns-play">▶</span>
        </div>
      </div>"""


def chips(items, active=0):
    out = "".join(
        f"<span class='chip-pill{(' on' if i == active else '')}'>{esc(it)}</span>"
        for i, it in enumerate(items))
    return f"<div class='chips'>{out}</div>"


letters = ["热门"] + [chr(c) for c in range(ord("A"), ord("Z") + 1)] + ["#"]
letter_bar = "".join(
    f"<span class='letter{(' on' if i == 0 else '')}'>{x}</span>" for i, x in enumerate(letters[:16]))

hot_cards = "".join(playlist_card(p) for p in playlists[:4])
grid_cards = "".join(playlist_grid_card(p) for p in playlists[:6])
artist_row = "".join(artist_cell(a) for a in artist_list[:5])
artist_grid = "".join(
    f"""
      <div class="ag">
        <img class="a-pic" style="width:88px;height:88px" src="{esc(a['pic120'])}" alt="">
        <div class="a-name">{esc(a['name'])}</div>
        <div class="a-fans">{wan(a['artistFans'])}</div>
      </div>""" for a in artist_list[:12])
detail_rows = "".join(song_row(s) for s in detail_songs)
jay_rows = "".join(song_row(s) for s in jay_songs)

recent = [s for s in detail_songs[1:3]]

CSS = """
  * { box-sizing: border-box; }
  body { margin: 0; background: #FAF8F3; font-family: -apple-system, "PingFang SC", "Microsoft YaHei", sans-serif; }
  .label { font-size: 13px; color: #4c473d; margin: 0 0 10px 2px; letter-spacing: .3px; }
  .phone { width: 390px; background: #FAF8F3; color: #16150F; padding: 56px 0 22px; overflow: hidden; }
  .nav { position: relative; height: 44px; display: flex; align-items: center; justify-content: center;
         font-size: 17px; font-weight: 600; }
  .nav .back { position: absolute; left: 14px; font-size: 22px; font-weight: 400; color: #16150F; top: 8px; }
  .large-title { font-size: 34px; font-weight: 700; padding: 4px 16px 12px; letter-spacing: .2px; }
  .search { margin: 0 16px 18px; height: 42px; border-radius: 21px; background: #FFFDF8;
            display: flex; align-items: center; gap: 8px; padding: 0 12px; color: #9A9486; font-size: 15px; }
  .search .hint { margin-left: auto; font-size: 11px; }
  .section-head { display: flex; align-items: center; gap: 8px; padding: 0 16px; margin: 0 0 10px; }
  .section-head h2 { font-size: 20px; font-weight: 600; margin: 0; letter-spacing: .2px; }
  .meta { font-size: 12px; color: #9A9486; }
  .more { margin-left: auto; font-size: 13px; color: #B03A2E; }
  .cards { display: flex; gap: 12px; padding: 0 16px 22px 16px; }
  .cover { position: relative; border-radius: 12px; overflow: hidden; background: #E8E3D8; flex: 0 0 auto; }
  .cover img { width: 100%; height: 100%; object-fit: cover; display: block; }
  .count { position: absolute; left: 8px; bottom: 8px; font-size: 11px; color: #fff;
           background: rgba(0,0,0,.42); border-radius: 8px; padding: 2px 6px; letter-spacing: .2px; }
  .pl-name { font-size: 15px; font-weight: 500; line-height: 1.35; margin-top: 8px;
             display: -webkit-box; -webkit-line-clamp: 2; -webkit-box-orient: vertical; overflow: hidden; }
  .pl-meta { font-size: 12px; color: #9A9486; margin-top: 4px; }
  .artists { display: flex; gap: 8px; padding: 0 16px 22px; }
  .ar { text-align: center; }
  .a-pic { border-radius: 50%; object-fit: cover; display: block; margin: 0 auto; background: #E8E3D8; }
  .a-name { font-size: 12.5px; font-weight: 500; margin-top: 7px; white-space: nowrap; overflow: hidden; text-overflow: ellipsis; }
  .a-fans { font-size: 11px; color: #9A9486; margin-top: 1px; }
  .chips { display: flex; gap: 8px; padding: 4px 16px 14px; overflow: hidden; }
  .chip-pill { flex: 0 0 auto; font-size: 13px; color: #6F6A5E; background: #FFFDF8;
               border-radius: 16px; padding: 6px 12px; }
  .chip-pill.on { background: #16150F; color: #FAF8F3; font-weight: 500; }
  .letters { display: flex; gap: 10px; padding: 0 16px 12px; overflow: hidden; align-items: center;
             -webkit-mask-image: linear-gradient(to right, #000 90%, transparent); }
  .letter { font-size: 12px; color: #9A9486; flex: 0 0 auto; }
  .letter.on { color: #16150F; font-weight: 700; border-bottom: 2px solid #B03A2E; padding-bottom: 1px; }
  .list-meta { font-size: 12px; color: #9A9486; padding: 0 16px 12px; }
  .gridwrap { display: grid; grid-template-columns: 171px 171px; gap: 16px 16px; padding: 0 16px 18px; }
  .artist-grid { display: grid; grid-template-columns: repeat(3, 1fr); gap: 18px 8px; padding: 0 16px 18px; }
  .ag { text-align: center; }
  .ag .a-name { font-size: 13px; }
  .head-card { display: flex; gap: 14px; padding: 4px 16px 14px; }
  .head-cover { width: 112px; height: 112px; border-radius: 12px; object-fit: cover; flex: 0 0 112px; background: #E8E3D8; }
  .head-avatar { width: 88px; height: 88px; border-radius: 50%; object-fit: cover; flex: 0 0 88px; background: #E8E3D8; }
  .head-info { display: flex; flex-direction: column; justify-content: center; gap: 6px; min-width: 0; }
  .head-title { font-size: 20px; font-weight: 600; line-height: 1.3; display: -webkit-box;
                -webkit-line-clamp: 2; -webkit-box-orient: vertical; overflow: hidden; }
  .head-sub { font-size: 13px; color: #6F6A5E; }
  .play-all { margin: 0 16px 8px; height: 36px; border-radius: 12px; background: #B03A2E; color: #fff;
              display: inline-flex; align-items: center; gap: 6px; padding: 0 18px; font-size: 15px; font-weight: 600; }
  .song { display: flex; align-items: center; gap: 12px; padding: 10px 16px; }
  .song .idx { width: 22px; font-size: 12px; color: #B03A2E; font-weight: 600; }
  .s-pic { width: 52px; height: 52px; border-radius: 8px; object-fit: cover; background: #E8E3D8; }
  .s-text { min-width: 0; flex: 1; }
  .s-name { font-size: 17px; white-space: nowrap; overflow: hidden; text-overflow: ellipsis; }
  .s-sub { font-size: 13px; color: #6F6A5E; margin-top: 3px; white-space: nowrap; overflow: hidden; text-overflow: ellipsis; }
  .chip { font-size: 10px; color: #6F6A5E; border: 1px solid rgba(0,0,0,.10); background: rgba(0,0,0,.03);
          border-radius: 999px; padding: 2px 7px; flex: 0 0 auto; }
  .s-dur { font-size: 12px; color: #9A9486; font-variant-numeric: tabular-nums; }
  .heart { font-size: 16px; color: #9A9486; }
  .divider { height: 1px; background: rgba(0,0,0,.06); margin: 14px 16px 16px; }
  .section-title { font-size: 20px; font-weight: 600; padding: 0 16px 8px; }
  .ns { display: flex; width: 300px; height: 100px; border-radius: 12px; overflow: hidden; flex: 0 0 auto; }
  .ns-cover { width: 100px; height: 100px; object-fit: cover; flex: 0 0 100px; }
  .ns-panel { position: relative; flex: 1; overflow: hidden; }
  .ns-blur { position: absolute; inset: -12px; width: 220px; height: 124px; object-fit: cover; filter: blur(16px); }
  .ns-scrim { position: absolute; inset: 0; background: rgba(0,0,0,.42); }
  .ns-text { position: relative; height: 100%; padding: 8px 30px 8px 12px; display: flex; flex-direction: column; }
  .ns-chip { align-self: flex-start; font-size: 10px; font-weight: 600; color: #fff; background: rgba(255,255,255,.22);
             border-radius: 4px; padding: 2px 6px; }
  .spacer { flex: 1; }
  .ns-name { font-size: 17px; font-weight: 600; color: #fff; white-space: nowrap; overflow: hidden; text-overflow: ellipsis; }
  .ns-artist { font-size: 13px; color: rgba(255,255,255,.72); white-space: nowrap; overflow: hidden; text-overflow: ellipsis; }
  .ns-album { font-size: 11px; color: rgba(255,255,255,.55); white-space: nowrap; overflow: hidden; text-overflow: ellipsis; }
  .ns-play { position: absolute; right: 12px; bottom: 12px; color: rgba(255,255,255,.92); font-size: 12px; }
"""

# ---------- 五屏 ----------
p1 = f"""
  <div class="large-title">发现</div>
  <div class="search"><span>⌕</span><span>搜索歌曲、歌手、专辑</span><span class="hint">四家一起找</span></div>

  <div class="section-head"><h2>歌单广场</h2><span class="meta">{hot['total']} 张</span><span class="more">查看全部</span></div>
  <div class="cards">{hot_cards}</div>

  <div class="section-head"><h2>歌手大全</h2><span class="meta">{artists['total']} 位</span><span class="more">查看全部</span></div>
  <div class="artists">{artist_row}</div>

  <div class="section-head"><h2>最近播放</h2><span class="meta">8 首</span></div>
  <div class="cards">
    <div class="pl" style="width:104px"><div class="cover" style="width:104px;height:104px">
      <img src="{esc(recent[0].get('pic'))}" alt=""></div>
      <div class="pl-name">{esc(recent[0].get('name'))}</div><div class="pl-meta">{esc(recent[0].get('artist'))}</div></div>
    <div class="pl" style="width:104px"><div class="cover" style="width:104px;height:104px">
      <img src="{esc(recent[1].get('pic'))}" alt=""></div>
      <div class="pl-name">{esc(recent[1].get('name'))}</div><div class="pl-meta">{esc(recent[1].get('artist'))}</div></div>
  </div>

  <div class="section-head"><h2>最新单曲</h2><span class="meta">每日更新</span><span class="more">查看全部</span></div>
  <div class="cards">{new_song_card(today[0])}{new_song_card(today[1])}</div>
"""

p2 = f"""
  <div class="nav"><span class="back">‹</span>歌单广场</div>
  {chips(["热门", "最新"])}
  <div class="list-meta">{hot['total']} 张热门歌单 · 按播放量排序</div>
  <div class="gridwrap">{grid_cards}</div>
"""

p3 = f"""
  <div class="nav"><span class="back">‹</span>歌手大全</div>
  {chips(["全部", "华语", "欧美", "组合", "日韩男", "日韩女"])}
  <div class="letters">{letter_bar}</div>
  <div class="list-meta">{artists['total']} 位 · 按粉丝排序</div>
  <div class="artist-grid">{artist_grid}</div>
"""

p4 = f"""
  <div class="nav"><span class="back">‹</span>歌单</div>
  <div class="head-card">
    <img class="head-cover" src="{esc(detail['img'])}" alt="">
    <div class="head-info">
      <div class="head-title">{esc(detail['name'])}</div>
      <div class="head-sub">{esc(detail.get('userName') or detail['uname'])}</div>
      <div class="head-sub">{detail['total']} 首 · {wan(detail.get('listencnt'))}播放</div>
    </div>
  </div>
  <div class="play-all">▶ 播放全部</div>
  {detail_rows}
"""

p5 = f"""
  <div class="nav"><span class="back">‹</span>歌手</div>
  <div class="head-card">
    <img class="head-avatar" src="{esc(jay_artist['pic300'])}" alt="">
    <div class="head-info">
      <div class="head-title">{esc(jay_artist['name'])}</div>
      <div class="head-sub">{wan(jay_artist['artistFans'])}粉丝 · {jay_artist['musicNum']} 首</div>
    </div>
  </div>
  <div class="play-all">▶ 播放全部</div>
  <div class="divider"></div>
  <div class="section-title">热门歌曲</div>
  {jay_rows}
"""

screens = [(p1, "① 发现页：编辑精选 → 歌单广场 + 歌手大全（搜索之下，最近播放之上）"),
           (p2, "② 歌单广场整页：热门 / 最新 + 双列封面墙"),
           (p3, "③ 歌手大全整页：分类 + A–Z + 头像墙（按粉丝排序）"),
           (p4, "④ 歌单详情：封面头图 + 播放全部 + 统一 SongRow"),
           (p5, "⑤ 歌手页：头像 + 粉丝 + 播放全部 + 热门歌曲")]

master = [f"<!doctype html><html lang='zh-CN'><head><meta charset='utf-8'>"
          f"<title>歌单广场 + 歌手大全 · 方案预览</title><style>{CSS}"
          f".frame{{padding:28px}} body{{background:#cfcac0}}</style></head><body>"]
for body, label in screens:
    master.append(f"<div class='frame'><div class='label'>{label}</div><div class='phone'>{body}</div></div>")
master.append("</body></html>")
out = ROOT / "docs/ios/mockups/square-artists.html"
out.write_text("".join(master), encoding="utf-8")

SCREENS.mkdir(parents=True, exist_ok=True)
for i, (body, _) in enumerate(screens, start=1):
    page = (f"<!doctype html><html lang='zh-CN'><head><meta charset='utf-8'>"
            f"<meta name='viewport' content='width=390'>"
            f"<title>screen {i}</title><style>{CSS}</style><style>.phone{{padding-top:90px}}</style></head><body>"
            f"<div class='phone'>{body}</div></body></html>")
    (SCREENS / f"s{i}.html").write_text(page, encoding="utf-8")

print(out)
print(SCREENS)
