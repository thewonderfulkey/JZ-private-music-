"""星海/ikun 的参数名对不上，逐个试；确认今晚这两家到底能不能出周杰伦的真音频。

星海：?source=kw&name=&<ID参数>=&quality=
  ID 参数候选：musicId / songid / id / rid / songmid
ikun：POST https://c.wwwweb.top/music/url  {source, musicId, quality}
  source 候选：kw / kuwo / tx / qq / wy / netease
"""
import json
import ssl
import time
import urllib.parse
import urllib.request

UA = ("Mozilla/5.0 (Linux; Android 10; K) AppleWebKit/537.36 (KHTML, like Gecko) "
      "Chrome/122.0 Mobile Safari/537.36")
CTX = ssl.create_default_context()
CTX.check_hostname = False
CTX.verify_mode = ssl.CERT_NONE

KW_RID = "228908"
QQ_MID = "0039MnYb0qxYhV"
WY_ID = "186016"


def req(url, headers=None, timeout=20, method="GET", body=None, read=0):
    h = {"User-Agent": UA}
    h.update(headers or {})
    data = json.dumps(body).encode() if isinstance(body, dict) else body
    r = urllib.request.Request(url, headers=h, data=data, method=method)
    t0 = time.time()
    try:
        with urllib.request.urlopen(r, timeout=timeout, context=CTX) as resp:
            b = resp.read(read) if read else resp.read()
            return resp.status, b, int((time.time() - t0) * 1000)
    except urllib.error.HTTPError as e:
        return e.code, e.read()[:300], int((time.time() - t0) * 1000)
    except Exception as e:  # noqa: BLE001
        return None, str(e).encode(), int((time.time() - t0) * 1000)


def probe_audio(url, dur=344):
    h = {"Range": "bytes=0-2047", "Referer": "https://www.kuwo.cn/"}
    st, head, ms = req(url, h, timeout=25, read=2048)
    if not str(url).startswith("http"):
        return "非 URL"
    hdr = {}
    # 再取一次拿总长
    st2, head2, ms2 = req(url, h, timeout=25, read=2048)
    return f"status={st} {ms}ms"


print("=" * 72)
print("星海 酷我：换个 ID 参数名试")
print("=" * 72)
for param in ["musicId", "songid", "id", "rid", "songmid", "musicid", "music_id"]:
    u = (f"https://yy.zddyr.top/lx/api/?source=kw&name="
         + urllib.parse.quote("晴天 周杰伦") + f"&{param}={KW_RID}&quality=320kmp3")
    st, body, ms = req(u, {"Referer": "https://www.kuwo.cn/"}, timeout=20)
    txt = body.decode("utf-8", "replace")
    ok = '"url"' in txt
    print(f"  {param:9s} {st} {ms}ms {'★有 url' if ok else ''} → {txt[:150]}")

print()
print("=" * 72)
print("星海 酷狗：hash 直给（晴天酷狗 hash 前 12 位 1B56126A5CBC，先看参数校验）")
print("=" * 72)
for param in ["musicId", "mainHash", "hash", "songid"]:
    u = (f"https://yy.zddyr.top/lx/api/?source=kg&quality=320kmp3&{param}=1B56126A5CBC")
    st, body, ms = req(u, {"Referer": "https://m.kugou.com/"}, timeout=20)
    txt = body.decode("utf-8", "replace")
    print(f"  {param:9s} {st} {ms}ms {'★有 url' if '\"url\"' in txt else ''} → {txt[:150]}")

print()
print("=" * 72)
print("ikun（c.wwwweb.top/music/url）按它要的字段 POST")
print("=" * 72)
for source, mid, quality in [("kw", KW_RID, "320k"), ("kuwo", KW_RID, "320k"),
                             ("tx", QQ_MID, "320k"), ("qq", QQ_MID, "320k"),
                             ("wy", WY_ID, "320k"), ("netease", WY_ID, "320k")]:
    body = {"source": source, "musicId": mid, "quality": quality}
    st, b, ms = req("https://c.wwwweb.top/music/url",
                    {"Content-Type": "application/json", "Accept": "application/json"},
                    timeout=20, method="POST", body=body)
    txt = b.decode("utf-8", "replace")
    print(f"  {source:8s} {mid:16s} {quality} → {st} {ms}ms {txt[:170]}")
    time.sleep(1)
