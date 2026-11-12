# -*- coding: utf-8 -*-
"""探活：酷狗指纹识曲同族端点（免 key、签名同 salt），同一份 8k 单声道 PCM 逐一实测"""
import hashlib, json, time, urllib.parse, urllib.request

SALT = "LnT6xpN3khm36zse0QzvmgTZ3waWdRSA"
UA = "KuGou/11490 (Android)"
PCM = r"C:\Users\17948\DoubaoWork\chats\2026-10-22\new-chat-1\_tmp_build\pcm2184_10s.pcm"

CANDS = [
    ("v1_mulit(现用)", "https://gateway.kugou.com/fingerprint.service/v1/music_trackid_mulit", "3116", "11070", "1"),
    ("v1_single",      "https://gateway.kugou.com/fingerprint.service/v1/music_trackid",        "3116", "11070", "0"),
    ("v2_mulit",       "https://gateway.kugou.com/fingerprint.service/v2/music_trackid_mulit",   "3116", "11070", "1"),
    ("v1_mulit·cver1005", "https://gateway.kugou.com/fingerprint.service/v1/music_trackid_mulit","1005", "1005",  "1"),
    ("v3_mulit",       "https://gateway.kugou.com/fingerprint.service/v3/music_trackid_mulit",   "3116", "11070", "1"),
    ("v1_trackid_alt", "https://gateway.kugou.com/fingerprint.service/v1/music_trackid_mulit",   "1005", "11430", "1"),
]

def md5hex(s):
    return hashlib.md5(s.encode()).hexdigest()

def build(ep, appid, cver, multi, body):
    now = int(time.time() * 1000)
    params = {
        "fpid": str(now), "area_code": "1", "include_unpublish": "1", "useid": "0",
        "multi_result": multi, "dfid": "-", "mid": md5hex(str(now)), "uuid": "-",
        "appid": appid, "clientver": cver, "clienttime": str(now // 1000),
    }
    joined = "".join(f"{k}={params[k]}" for k in sorted(params))
    md = hashlib.md5()
    md.update(SALT.encode()); md.update(joined.encode()); md.update(body); md.update(SALT.encode())
    q = "&".join(f"{k}={urllib.parse.quote(str(params[k]))}" for k in sorted(params)) + "&signature=" + md.hexdigest()
    return ep + "?" + q, params["mid"]

body = open(PCM, "rb").read()
print(f"样本 {len(body)} B = {len(body)//16000} 秒 @8k mono 16bit\n")

for name, ep, appid, cver, multi in CANDS:
    url, mid = build(ep, appid, cver, multi, body)
    req = urllib.request.Request(url, data=body, method="POST",
                                 headers={"User-Agent": UA, "mid": mid, "dfid": "-",
                                          "Content-Type": "application/octet-stream"})
    t0 = time.time()
    try:
        with urllib.request.urlopen(req, timeout=25) as r:
            status = r.status
            txt = r.read().decode("utf-8", "replace")
    except urllib.error.HTTPError as e:
        status = e.code
        txt = e.read().decode("utf-8", "replace")[:300]
    except Exception as e:
        print(f"{name:22s} 连接失败: {type(e).__name__} {e}")
        continue
    cost = time.time() - t0
    try:
        j = json.loads(txt)
        code = j.get("error_code", j.get("code", "?"))
        data = j.get("data") or []
        n = len(data) if isinstance(data, list) else 0
        first = ""
        if n:
            d0 = data[0]
            alb = (d0.get("album") or [{}])[0].get("albumname", "") if isinstance(d0.get("album"), list) else ""
            first = f"{d0.get('songname','')} / {d0.get('singername','')} / {alb}"
        print(f"{name:22s} HTTP {status} {cost:4.1f}s error_code={code} data={n} 首条: {first}")
    except Exception:
        print(f"{name:22s} HTTP {status} {cost:4.1f}s 非 JSON: {txt[:160].replace(chr(10),' ')}")
