# -*- coding: utf-8 -*-
"""酷狗取流到底通不通：拿 song_search_v2 的 hash，分别问 m.kugou / wwwapi，打印是否含可用 url。"""
import io
import json
import urllib.parse
import urllib.request

OUT = r"C:\Users\17948\DoubaoWork\chats\2026-10-22\new-chat-1\_tmp_build\re_kugou_stream.txt"
lines = []
UA = "Mozilla/5.0 (Linux; Android 10) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/120 Mobile Safari/537.36"


def get(url, ref="https://www.kugou.com/", timeout=15):
    req = urllib.request.Request(url, headers={"User-Agent": UA, "Referer": ref})
    with urllib.request.urlopen(req, timeout=timeout) as r:
        return r.status, r.read().decode("utf-8", "ignore")


# 先拿真实 hash（原唱 IVORY TOWER 未必有，用「周杰伦 晴天」做对照，确保有正版条目）
kw = "晴天 周杰伦"
s = "https://songsearch.kugou.com/song_search_v2?keyword=%s&page=1&pagesize=3" % urllib.parse.quote(kw)
st, body = get(s)
js = json.loads(body)
lists = js.get("data", {}).get("lists", [])
lines.append("搜索 %s：status=%s 条数=%d" % (kw, st, len(lists)))
for it in lists[:3]:
    lines.append("  %s | %s | hash=%s | album=%s | dur=%s" % (
        it.get("SongName"), it.get("SingerName"), it.get("FileHash"), it.get("AlbumID"), it.get("Duration")))

if lists:
    it = lists[0]
    h = it.get("FileHash")
    aid = it.get("AlbumID") or 0
    candidates = [
        ("m.kugou playInfo", "https://m.kugou.com/app/i/getSongInfo.php?cmd=playInfo&hash=%s" % h),
        ("wwwapi getdata", "https://wwwapi.kugou.com/yy/index.php?r=play/getdata&hash=%s&album_id=%s&mid=%s&platid=1&_=%d" % (
            h, aid, "0123456789abcdef0123456789abcdef", 1)),
        ("tracker yue", "https://tracker.kugou.com/?cmd=1005&hash=%s&mid=%s" % (h, "0123456789abcdef0123456789abcdef")),
    ]
    for name, url in candidates:
        try:
            st2, b2 = get(url, ref="https://m.kugou.com/")
            try:
                j = json.loads(b2)
            except Exception:
                lines.append("  %-16s %s 非 JSON：%s" % (name, st2, b2[:160]))
                continue
            urlv = j.get("url") or (j.get("data") or {}).get("url") if isinstance(j, dict) else None
            keys = sorted(j.keys())[:12] if isinstance(j, dict) else "?"
            lines.append("  %-16s %s keys=%s url=%s" % (name, st2, keys, (urlv or "")[:120]))
        except Exception as e:
            lines.append("  %-16s ERR %s" % (name, e))

io.open(OUT, "w", encoding="utf-8").write("\n".join(lines) + "\n")
print("\n".join(lines))
