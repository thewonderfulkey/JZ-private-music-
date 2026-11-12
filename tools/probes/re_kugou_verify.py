# -*- coding: utf-8 -*-
"""确认两件事：①m.kugou playInfo 给的 url 是不是真音频（Range 探测）；②酷狗搜索两条通道今天是否可用。"""
import io
import json
import ssl
import urllib.parse
import urllib.request

OUT = r"C:\Users\17948\DoubaoWork\chats\2026-10-22\new-chat-1\_tmp_build\re_kugou_verify.txt"
lines = []
UA = "Mozilla/5.0 (Linux; Android 10) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/120 Mobile Safari/537.36"
HASH = "15E02065067C44E32C0DE75A6A63D363"


def get(url, ref="https://m.kugou.com/", timeout=15, insecure=False, rng=None):
    ctx = ssl._create_unverified_context() if insecure else None
    req = urllib.request.Request(url, headers={"User-Agent": UA, "Referer": ref})
    if rng:
        req.add_header("Range", rng)
    with urllib.request.urlopen(req, timeout=timeout, context=ctx) as r:
        return r.status, dict(r.headers), r.read(65536)


# ① 取流 URL 真实性
st, headers, body = get("https://m.kugou.com/app/i/getSongInfo.php?cmd=playInfo&hash=%s" % HASH)
j = json.loads(body.decode("utf-8", "ignore"))
u = j.get("url", "")
lines.append("playInfo url=%s" % u[:120])
lines.append("  声明 bitRate=%s extName=%s duration=%s" % (j.get("bitRate"), j.get("extName"), j.get("duration")))
if u:
    st2, h2, head = get(u, ref="https://m.kugou.com/", rng="bytes=0-4095")
    lines.append("  取流探测 status=%s type=%s crange=%s 头16=%r" % (
        st2, h2.get("Content-Type"), h2.get("Content-Range"), head[:16]))

# ② 搜索通道
lines.append("")
try:
    s = "https://mobilecdn.kugou.com/api/v3/search/song?format=json&keyword=%s&page=1&pagesize=5&showtype=1" % urllib.parse.quote("IVORY TOWER")
    st, h, b = get(s, insecure=True)
    j = json.loads(b.decode("utf-8", "ignore"))
    n = len((j.get("data") or {}).get("info") or [])
    lines.append("mobilecdn(放宽证书) status=%s 条数=%d" % (st, n))
except Exception as e:
    lines.append("mobilecdn ERR %s" % e)

try:
    s2 = "https://songsearch.kugou.com/song_search_v2?keyword=%s&page=1&pagesize=5" % urllib.parse.quote("IVORY TOWER")
    st, h, b = get(s2, ref="https://www.kugou.com/")
    j = json.loads(b.decode("utf-8", "ignore"))
    lst = (j.get("data") or {}).get("lists") or []
    lines.append("song_search_v2 status=%s total=%s 条数=%d" % (st, (j.get("data") or {}).get("total"), len(lst)))
    for it in lst[:5]:
        lines.append("   %s | %s | hash=%s" % (it.get("SongName"), it.get("SingerName"), it.get("FileHash")))
except Exception as e:
    lines.append("song_search_v2 ERR %s" % e)

io.open(OUT, "w", encoding="utf-8").write("\n".join(lines) + "\n")
print("\n".join(lines))
