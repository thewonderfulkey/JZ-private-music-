"""2026-11-20 晚 · 第二轮：周杰伦原曲在酷我各条通道的真实取流结果。

上一轮发现：`search.kuwo.cn/r.s` 按歌名搜出来的头部条目已经**不是原唱**
（《晴天》首位是「女声治愈版」，七里香首位是《搁浅》）。所以这一轮先用「歌名+周杰伦」
把原唱条目捞准，再逐条打：
  · anti.s convert_url（我们 KuwoOfficialAdapter 用的那条）
  · anti.s convert_url3（另一形态）
  · www.kuwo.cn/api/v1/www/music/playUrl（web 口）
并对每条返回的地址做 Range 探测（Content-Length / 首字节 / Content-Type），
判断是「整首」「181KB 残片」还是「一句人话」。
"""
import json
import ssl
import time
import urllib.parse
import urllib.request

UA_I = ("Mozilla/5.0 (iPhone; CPU iPhone OS 16_6 like Mac OS X) "
        "AppleWebKit/605.1.15 (KHTML, like Gecko) Version/16.6 Mobile/15E148 Safari/604.1")
CTX = ssl.create_default_context()
CTX.check_hostname = False
CTX.verify_mode = ssl.CERT_NONE

SONGS = ["晴天", "七里香", "夜曲", "稻香", "告白气球", "发如雪", "青花瓷", "简单爱"]


def get(url, headers=None, timeout=15, read=4096):
    h = {"User-Agent": UA_I}
    h.update(headers or {})
    req = urllib.request.Request(url, headers=h)
    t0 = time.time()
    try:
        with urllib.request.urlopen(req, timeout=timeout, context=CTX) as r:
            body = r.read(read)
            return (r.status, body, int((time.time() - t0) * 1000),
                    r.headers.get("Content-Type"), r.headers.get("Content-Range")
                    or r.headers.get("Content-Length"))
    except Exception as e:  # noqa: BLE001
        return None, str(e).encode(), int((time.time() - t0) * 1000), None, None


def kuwo_search(kw, rn=8):
    u = ("https://search.kuwo.cn/r.s?all=%s&ft=music&rn=%d&pn=1&rformat=json&encoding=utf8"
         "&vipver=MUSIC_8.7.8.0_WX" % (urllib.parse.quote(kw), rn))
    st, body, ms, _, _ = get(u, {"Referer": "https://www.kuwo.cn/"}, read=200000)
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
            out.append({
                "rid": str(it.get("DC_TARGETID") or it.get("MUSICRID") or "").replace("MUSIC_", ""),
                "name": it.get("SONGNAME"),
                "artist": it.get("ARTIST"),
                "album": it.get("ALBUM"),
                "dur": it.get("DURATION"),
            })
    return out


def probe_audio(url):
    """Range 取 0-2047，返回 (status, ctype, total, magic)"""
    h = {"Referer": "https://www.kuwo.cn/", "Range": "bytes=0-2047"}
    st, body, ms, ctype, crange = get(url, h, timeout=20, read=2048)
    total = ""
    if crange and "/" in str(crange):
        total = str(crange).split("/")[-1]
    elif crange:
        total = str(crange)
    return st, ctype, total, body[:8], ms


print("=" * 74)
print("周杰伦原唱条目 → 三条官方通道")
print("=" * 74)
for kw in SONGS:
    recs = kuwo_search(kw + " 周杰伦", 10)
    exact = [r for r in recs
             if r["name"] and kw in r["name"].replace("&nbsp;", " ")
             and "周杰伦" in (r["artist"] or "")
             and "Live" not in (r["name"] or "")
             and "伴奏" not in (r["name"] or "")
             and "翻" not in (r["name"] or "")]
    print(f"\n[{kw}] 候选 {len(recs)} 条，原唱像的 {len(exact)} 条")
    for r in exact[:2]:
        rid = r["rid"]
        print(f"  · rid={rid} 《{r['name']}》/{r['artist']} 专辑={r['album']} 时长={r['dur']}s")
        # ① anti.s convert_url（我们用的）
        u1 = ("https://antiserver.kuwo.cn/anti.s?type=convert_url&format=mp3"
              f"&response=url&rid=MUSIC_{rid}")
        st, body, ms, _, _ = get(u1, {"Referer": "https://www.kuwo.cn/"}, timeout=15)
        txt = body.decode("utf-8", "replace").strip()
        print(f"     ① anti.s convert_url {st} {ms}ms → {txt[:120]!r}")
        if txt.lower().startswith("http"):
            print("        ", probe_audio(txt))
        # ② anti.s convert_url3
        u2 = ("https://antiserver.kuwo.cn/anti.s?type=convert_url3&format=mp3"
              f"&response=url&br=320kmp3&rid={rid}")
        st, body, ms, _, _ = get(u2, {"Referer": "https://www.kuwo.cn/"}, timeout=15)
        txt2 = body.decode("utf-8", "replace").strip()
        print(f"     ② anti.s convert_url3 {st} {ms}ms → {txt2[:160]!r}")
        # ③ web playUrl
        u3 = (f"https://www.kuwo.cn/api/v1/www/music/playUrl?mid={rid}"
              "&type=music&httpsStatus=1")
        st, body, ms, _, _ = get(u3, {"Referer": "https://www.kuwo.cn/",
                                      "Accept": "application/json"}, timeout=15)
        txt3 = body.decode("utf-8", "replace").strip()
        print(f"     ③ web playUrl {st} {ms}ms → {txt3[:200]!r}")
        if '"url"' in txt3:
            try:
                u = json.loads(txt3)["data"]["url"]
                print("        ", probe_audio(u))
            except Exception:  # noqa: BLE001
                pass
