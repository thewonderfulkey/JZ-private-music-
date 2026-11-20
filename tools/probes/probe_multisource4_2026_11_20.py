"""为「接多条取流器」做最后的可行性判定：三条候选今晚到底稳不稳。

① 落月 v3  /music/tencent/song/link?mid=&quality=8/10   QQ 320k / flac
② ikun     POST c.wwwweb.top/music/url {source:kw}        酷我 320k / flac
③ 星海酷我  yy.zddyr.top/lx/api/?source=kw&id=&quality=   酷我 FLAC（跳板）
每首两轮，看是否稳定；并对音频做 Range 校验 + 占位文件比对。
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
PH = "43fe5f6460e49afdf0bc2340012fe7b5"

SONGS = [
    ("晴天", "0039MnYb0qxYhV", "228908", 344),
    ("七里香", "004Z8Ihr0JIu5s", "94237", 299),
    ("大鱼", "004OQ5Mt0EmEzv", "7095195", 292),
]


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


def facts(url, dur):
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
    c = "?"
    if head[:4] == b"fLaC":
        c = "flac"
    elif head[:3] == b"ID3":
        c = "mp3"
    elif head[:1] == b"\xff" and (head[1] & 0xE0) == 0xE0:
        c = "mp3"
    elif head[4:8] == b"ftyp":
        c = "m4a"
    elif head[:1] in (b"{", b"<"):
        c = "非音频"
    kb = int(total * 8 / 1000 / dur) if total else 0
    tag = ""
    if total == 181521:
        st2, full, _, _, _ = req(url, {"Referer": "https://www.kuwo.cn/"}, timeout=40)
        tag = "  ←占位文件" if hashlib.md5(full).hexdigest() == PH else "  181521B(非占位)"
    if "mgg" in final.lower():
        tag += "  ←.mgg 加密包"
    print(f"      音频 status={st} {ms}ms total={total}B {c} kbps={kb}{tag}")


print("=" * 76)
print("① 落月 v3（QQ）")
print("=" * 76)
for name, mid, rid, dur in SONGS:
    for q in (8, 10):
        ok = 0
        for attempt in (1, 2):
            u = f"https://api.vkeys.cn/music/tencent/song/link?mid={mid}&quality={q}"
            st, b, ms, _, _ = req(u, {"Accept": "application/json"}, timeout=20)
            try:
                j = json.loads(b.decode("utf-8", "replace"))
                payload = j.get("data") or {}
                url = payload.get("url") if isinstance(payload, dict) else None
                msg = j.get("message") or (payload.get("message") if isinstance(payload, dict) else "")
            except Exception:  # noqa: BLE001
                url, msg = None, b[:60]
            print(f"\n  [{name} q={q} #{attempt}] {st} {ms}ms url={'有' if url else '无'} msg={str(msg)[:40]}")
            if url:
                facts(url, dur)
                ok += 1
            time.sleep(1)
        print(f"    → {name} q={q} 命中 {ok}/2")

print()
print("=" * 76)
print("② ikun 酷我")
print("=" * 76)
for name, mid, rid, dur in SONGS:
    for qual in ("320k", "flac"):
        ok = 0
        for attempt in (1, 2):
            st, b, ms, _, _ = req("https://c.wwwweb.top/music/url",
                                  {"Content-Type": "application/json", "Accept": "application/json"},
                                  timeout=30, method="POST",
                                  body={"source": "kw", "musicId": rid, "quality": qual})
            try:
                j = json.loads(b.decode("utf-8", "replace"))
                url = j.get("url")
                msg = j.get("message")
            except Exception:  # noqa: BLE001
                url, msg = None, b[:60]
            print(f"\n  [{name} {qual} #{attempt}] {st} {ms}ms code={msg} url={'有' if url else '无'}")
            if url:
                facts(url, dur)
                ok += 1
            time.sleep(1.5)
        print(f"    → {name} {qual} 命中 {ok}/2")

print()
print("=" * 76)
print("③ 星海酷我（跳板）")
print("=" * 76)
for name, mid, rid, dur in SONGS:
    ok = 0
    for attempt in (1, 2):
        u = (f"https://yy.zddyr.top/lx/api/?source=kw&name=" + urllib.parse.quote(f"{name} 周杰伦")
             + f"&id={rid}&quality=320kmp3")
        st, b, ms, _, _ = req(u, {"Referer": "https://www.kuwo.cn/"}, timeout=25)
        try:
            j = json.loads(b.decode("utf-8", "replace"))
            jump = j.get("url")
        except Exception:  # noqa: BLE001
            jump = None
        print(f"\n  [{name} #{attempt}] 星海 {st} {ms}ms jump={'有' if jump else j.get('msg')}")
        if jump:
            facts(jump, dur)
            ok += 1
        time.sleep(1)
    print(f"    → {name} 命中 {ok}/2")
