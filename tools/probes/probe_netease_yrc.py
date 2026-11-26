"""测网易 yrc（逐字歌词）命中率：30 首常听歌，搜索→取 id→取歌词看有没有 yrc。

为什么测这个（2026-11-26）：AMLL TTML 库里 `ncm-lyrics/*.yrc` 说明网易本身有逐字歌词，
而我们现在的网易歌词只取 `lrc`（逐行）。如果 yrc 命中率够高，这就是第三条逐字来源，
而且零新依赖（同一个接口，多一个 `yv=-1` 参数）。
"""
import json
import ssl
import sys
import time
import urllib.parse
import urllib.request

ctx = ssl.create_default_context()
UA = "Mozilla/5.0 (iPhone; CPU iPhone OS 16_6 like Mac OS X) AppleWebKit/605.1.15 Mobile/15E148"

TARGETS = [
    ("晴天", "周杰伦"), ("七里香", "周杰伦"), ("稻香", "周杰伦"), ("夜曲", "周杰伦"),
    ("演员", "薛之谦"), ("大鱼", "周深"), ("孤勇者", "陈奕迅"), ("海阔天空", "Beyond"),
    ("富士山下", "陈奕迅"), ("平凡之路", "朴树"), ("后来", "刘若英"),
    ("起风了", "买辣椒也用券"), ("漠河舞厅", "柳爽"), ("如愿", "王菲"),
    ("唯一", "告五人"), ("罗刹海市", "刀郎"),
    ("Shape of You", "Ed Sheeran"), ("Viva La Vida", "Coldplay"),
    ("告白气球", "周杰伦"), ("青花瓷", "周杰伦"),
    ("十年", "陈奕迅"), ("红玫瑰", "陈奕迅"),
    ("光年之外", "邓紫棋"), ("泡沫", "邓紫棋"),
    ("消愁", "毛不易"), ("年少有为", "李荣浩"),
    ("吻别", "张学友"), ("忘情水", "刘德华"),
    ("倔强", "五月天"), ("突然好想你", "五月天"),
    ("小幸运", "田馥甄"), ("云烟成雨", "房东的猫"),
    ("奇妙能力歌", "陈粒"), ("成都", "赵雷"),
    ("山丘", "李宗盛"), ("月亮代表我的心", "邓丽君"),
    ("认真的雪", "薛之谦"),
    ("Rolling in the Deep", "Adele"), ("Love Story", "Taylor Swift"),
    ("Lemon", "米津玄師"),
]


def get(u, h=None, t=20):
    r = urllib.request.Request(u)
    r.add_header("User-Agent", UA)
    for k, v in (h or {}).items():
        r.add_header(k, v)
    with urllib.request.urlopen(r, timeout=t, context=ctx) as x:
        return x.read()


def search_id(name, artist):
    kw = urllib.parse.quote(f"{name} {artist}")
    b = get(f"https://music.163.com/api/search/get?s={kw}&type=1&limit=5",
            {"Referer": "https://music.163.com/"})
    j = json.loads(b)
    songs = ((j.get("result") or {}).get("songs")) or []
    for s in songs:
        if s.get("name", "").strip().lower() == name.strip().lower():
            return str(s.get("id"))
    return str(songs[0]["id"]) if songs else None


def lyric(sid):
    b = get(f"https://music.163.com/api/song/lyric?id={sid}&lv=-1&kv=-1&tv=-1&yv=-1",
            {"Referer": "https://music.163.com/"})
    j = json.loads(b)
    yrc = (j.get("yrc") or {}).get("lyric") or ""
    lrc = (j.get("lrc") or {}).get("lyric") or ""
    return len([x for x in yrc.splitlines() if x.strip()]), len([x for x in lrc.splitlines() if x.strip()])


rows = []
for name, artist in TARGETS:
    sid = None
    y = l = 0
    try:
        sid = search_id(name, artist)
        if sid:
            y, l = lyric(sid)
    except Exception as e:
        print("ERR", name, type(e).__name__, str(e)[:60])
    ok = y > 5
    rows.append((name, artist, sid, y, l, ok))
    print(f"{'Y' if ok else '-'} {name:<12} id={sid or '—':<12} yrc={y:<3} lrc={l:<3}")
    time.sleep(0.4)

hit = sum(1 for r in rows if r[5])
print(f"\n命中 {hit}/{len(rows)} = {hit / len(rows) * 100:.0f}%")
out = [{"name": r[0], "artist": r[1], "id": r[2], "yrcLines": r[3], "lrcLines": r[4], "hit": r[5]}
       for r in rows]
open("tools/probes/out/netease_yrc_hit_20261126.json", "w", encoding="utf-8").write(
    json.dumps({"hit": hit, "total": len(rows), "rows": out}, ensure_ascii=False, indent=2))
