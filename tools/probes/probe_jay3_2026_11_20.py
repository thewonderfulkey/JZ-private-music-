"""第三轮：完全按 App 的路径复算「一首酷我周杰伦」能不能出播放源。

1) 拉酷我热歌榜（kbangserver ksong.s id=16，rn=100）——发现页「热门音乐」的真实数据；
2) 挑出周杰伦的条目（App 拿到的 rid 就是这里给的）；
3) 对每条按播放链复算：
   · 妖狐酷我（搜索式）→ 拿到什么容器/码率 → PlaybackQualityRules.isPlayable 判不判可播
   · 酷我官方 anti.s（rid 直查）→ 返回的是整首 / 181KB 残片 / 一句人话
4) 再看跨平台补位（QQ cyapi）能不能救：QQ 搜索同名 → cyapi 取流 → Range 探测是否活。

阈值与 App 完全一致：maxKbps=320、losslessFloor 见 QualityFacts（按 800 近似）。
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
YAOHU = "https://api.yaohud.cn/api/music/kuwo?key=nvgKtvzw7CFSNFrDhA6&action=search&msg=%s&n=1"
CYAPI = ("https://cyapi.top/API/qq_music.php?apikey="
         "1ffdf5733f5d538760e63d7e46ba17438d9f7b9dfc18c51be1109386fd74c3a1&type=json&mid=%s")
LOSSLESS_FLOOR = 800


def get(url, headers=None, timeout=20, read=200000):
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


def audio_facts(url):
    """模拟 StreamVerifier.inspect + QualityFacts：拿总字节、首字节魔数、算 kbps。"""
    h = {"Referer": "https://www.kuwo.cn/", "Range": "bytes=0-2047"}
    st, body, ms, ctype, crange = get(url, h, timeout=20, read=2048)
    total = 0
    if crange and "/" in str(crange):
        try:
            total = int(str(crange).split("/")[-1])
        except Exception:  # noqa: BLE001
            total = 0
    magic = body[:8]
    container = "unknown"
    if magic[:4] == b"fLaC":
        container = "flac"
    elif magic[:3] == b"ID3":
        container = "mp3"
    elif magic[0] == 0xFF and (magic[1] & 0xE0) == 0xE0:
        container = "mp3"
    elif magic[4:8] == b"ftyp":
        container = "m4a"
    elif magic[:4] == b"RIFF":
        container = "wav"
    return st, st, total, container, ctype, ms


def fit(title, singer, dur):
    key = title
    u = YAOHU % urllib.parse.quote(key)
    st, body, ms, _, _ = get(u, {"X-Client-Software": "lx"}, timeout=20, read=4000)
    try:
        j = json.loads(body.decode("utf-8", "replace"))
    except Exception:  # noqa: BLE001
        return {"ok": False, "why": "非 JSON", "ms": ms}
    data = j.get("data") or {}
    vm = data.get("vipmusic") or {}
    url = (vm.get("url") or "").strip()
    if not url.startswith("http"):
        return {"ok": False, "why": f"无 url（code={j.get('code')} msg={j.get('msg')}）", "ms": ms}
    st2, _, total, container, ctype, ms2 = audio_facts(url)
    kbps = int(total * 8 / 1000 / dur) if total and dur else 0
    playable = not (container in ("flac", "wav", "ape") or kbps >= LOSSLESS_FLOOR)
    return {"ok": True, "title": data.get("songtitle"), "level": vm.get("level"),
            "container": container, "bytes": total, "kbps": kbps, "playable": playable,
            "ms": ms, "probe_ms": ms2, "audio_status": st2}


def kuwo_official(rid):
    u = ("https://antiserver.kuwo.cn/anti.s?type=convert_url&format=mp3"
         f"&response=url&rid=MUSIC_{rid}")
    st, body, ms, _, _ = get(u, {"Referer": "https://www.kuwo.cn/"}, timeout=20, read=4000)
    txt = body.decode("utf-8", "replace").strip()
    if not txt.lower().startswith("http"):
        return {"ok": False, "why": txt[:120], "ms": ms}
    st2, _, total, container, ctype, ms2 = audio_facts(txt)
    return {"ok": True, "url": txt[:90], "bytes": total, "container": container,
            "ctype": ctype, "ms": ms, "probe_ms": ms2, "audio_status": st2}


print("=" * 76)
print("① 酷我热歌榜（App 的「热门音乐」真实数据）里的周杰伦")
print("=" * 76)
st, body, ms, _, _ = get("https://kbangserver.kuwo.cn/ksong.s?from=pc&type=bang&id=16&pn=0&rn=100",
                         {"Referer": "https://www.kuwo.cn/"}, timeout=30)
print(f"榜单 {st} {ms}ms  {len(body)}B")
try:
    page = json.loads(body.decode("utf-8", "replace"))
except Exception as e:  # noqa: BLE001
    print("解析失败", e)
    page = {}
items = page.get("musiclist") or []
print(f"共 {len(items)} 首，pub={page.get('pub')}")
jay = [it for it in items if "周杰伦" in (it.get("artist") or "")]
print(f"周杰伦条目 {len(jay)} 首：")
for it in jay:
    print(f"  rid={it.get('id')} 《{it.get('name')}》/{it.get('artist')} 时长={it.get('duration')}")

print()
print("=" * 76)
print("② 按 App 播放链复算（妖狐 → 酷我官方 anti.s）")
print("=" * 76)
for it in jay[:4]:
    name = (it.get("name") or "").replace("&nbsp;", " ")
    dur = int(it.get("duration") or 0)
    print(f"\n《{name}》/{it.get('artist')} rid={it.get('id')} dur={dur}s")
    y = fit(name, it.get("artist"), dur)
    print(f"   妖狐: {y}")
    o = kuwo_official(it.get("id"))
    print(f"   anti.s: {o}")

print()
print("=" * 76)
print("③ QQ 兜底：cyapi 对周杰伦是不是真的能出活链")
print("=" * 76)
MIDS = {"晴天": "0039MnYb0qxYhV", "七里香": "004Z8Ihr0JIu5s",
        "告白气球": "003OUlho2HcRHC", "稻香": "003aAYrm3GE0Ac"}
for name, mid in MIDS.items():
    st, body, ms, _, _ = get(CYAPI % mid, {"Referer": "https://y.qq.com/"}, timeout=25)
    try:
        j = json.loads(body.decode("utf-8", "replace"))
    except Exception:  # noqa: BLE001
        print(f"\n[{name}] {st} {ms}ms 非 JSON: {body[:160]!r}")
        continue
    url = j.get("url") or ""
    print(f"\n[{name}] cyapi {st} {ms}ms name={j.get('name')} url={(url or '（无）')[:80]}")
    if url:
        st2, _, total, container, ctype, ms2 = audio_facts(url)
        kb = int(total * 8 / 1000 / (j.get("duration") or 1)) if total else 0
        print(f"   探测 status={st2} {ms2}ms ctype={ctype} bytes={total} container={container} kbps={kb}")
