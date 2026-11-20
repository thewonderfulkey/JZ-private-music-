"""最终确认：两条今晚还活着的聚合链，能不能把周杰伦《晴天》出成**真音频**。

A. 星海酷我跳板：https://yy.zddyr.top/lx/api/kwplay.php?mid=228908&q=320kmp3&ts=&s=
B. ikun 酷我：POST c.wwwweb.top/music/url {source:kw, musicId:228908, quality:320k}
C. ikun QQ：  POST c.wwwweb.top/music/url {source:tx, musicId:0039MnYb0qxYhV, quality:320k}
D. 星海 flac 档 / ikun flac 档
每条都跟 302、Range 取 0-2047、再取全量算 md5（对照酷我占位 43fe5f64…）。
"""
import hashlib
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
PLACEHOLDER = "43fe5f6460e49afdf0bc2340012fe7b5"
KW_RID, QQ_MID = "228908", "0039MnYb0qxYhV"


def req(url, headers=None, timeout=25, method="GET", body=None, read=0):
    h = {"User-Agent": UA}
    h.update(headers or {})
    data = json.dumps(body).encode() if isinstance(body, dict) else body
    r = urllib.request.Request(url, headers=h, data=data, method=method)
    t0 = time.time()
    try:
        with urllib.request.urlopen(r, timeout=timeout, context=CTX) as resp:
            b = resp.read(read) if read else resp.read()
            return resp.status, b, int((time.time() - t0) * 1000), dict(resp.headers), resp.geturl()
    except urllib.error.HTTPError as e:
        return e.code, e.read()[:300], int((time.time() - t0) * 1000), dict(e.headers or {}), url
    except Exception as e:  # noqa: BLE001
        return None, str(e).encode(), int((time.time() - t0) * 1000), {}, url


def facts(url, label, dur=344):
    st, head, ms, hd, final = req(url, {"Range": "bytes=0-2047", "Referer": "https://www.kuwo.cn/"},
                                   timeout=30, read=2048)
    cr = str(hd.get("Content-Range") or hd.get("Content-Length") or "")
    total = 0
    if "/" in cr:
        try:
            total = int(cr.split("/")[-1])
        except Exception:  # noqa: BLE001
            pass
    elif cr.isdigit():
        total = int(cr)
    container = "?"
    if head[:4] == b"fLaC":
        container = "flac"
    elif head[:3] == b"ID3":
        container = "mp3(ID3)"
    elif head[:1] == b"\xff" and len(head) > 1 and (head[1] & 0xE0) == 0xE0:
        container = "mp3"
    elif head[4:8] == b"ftyp":
        container = "m4a"
    elif head[:1] in (b"{", b"[", b"<"):
        container = "非音频(" + head[:1].decode("latin1") + ")"
    kb = int(total * 8 / 1000 / dur) if total else 0
    note = ""
    if total == 181521:
        st2, full, _, _, _ = req(url, {"Referer": "https://www.kuwo.cn/"}, timeout=40)
        note = "  ← 酷我占位文件" if hashlib.md5(full).hexdigest() == PLACEHOLDER else "  181521B(非占位)"
    print(f"{label}\n    最终URL: {final[:110]}")
    print(f"    status={st} {ms}ms total={total}B {container} kbps={kb}{note}")
    return total, container


print("=" * 72)
print("A. 星海酷我跳板")
print("=" * 72)
for q in ["320kmp3", "flac"]:
    u = (f"https://yy.zddyr.top/lx/api/?source=kw&name=" + urllib.parse.quote("晴天 周杰伦")
         + f"&id={KW_RID}&quality={q}")
    st, body, ms, _, _ = req(u, {"Referer": "https://www.kuwo.cn/"}, timeout=25)
    try:
        j = json.loads(body.decode("utf-8", "replace"))
        jump = j.get("url")
    except Exception:  # noqa: BLE001
        jump = None
    print(f"\n[{q}] 星海接口 {st} {ms}ms → {jump}")
    if jump:
        facts(jump, f"    {q} 跳板音频")

print()
print("=" * 72)
print("B/C. ikun（c.wwwweb.top）")
print("=" * 72)
for source, mid, qual, dur in [("kw", KW_RID, "320k", 344), ("kw", KW_RID, "flac", 344),
                               ("tx", QQ_MID, "320k", 269), ("tx", QQ_MID, "flac", 269)]:
    st, b, ms, _, _ = req("https://c.wwwweb.top/music/url",
                          {"Content-Type": "application/json", "Accept": "application/json"},
                          timeout=30, method="POST",
                          body={"source": source, "musicId": mid, "quality": qual})
    txt = b.decode("utf-8", "replace")
    try:
        j = json.loads(txt)
        url = j.get("url")
    except Exception:  # noqa: BLE001
        j, url = {}, None
    print(f"\n[{source} {mid} {qual}] {st} {ms}ms code={j.get('code')} msg={str(j.get('message'))[:60]}")
    print(f"    url={str(url)[:110]}")
    if url:
        facts(url, f"    {qual} 音频", dur=dur)
    time.sleep(1.5)
