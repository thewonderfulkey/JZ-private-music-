"""今晚 23:5x 复测：星澜脚本里「能用的那几条」现在还活着吗，能不能救周杰伦。

只打脚本里实测活着的、且与我们有关系的端点：
  ① 星海 酷我   https://yy.zddyr.top/lx/api/?source=kw&name=&songid=&quality=
  ② 星海 QQ     https://yy.zddyr.top/lx/api/?source=tx&quality=&songmid=
  ③ 落月 QQ     https://api.vkeys.cn/v2/music/tencent/geturl?mid=&quality=8
  ④ 云记 酷狗   POST https://musicserver.haitangw.cc/v1/music/resolve-url
  ⑤ ikun 酷我/网易 https://c.wwwweb.top/music/url
每个 URL 都做 Range 探测（跟 302），报真实字节/容器/码率，并和「占位文件 md5=43fe5f64…」比对。
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

JAY_QQ_MID = "0039MnYb0qxYhV"     # 晴天
JAY_KW_RID = "228908"             # 晴天（酷我热歌榜给的 rid）
DUR = 344


def req(url, headers=None, timeout=20, method="GET", body=None, read=0, follow=True):
    h = {"User-Agent": UA}
    h.update(headers or {})
    data = None
    if body is not None:
        data = json.dumps(body).encode() if not isinstance(body, (bytes, str)) else \
            (body.encode() if isinstance(body, str) else body)
    r = urllib.request.Request(url, headers=h, data=data, method=method)
    t0 = time.time()
    try:
        with urllib.request.urlopen(r, timeout=timeout, context=CTX) as resp:
            b = resp.read(read) if read else resp.read()
            return resp.status, b, int((time.time() - t0) * 1000), dict(resp.headers), resp.geturl()
    except urllib.error.HTTPError as e:
        return e.code, e.read()[:400], int((time.time() - t0) * 1000), dict(e.headers or {}), url
    except Exception as e:  # noqa: BLE001
        return None, str(e).encode(), int((time.time() - t0) * 1000), {}, url


def judge(url, label, dur=DUR):
    if not url or not str(url).startswith("http"):
        return f"{label}: 没拿到 URL"
    h = {"Range": "bytes=0-2047", "Referer": "https://www.kuwo.cn/"}
    st, head, ms, hd, final = req(url, h, timeout=25, read=2048)
    total = 0
    cr = hd.get("Content-Range") or hd.get("Content-Length") or ""
    if "/" in cr:
        try:
            total = int(cr.split("/")[-1])
        except Exception:  # noqa: BLE001
            pass
    elif str(cr).isdigit():
        total = int(cr)
    kb = int(total * 8 / 1000 / dur) if total else 0
    container = "?"
    if head[:4] == b"fLaC":
        container = "flac"
    elif head[:3] == b"ID3":
        container = "mp3(ID3)"
    elif head[0] == 0xFF and (head[1] & 0xE0) == 0xE0:
        container = "mp3"
    elif head[4:8] == b"ftyp":
        container = "m4a"
    elif head[:2] == b"{\"" or head[:1] in (b"{", b"["):
        container = "JSON!"
    is_ph = ""
    if total == 181521:
        # 取全量比对 md5
        st2, full, ms2, _, _ = req(url, {"Referer": "https://www.kuwo.cn/"}, timeout=40)
        if hashlib.md5(full).hexdigest() == PLACEHOLDER:
            is_ph = "  ← 酷我占位文件！"
        else:
            is_ph = f"  181521B 但不是占位(md5 {hashlib.md5(full).hexdigest()[:10]})"
    print(f"{label}: status={st} {ms}ms total={total}B {container} kbps={kb}{is_ph}")
    return total


print("=" * 74)
print("① 星海 酷我（yy.zddyr.top source=kw）——能不能替掉那个占位文件")
print("=" * 74)
for q in ["320kmp3", "flac", "128kmp3"]:
    u = ("https://yy.zddyr.top/lx/api/?source=kw&name="
         + urllib.parse.quote("晴天 周杰伦") + "&songid=" + JAY_KW_RID + "&quality=" + q)
    st, body, ms, hd, _ = req(u, {"Referer": "https://www.kuwo.cn/"}, timeout=25)
    txt = body.decode("utf-8", "replace")
    print(f"\n[{q}] {st} {ms}ms → {txt[:180]}")
    try:
        j = json.loads(txt)
        url = j.get("url") or (j.get("data") or {}).get("url") if isinstance(j, dict) else None
    except Exception:  # noqa: BLE001
        url = None
    if url:
        judge(url, f"    {q} 音频")

print()
print("=" * 74)
print("② 星海 QQ（source=tx）")
print("=" * 74)
for q in ["320kmp3", "flac"]:
    u = ("https://yy.zddyr.top/lx/api/?source=tx&quality=" + q
         + "&songmid=" + JAY_QQ_MID + "&albumId=000MkMni19ClKG&mainHash=&hash=")
    st, body, ms, hd, _ = req(u, {"Referer": "https://y.qq.com/"}, timeout=25)
    txt = body.decode("utf-8", "replace")
    print(f"\n[{q}] {st} {ms}ms → {txt[:180]}")
    try:
        j = json.loads(txt)
        url = j.get("url") if isinstance(j, dict) else None
    except Exception:  # noqa: BLE001
        url = None
    if url:
        judge(url, f"    {q} 音频", dur=269)

print()
print("=" * 74)
print("③ 落月 QQ（api.vkeys.cn）")
print("=" * 74)
for q in [8, 10]:
    u = f"https://api.vkeys.cn/v2/music/tencent/geturl?mid={JAY_QQ_MID}&quality={q}"
    st, body, ms, hd, _ = req(u, {"Accept": "application/json"}, timeout=15)
    print(f"\n[v2 quality={q}] {st} {ms}ms → {body.decode('utf-8','replace')[:170]}")
u = f"https://api.vkeys.cn/music/tencent/song/link?mid={JAY_QQ_MID}&quality=8"
st, body, ms, hd, _ = req(u, {"Accept": "application/json"}, timeout=15)
print(f"\n[v3 quality=8] {st} {ms}ms → {body.decode('utf-8','replace')[:200]}")

print()
print("=" * 74)
print("④ 云记 酷狗（haitangw resolve-url）")
print("=" * 74)
st, body, ms, hd, _ = req("https://musicserver.haitangw.cc/v1/music/resolve-url",
                          {"Content-Type": "application/json", "Accept": "application/json"},
                          timeout=20, method="POST",
                          body={"source": "kg", "rid": "1B56126A5CBC", "level": "exhigh"})
print(f"{st} {ms}ms → {body.decode('utf-8','replace')[:220]}")

print()
print("=" * 74)
print("⑤ ikun（c.wwwweb.top）")
print("=" * 74)
for body in ({"url": f"https://www.kuwo.cn/play_detail/{JAY_KW_RID}"},
             {"url": f"https://music.163.com/song?id=186016"}):
    st, b, ms, hd, _ = req("https://c.wwwweb.top/music/url",
                           {"Content-Type": "application/json", "Accept": "application/json"},
                           timeout=20, method="POST", body=body)
    print(f"\n{body['url']} → {st} {ms}ms {b.decode('utf-8','replace')[:200]}")
