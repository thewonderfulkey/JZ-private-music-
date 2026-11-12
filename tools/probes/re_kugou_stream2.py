# -*- coding: utf-8 -*-
"""酷狗取流探活（用已知可用 hash，避免搜索参数干扰）：m.kugou / wwwapi / tracker 三条通道。"""
import io
import json
import urllib.request

OUT = r"C:\Users\17948\DoubaoWork\chats\2026-10-22\new-chat-1\_tmp_build\re_kugou_stream.txt"
lines = []
UA = "Mozilla/5.0 (Linux; Android 10) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/120 Mobile Safari/537.36"
MID = "0123456789abcdef0123456789abcdef"
HASH = "15E02065067C44E32C0DE75A6A63D363"   # 任舒瞳 Ivory Tower（song_search_v2 实测返回）


def get(url, ref="https://m.kugou.com/", timeout=15):
    req = urllib.request.Request(url, headers={"User-Agent": UA, "Referer": ref})
    with urllib.request.urlopen(req, timeout=timeout) as r:
        return r.status, r.read().decode("utf-8", "ignore")


cands = [
    ("m playInfo", "https://m.kugou.com/app/i/getSongInfo.php?cmd=playInfo&hash=%s" % HASH),
    ("wwwapi getdata", "https://wwwapi.kugou.com/yy/index.php?r=play/getdata&hash=%s&album_id=81242842&mid=%s&platid=1" % (HASH, MID)),
    ("tracker 1005", "https://tracker.kugou.com/?cmd=1005&hash=%s&mid=%s" % (HASH, MID)),
    ("tracker 1014", "https://tracker.kugou.com/?cmd=1014&hash=%s&mid=%s" % (HASH, MID)),
]
for name, url in cands:
    try:
        st, b = get(url)
        try:
            j = json.loads(b)
        except Exception:
            lines.append("%-15s %s 非 JSON：%s" % (name, st, b[:180].replace("\n", " ")))
            continue
        if isinstance(j, dict):
            keys = ",".join(sorted(j.keys())[:14])
            d = j.get("data") if isinstance(j.get("data"), dict) else {}
            urlv = j.get("url") or d.get("url") or j.get("play_url") or ""
            lines.append("%-15s %s keys=[%s] code=%s err=%s url=%s" % (
                name, st, keys, j.get("err_code") or j.get("code") or j.get("status"), j.get("error") or j.get("msg") or "", str(urlv)[:110]))
        else:
            lines.append("%-15s %s %s" % (name, st, str(j)[:160]))
    except Exception as e:
        lines.append("%-15s ERR %s" % (name, e))

# 搜索通道再确认：分组关键词（不带空格）
for kw in ("晴天", "周杰伦", "IVORY TOWER"):
    try:
        s = "https://songsearch.kugou.com/song_search_v2?keyword=%s&page=1&pagesize=3&platform=WebFilter&tag=em" % urllib.parse.quote(kw)
        st, b = get(s, ref="https://www.kugou.com/")
        j = json.loads(b)
        lst = (j.get("data") or {}).get("lists") or []
        lines.append("搜索 %-12s total=%s 条数=%d 首条=%s/%s" % (
            kw, (j.get("data") or {}).get("total"), len(lst),
            (lst[0].get("SongName") if lst else "-"), (lst[0].get("SingerName") if lst else "-")))
    except Exception as e:
        lines.append("搜索 %-12s ERR %s" % (kw, e))

import urllib.parse  # noqa: E402  (放在使用之后也无害)
io.open(OUT, "w", encoding="utf-8").write("\n".join(lines) + "\n")
print("\n".join(lines))
