"""2026-11-20 晚：老板反馈「周杰伦的歌都播不出来（说是只在酷我最新手机端才能播放），
QQ 接口超时兜底失败」。本脚本只读探测各条取流通道的现状，定位是哪一跳断了。

探测项：
  A. Kuwo anti.s（酷我官方 rid 直查）—— 我们播放链的酷我兜底
  B. 妖狐酷我（搜索式）—— 酷我主通道
  C. cyapi QQ —— QQ 唯一后端
  D. 酷我 openapi playUrl（另一条官方路，看会不会回那句人话）
"""
import json
import ssl
import time
import urllib.parse
import urllib.request

UA_I = ("Mozilla/5.0 (iPhone; CPU iPhone OS 16_6 like Mac OS X) "
        "AppleWebKit/605.1.15 (KHTML, like Gecko) Version/16.6 Mobile/15E148 Safari/604.1")
UA_W = ("Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 "
        "(KHTML, like Gecko) Chrome/122.0 Safari/537.36")
CTX = ssl.create_default_context()
CTX.check_hostname = False
CTX.verify_mode = ssl.CERT_NONE

YAOHU = "https://api.yaohud.cn/api/music/kuwo?key=nvgKtvzw7CFSNFrDhA6&action=search&msg=%s&n=1"
CYAPI = ("https://cyapi.top/API/qq_music.php?apikey="
         "1ffdf5733f5d538760e63d7e46ba17438d9f7b9dfc18c51be1109386fd74c3a1&type=json&mid=%s")

SONGS = ["晴天", "七里香", "夜曲", "稻香", "告白气球", "发如雪"]


def get(url, headers=None, timeout=15):
    h = {"User-Agent": UA_I}
    h.update(headers or {})
    req = urllib.request.Request(url, headers=h)
    t0 = time.time()
    try:
        with urllib.request.urlopen(req, timeout=timeout, context=CTX) as r:
            body = r.read()
            return r.status, body, int((time.time() - t0) * 1000), dict(r.headers)
    except Exception as e:  # noqa: BLE001
        return None, str(e).encode(), int((time.time() - t0) * 1000), {}


def head_probe(url, timeout=15):
    """只取前 2KB，看是不是真音频（Content-Type + 首字节）。"""
    h = {"User-Agent": UA_I, "Range": "bytes=0-2047", "Referer": "https://www.kuwo.cn/"}
    req = urllib.request.Request(url, headers=h)
    t0 = time.time()
    try:
        with urllib.request.urlopen(req, timeout=timeout, context=CTX) as r:
            body = r.read(2048)
            return (r.status, r.headers.get("Content-Type"), r.headers.get("Content-Range")
                    or r.headers.get("Content-Length"), body[:16],
                    int((time.time() - t0) * 1000))
    except Exception as e:  # noqa: BLE001
        return ("ERR", str(e), None, b"", int((time.time() - t0) * 1000))


def kuwo_search(kw, rn=3):
    u = ("https://search.kuwo.cn/r.s?all=%s&ft=music&rn=%d&pn=1&rformat=json&encoding=utf8"
         "&vipver=MUSIC_8.7.8.0_WX" % (urllib.parse.quote(kw), rn))
    st, body, ms, _ = get(u, {"Referer": "https://www.kuwo.cn/"})
    text = body.decode("utf-8", "replace")
    out = []
    for chunk in text.split("\n"):
        chunk = chunk.strip()
        if not chunk:
            continue
        try:
            rec = json.loads(chunk.replace("'", '"'))
        except Exception:  # noqa: BLE001
            continue
        for it in rec.get("abslist", []):
            out.append((it.get("DC_TARGETID") or it.get("MUSICRID") or it.get("id"),
                        it.get("SONGNAME"), it.get("ARTIST")))
    return st, ms, out


print("=" * 70)
print("A. Kuwo anti.s 官方 rid 直查")
print("=" * 70)
for kw in SONGS:
    st, ms, recs = kuwo_search(kw, 2)
    print(f"\n[{kw}] 搜索 {st} {ms}ms → {recs[:2]}")
    for rid, name, artist in recs[:1]:
        rid_num = str(rid or "").replace("MUSIC_", "")
        u = ("https://antiserver.kuwo.cn/anti.s?type=convert_url&format=mp3"
             f"&response=url&rid=MUSIC_{rid_num}")
        s, body, t, _ = get(u, {"Referer": "https://www.kuwo.cn/"}, timeout=12)
        txt = body.decode("utf-8", "replace").strip()
        print(f"   anti.s rid={rid_num} {s} {t}ms → {txt[:160]!r}")
        if txt.lower().startswith("http"):
            print("     音频:", head_probe(txt))

print()
print("=" * 70)
print("B. 妖狐酷我（搜索式）")
print("=" * 70)
for kw in SONGS:
    key = kw + "周杰伦"
    u = YAOHU % urllib.parse.quote(key)
    s, body, t, _ = get(u, {"X-Client-Software": "lx"}, timeout=20)
    txt = body.decode("utf-8", "replace")
    try:
        j = json.loads(txt)
    except Exception:  # noqa: BLE001
        print(f"\n[{key}] {s} {t}ms 非 JSON: {txt[:200]!r}")
        continue
    data = j.get("data") or {}
    vm = data.get("vipmusic") or {}
    url = vm.get("url") or ""
    print(f"\n[{key}] {s} {t}ms code={j.get('code')} title={data.get('songtitle')!r}")
    print(f"   level={vm.get('level')} bitrate={vm.get('bitrate')} url={url[:110]!r}")
    if url.startswith("http"):
        print("   音频:", head_probe(url))

print()
print("=" * 70)
print("C. cyapi QQ（mid 直查）")
print("=" * 70)
# 周杰伦几个常见 mid（晴天 / 七里香 / 告白气球 / 稻香）
MIDS = {
    "晴天": "0039MnYb0qxYhV",
    "七里香": "004Z8Ihr0JIu5s",
    "告白气球": "003OUlho2HcRHC",
    "稻香": "003aAYrm3GE0Ac",
}
for name, mid in MIDS.items():
    s, body, t, _ = get(CYAPI % mid, {"Referer": "https://y.qq.com/"}, timeout=20)
    txt = body.decode("utf-8", "replace")
    print(f"\n[{name} {mid}] {s} {t}ms → {txt[:200]!r}")

print()
print("=" * 70)
print("D. 酷我 openapi playUrl（看会不会直接回那句人话）")
print("=" * 70)
for kw in SONGS[:3]:
    st, ms, recs = kuwo_search(kw, 1)
    if not recs:
        continue
    rid = str(recs[0][0]).replace("MUSIC_", "")
    for tpl in (
        "https://www.kuwo.cn/api/v1/www/music/playUrl?mid={}&type=music&httpsStatus=1",
        "https://www.kuwo.cn/openapi/v1/www/music/playUrl?mid={}&type=music&httpsStatus=1",
    ):
        u = tpl.format(rid)
        s, body, t, _ = get(u, {"Referer": "https://www.kuwo.cn/",
                                "Accept": "application/json"}, timeout=12)
        print(f"\n[{kw} rid={rid}] {u.split('/')[2]} {s} {t}ms → "
              f"{body.decode('utf-8', 'replace')[:220]!r}")
