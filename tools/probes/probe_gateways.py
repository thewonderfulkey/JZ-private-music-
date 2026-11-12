# -*- coding: utf-8 -*-
"""探活：网易云 /api/music/audio/match（aplayer 方案里的实际接口）、AcoustID、AudD 的准入形态"""
import json, urllib.parse, urllib.request, time

UA_EXT = ("Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) "
          "Chrome/124.0.0.0 Safari/537.36")

print("=== 1) 网易 /api/music/audio/match（假 rawdata，只看接口是否活着/怎么报错） ===")
url = "https://interface.music.163.com/api/music/audio/match"
form = urllib.parse.urlencode({
    "sessionId": "441df692-afea-4a54-8aff-f5f20fd34f12",
    "algorithmCode": "shazam_v2",
    "duration": "12",
    "rawdata": "AAAA",          # 故意给无效指纹
    "times": "2",
    "decrypt": "1",
}).encode()
for label, headers in [
    ("带扩展 Origin", {"origin": "chrome-extension://pgphbbekcgpfaekhcbjamjjkegcclhhd"}),
    ("不带 Origin", {}),
]:
    req = urllib.request.Request(url, data=form, method="POST", headers={
        "user-agent": UA_EXT, "accept": "application/json",
        "content-type": "application/x-www-form-urlencoded; charset=UTF-8", **headers})
    t0 = time.time()
    try:
        with urllib.request.urlopen(req, timeout=20) as r:
            body = r.read().decode("utf-8", "replace")
            print(f"  {label}: HTTP {r.status} {time.time()-t0:.1f}s  {body[:220]}")
    except urllib.error.HTTPError as e:
        print(f"  {label}: HTTP {e.code} {time.time()-t0:.1f}s  {e.read().decode('utf-8','replace')[:220]}")
    except Exception as e:
        print(f"  {label}: 失败 {type(e).__name__} {e}")

print("\n=== 2) 网易官方歌词搜索 type=1006（之前实测是密文，复核一次） ===")
u = ("https://music.163.com/api/search/get/web?s=" + urllib.parse.quote("故事的小黄花") + "&type=1006&limit=3")
req = urllib.request.Request(u, headers={"User-Agent": "Mozilla/5.0", "Referer": "https://music.163.com/"})
d = urllib.request.urlopen(req, timeout=20).read().decode("utf-8", "replace")
print("  返回前 120 字符:", d[:120])
print("  是否密文(hex 串、无 'songs'):", "songs" not in d)

print("\n=== 3) AcoustID（Chromaprint 官方库）无 key 调用 ===")
u = "https://api.acoustid.org/v2/lookup?client=test&meta=recordings+releasegroups&duration=300&fingerprint=AQADtEmi"
try:
    d = urllib.request.urlopen(urllib.request.Request(u, headers={"User-Agent": "probe"}), timeout=20).read().decode("utf-8", "replace")
    print("  ", d[:220])
except Exception as e:
    print("  失败", type(e).__name__, e)

print("\n=== 4) AudD（ACR 商业服务，看无 key 时返回什么） ===")
try:
    req = urllib.request.Request("https://api.audd.io/", data=b"", method="POST")
    d = urllib.request.urlopen(req, timeout=20).read().decode("utf-8", "replace")
    print("  ", d[:220])
except urllib.error.HTTPError as e:
    print("  ", e.code, e.read().decode("utf-8", "replace")[:220])
except Exception as e:
    print("  失败", type(e).__name__, e)
