"""第四轮：三件事
① 那个 181,521 字节的「酷我残片」到底是什么：不同 rid 是不是同一个文件、多长、是不是人声提示
② 妖狐酷我 403「频繁请求被屏蔽」是不是暂时的（冷却后再问一次）
③ cyapi 再来一次（看是不是也会抖）
"""
import hashlib
import json
import ssl
import struct
import time
import urllib.parse
import urllib.request

UA_I = ("Mozilla/5.0 (iPhone; CPU iPhone OS 16_6 like Mac OS X) "
        "AppleWebKit/605.1.15 (KHTML, like Gecko) Version/16.6 Mobile/15E148 Safari/604.1")
CTX = ssl.create_default_context()
CTX.check_hostname = False
CTX.verify_mode = ssl.CERT_NONE


def get(url, headers=None, timeout=25):
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


def mp3_duration(data: bytes) -> float:
    """按 MPEG 帧头累计帧数 → 秒（128kbps / 44.1k 的常见 CBR 够用）。"""
    i, frames = 0, 0
    if data[:3] == b"ID3":
        size = ((data[6] & 0x7F) << 21) | ((data[7] & 0x7F) << 14) | \
               ((data[8] & 0x7F) << 7) | (data[9] & 0x7F)
        i = 10 + size
    rates = {0: 44100, 1: 48000, 2: 32000}
    bitrates = {1: 32, 2: 40, 3: 48, 4: 56, 5: 64, 6: 80, 7: 96, 8: 112,
                9: 128, 10: 160, 11: 192, 12: 224, 13: 256, 14: 320}
    total = 0.0
    while i + 4 <= len(data) and frames < 200000:
        if data[i] != 0xFF or (data[i + 1] & 0xE0) != 0xE0:
            i += 1
            continue
        ver = (data[i + 1] >> 3) & 0x03
        layer = (data[i + 1] >> 1) & 0x03
        br_idx = (data[i + 2] >> 4) & 0x0F
        sr_idx = (data[i + 2] >> 2) & 0x03
        pad = (data[i + 2] >> 1) & 0x01
        if ver != 3 or layer != 1 or br_idx in (0, 15) or sr_idx == 3:
            i += 1
            continue
        sr = rates[sr_idx]
        br = bitrates.get(br_idx, 128)
        frame_len = int(144000 * br / sr) + pad
        if frame_len <= 4:
            i += 1
            continue
        total += 1152.0 / sr
        frames += 1
        i += frame_len
    return total, frames


print("=" * 74)
print("① 残片取证：同一个文件？多长？是不是同一段东西？")
print("=" * 74)
CASES = [("晴天", "228908"), ("青花瓷", "324244"), ("稻香", "384351210")]
blobs = {}
for name, rid in CASES:
    u = ("https://antiserver.kuwo.cn/anti.s?type=convert_url&format=mp3"
         f"&response=url&rid=MUSIC_{rid}")
    st, body, ms, _ = get(u, {"Referer": "https://www.kuwo.cn/"}, timeout=20)
    txt = body.decode("utf-8", "replace").strip()
    print(f"\n[{name} rid={rid}] anti.s {st} {ms}ms → {txt[:90]}")
    if not txt.startswith("http"):
        continue
    st2, audio, ms2, hdr = get(txt, {"Referer": "https://www.kuwo.cn/"}, timeout=40)
    print(f"   整条下载 {st2} {ms2}ms {len(audio)}B "
          f"md5={hashlib.md5(audio).hexdigest()} ctype={hdr.get('Content-Type')}")
    dur, frames = mp3_duration(audio)
    print(f"   MP3 帧 {frames} 个 → 约 {dur:.1f}s")
    blobs[name] = audio

if len(blobs) >= 2:
    keys = list(blobs)
    same = len({hashlib.md5(b).hexdigest() for b in blobs.values()}) == 1
    print(f"\n不同歌的残片字节是否完全相同：{same}")

# 有没有 ID3/歌词/文案藏在这段音频里
for name, b in blobs.items():
    head = b[:200]
    printable = "".join(chr(c) if 32 <= c < 127 else "." for c in head)
    print(f"\n[{name}] 前 200 字节可打印：{printable[:160]}")

print()
print("=" * 74)
print("② 妖狐酷我：冷却后再问一次（看 403 是不是暂时限流）")
print("=" * 74)
for key in ["晴天周杰伦", "七里香周杰伦", "晴天"]:
    u = ("https://api.yaohud.cn/api/music/kuwo?key=nvgKtvzw7CFSNFrDhA6&action=search&msg=%s&n=1"
         % urllib.parse.quote(key))
    st, body, ms, _ = get(u, {"X-Client-Software": "lx"}, timeout=25)
    txt = body.decode("utf-8", "replace")
    try:
        j = json.loads(txt)
        data = j.get("data") or {}
        vm = data.get("vipmusic") or {}
        print(f"[{key}] {st} {ms}ms code={j.get('code')} msg={j.get('msg')} "
              f"title={data.get('songtitle')!r} level={vm.get('level')} url={str(vm.get('url'))[:70]}")
    except Exception:  # noqa: BLE001
        print(f"[{key}] {st} {ms}ms 非 JSON: {txt[:150]!r}")
    time.sleep(3)

print()
print("=" * 74)
print("③ cyapi QQ 连问两次")
print("=" * 74)
CYAPI = ("https://cyapi.top/API/qq_music.php?apikey="
         "1ffdf5733f5d538760e63d7e46ba17438d9f7b9dfc18c51be1109386fd74c3a1&type=json&mid=%s")
for name, mid in [("晴天", "0039MnYb0qxYhV"), ("夜曲", "0039MnYb0qxYhV")]:
    st, body, ms, _ = get(CYAPI % mid, {"Referer": "https://y.qq.com/"}, timeout=30)
    try:
        j = json.loads(body.decode("utf-8", "replace"))
        print(f"[{name}] {st} {ms}ms name={j.get('name')} url存在={bool(j.get('url'))}")
    except Exception:  # noqa: BLE001
        print(f"[{name}] {st} {ms}ms 非 JSON/超时: {body[:120]!r}")
    time.sleep(2)
