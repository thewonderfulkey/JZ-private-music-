# -*- coding: utf-8 -*-
"""三项探活：
A. 同一接口不同时长/不同片段 → 命中是否变化（验证"分段多采样"是否真能救）
B. 该接口能否直接吃 mp3 片段（能则端上可省流量/更接近真实听歌场景）
C. 网易歌词搜索（type=1006）作为免费"歌词反查"通道是否可用
"""
import hashlib, json, time, urllib.parse, urllib.request, os

SALT = "LnT6xpN3khm36zse0QzvmgTZ3waWdRSA"
UA = "KuGou/11490 (Android)"
EP = "https://gateway.kugou.com/fingerprint.service/v1/music_trackid_mulit"
BASE = r"C:\Users\17948\DoubaoWork\chats\2026-10-22\new-chat-1\_tmp_build"
PCM20 = os.path.join(BASE, "pcm2184_20s.pcm")
MP3 = r"C:\Users\17948\DoubaoWork\chats\2026-10-22\new-chat-1\sunny_day_test\results\kuwo_51685512_320k.mp3"

def md5hex(s): return hashlib.md5(s.encode()).hexdigest()

def fp(body, ctype="application/octet-stream"):
    now = int(time.time() * 1000)
    params = {"fpid": str(now), "area_code": "1", "include_unpublish": "1", "useid": "0",
              "multi_result": "1", "dfid": "-", "mid": md5hex(str(now)), "uuid": "-",
              "appid": "3116", "clientver": "11070", "clienttime": str(now // 1000)}
    joined = "".join(f"{k}={params[k]}" for k in sorted(params))
    md = hashlib.md5(); md.update(SALT.encode()); md.update(joined.encode()); md.update(body); md.update(SALT.encode())
    q = "&".join(f"{k}={urllib.parse.quote(str(params[k]))}" for k in sorted(params)) + "&signature=" + md.hexdigest()
    req = urllib.request.Request(EP + "?" + q, data=body, method="POST",
                                 headers={"User-Agent": UA, "mid": params["mid"], "dfid": "-", "Content-Type": ctype})
    try:
        with urllib.request.urlopen(req, timeout=25) as r:
            j = json.loads(r.read().decode("utf-8", "replace"))
    except Exception as e:
        return f"请求失败 {type(e).__name__}"
    if j.get("error_code") != 0:
        return f"error_code={j.get('error_code')}"
    data = j.get("data") or []
    return " / ".join(f"{d.get('songname','')}-{d.get('singername','')}" for d in data[:3]) or "空"

pcm = open(PCM20, "rb").read()
print("=== A. 同一接口、不同时长 ===")
for sec in (2, 3, 5, 8, 10, 15, 20):
    n = sec * 16000
    if n > len(pcm): break
    print(f"{sec:2d}s  {fp(pcm[:n])}")

print("\n=== A2. 20 秒内的三段 6 秒（模拟录在不同位置） ===")
seg = 6 * 16000
for i, start in enumerate((0, 7, 14)):
    chunk = pcm[start * 16000: start * 16000 + seg]
    if len(chunk) < seg: chunk = pcm[-seg:]
    print(f"第{i+1}段 起点 {start}s  {fp(chunk)}")

print("\n=== B. 直接送 mp3 片段（前 200KB） ===")
mp3 = open(MP3, "rb").read(200_000)
print(f"mp3 片段 {len(mp3)} B → {fp(mp3, 'audio/mpeg')}")

print("\n=== C. 网易歌词搜索 type=1006（免费，无需登录） ===")
for q in ("故事的小黄花", "从前从前有个人爱你很久"):
    url = ("https://music.163.com/api/search/get/web?s=" + urllib.parse.quote(q) +
           "&type=1006&offset=0&total=true&limit=5")
    req = urllib.request.Request(url, headers={"User-Agent": "Mozilla/5.0", "Referer": "https://music.163.com/"})
    try:
        with urllib.request.urlopen(req, timeout=20) as r:
            j = json.loads(r.read().decode("utf-8", "replace"))
        songs = (j.get("result") or {}).get("songs") or []
        print(f"「{q}」 code={j.get('code')} 命中 {len(songs)} 条：" +
              " / ".join(f"{s.get('name')}-{(s.get('artists') or [{}])[0].get('name','')}" for s in songs[:3]))
    except Exception as e:
        print(f"「{q}」 失败 {type(e).__name__} {e}")
