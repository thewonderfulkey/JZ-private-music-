# -*- coding: utf-8 -*-
"""三问取证：①酷我英文查询 20 条明细是否真无相关；②妖狐是否有酷狗通道；③酷狗官方取流是否可用。"""
import io
import json
import re
import urllib.parse
import urllib.request

OUT = r"C:\Users\17948\DoubaoWork\chats\2026-10-22\new-chat-1\_tmp_build\re_search_probe2.txt"
lines = []


def get(url, ua="kwplayer_ar_12.0.6.4", ref="https://www.kuwo.cn/", timeout=12):
    req = urllib.request.Request(url, headers={"User-Agent": ua, "Referer": ref})
    with urllib.request.urlopen(req, timeout=timeout) as r:
        return r.status, r.read().decode("utf-8", "ignore")


KW = "IVORY TOWER"
u = ("https://search.kuwo.cn/r.s?all=%s&ft=music&rn=20&pn=1&rformat=json&encoding=utf8"
     "&vipver=MUSIC_8.7.8.0_WX" % urllib.parse.quote(KW))
try:
    st, body = get(u)
    names = re.findall(r"SONGNAME':'([^']*)'", body)
    artists = re.findall(r"ARTIST':'([^']*)'", body)
    total = re.search(r"'TOTAL':'(\d+)'", body)
    lines.append("[酷我] status=%s TOTAL=%s 解析 name=%d artist=%d" % (st, total.group(1) if total else "?", len(names), len(artists)))
    for i in range(min(20, len(names))):
        lines.append("   %02d | %s | %s" % (i + 1, names[i], artists[i] if i < len(artists) else "?"))
except Exception as e:
    lines.append("[酷我] ERR %s" % e)
lines.append("")

# 妖狐：是否提供酷狗通道
lines.append("[妖狐] 探测 kugou 通道")
for act in ("search", "song"):
    url = "https://api.yaohud.cn/api/music/kugou?key=nvgKtvzw7CFSNFrDhA6&action=%s&msg=%s&n=1" % (
        act, urllib.parse.quote("IVORY TOWER 泽野弘之"))
    try:
        st, body = get(url, ua="lx", ref="https://api.yaohud.cn/")
        lines.append("   action=%-6s %s :: %s" % (act, st, body.replace("\n", " ")[:300]))
    except Exception as e:
        lines.append("   action=%-6s ERR %s" % (act, e))
lines.append("")

# 酷狗官方取流：先用 song_search_v2 拿 FileHash，再试 play/getdata
lines.append("[酷狗] 搜索 + 取流")
try:
    s = "https://songsearch.kugou.com/song_search_v2?keyword=%s&page=1&pagesize=5" % urllib.parse.quote(KW)
    st, body = get(s, ua="Mozilla/5.0 (Linux; Android 10)", ref="https://www.kugou.com/")
    js = json.loads(body)
    lst = js.get("data", {}).get("lists", [])
    lines.append("   song_search_v2 status=%s 条数=%d" % (st, len(lst)))
    for it in lst[:5]:
        lines.append("     %s | %s | hash=%s | album=%s | dur=%s" % (
            it.get("SongName"), it.get("SingerName"), it.get("FileHash"), it.get("AlbumID"), it.get("Duration")))
    if lst:
        h = lst[0].get("FileHash")
        aid = lst[0].get("AlbumID")
        mid = "a" * 32
        for name, url, ref in [
            ("wwwapi getdata", "https://wwwapi.kugou.com/yy/index.php?r=play/getdata&hash=%s&album_id=%s&mid=%s" % (h, aid, mid), "https://www.kugou.com/"),
            ("m getSongInfo", "https://m.kugou.com/app/i/getSongInfo.php?cmd=playInfo&hash=%s" % h, "https://m.kugou.com/"),
        ]:
            try:
                st2, b2 = get(url, ua="Mozilla/5.0 (Linux; Android 10)", ref=ref)
                lines.append("     %-16s %s :: %s" % (name, st2, b2.replace("\n", " ")[:260]))
            except Exception as e:
                lines.append("     %-16s ERR %s" % (name, e))
except Exception as e:
    lines.append("   酷狗搜索/取流 ERR %s" % e)

io.open(OUT, "w", encoding="utf-8").write("\n".join(lines) + "\n")
print("\n".join(lines))
