# -*- coding: utf-8 -*-
"""补测：
C. 网易歌词搜索 type=1006（免费、无需登录）到底能不能用
D. 同一首 8k PCM 加噪后，3 秒 vs 10 秒 的命中差异（判断"分段多采样/延长录音"是否真有用）
"""
import hashlib, json, time, urllib.parse, urllib.request, random, struct, math

SALT = "LnT6xpN3khm36zse0QzvmgTZ3waWdRSA"
UA = "KuGou/11490 (Android)"
EP = "https://gateway.kugou.com/fingerprint.service/v1/music_trackid_mulit"
PCM = r"C:\Users\17948\DoubaoWork\chats\2026-10-22\new-chat-1\_tmp_build\pcm2184_20s.pcm"

def md5hex(s): return hashlib.md5(s.encode()).hexdigest()

def fp(body):
    now = int(time.time() * 1000)
    p = {"fpid": str(now), "area_code": "1", "include_unpublish": "1", "useid": "0",
         "multi_result": "1", "dfid": "-", "mid": md5hex(str(now)), "uuid": "-",
         "appid": "3116", "clientver": "11070", "clienttime": str(now // 1000)}
    joined = "".join(f"{k}={p[k]}" for k in sorted(p))
    md = hashlib.md5(); md.update(SALT.encode()); md.update(joined.encode()); md.update(body); md.update(SALT.encode())
    q = "&".join(f"{k}={urllib.parse.quote(str(p[k]))}" for k in sorted(p)) + "&signature=" + md.hexdigest()
    req = urllib.request.Request(EP + "?" + q, data=body, method="POST",
                                 headers={"User-Agent": UA, "mid": p["mid"], "dfid": "-",
                                          "Content-Type": "application/octet-stream"})
    try:
        with urllib.request.urlopen(req, timeout=25) as r:
            j = json.loads(r.read().decode("utf-8", "replace"))
    except Exception as e:
        return f"失败:{type(e).__name__}"
    if j.get("error_code") != 0:
        return f"error_code={j.get('error_code')}"
    d = j.get("data") or []
    return " / ".join(f"{x.get('songname','')}-{x.get('singername','')}" for x in d[:2]) or "空"

# ---- D. 加噪 ----
raw = open(PCM, "rb").read()
samples = struct.unpack("<%dh" % (len(raw) // 2), raw)
rms = math.sqrt(sum(s * s for s in samples) / len(samples))
random.seed(7)

def noisy(snr_db, n_samples):
    amp = rms / (10 ** (snr_db / 20.0))
    vals = [max(-32768, min(32767, int(s + random.gauss(0, amp)))) for s in samples[:n_samples]]
    return struct.pack("<%dh" % len(vals), *vals)

print("=== D. 加噪后 3s / 6s / 10s 命中对比（信噪比越低越接近嘈杂环境） ===")
for snr in (20, 10, 5, 0, -5):
    line = f"SNR {snr:>3d}dB  "
    for sec in (3, 6, 10):
        line += f"[{sec}s] {fp(noisy(snr, sec * 16000))[:46]:<46s}"
    print(line)

print("\n=== C. 网易歌词搜索 type=1006 ===")
for q in ("故事的小黄花", "从前从前有个人爱你很久"):
    url = ("https://music.163.com/api/search/get/web?s=" + urllib.parse.quote(q) +
           "&type=1006&offset=0&total=true&limit=5")
    req = urllib.request.Request(url, headers={"User-Agent": "Mozilla/5.0", "Referer": "https://music.163.com/"})
    try:
        with urllib.request.urlopen(req, timeout=20) as r:
            j = json.loads(r.read().decode("utf-8", "replace"))
    except Exception as e:
        print(f"「{q}」请求失败 {type(e).__name__}"); continue
    res = j.get("result") or {}
    songs = res.get("songs") or []
    names = []
    for s in songs[:5]:
        arts = s.get("artists") or []
        a = arts[0].get("name", "") if arts and isinstance(arts[0], dict) else (arts[0] if arts else "")
        names.append(f"{s.get('name','')}-{a}")
    print(f"「{q}」 code={j.get('code')} 命中 {len(songs)} 条: " + " / ".join(names))
