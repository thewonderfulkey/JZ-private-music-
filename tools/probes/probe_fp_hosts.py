# -*- coding: utf-8 -*-
"""补测：是否有第二个独立指纹后端（换 host），以及 multi_result 取值能否拿到更多候选"""
import hashlib, json, time, urllib.parse, urllib.request

SALT = "LnT6xpN3khm36zse0QzvmgTZ3waWdRSA"
UA = "KuGou/11490 (Android)"
PCM = r"C:\Users\17948\DoubaoWork\chats\2026-10-22\new-chat-1\_tmp_build\pcm2184_10s.pcm"

def md5hex(s): return hashlib.md5(s.encode()).hexdigest()

def call(host, path, multi="1", appid="3116", cver="11070"):
    body = open(PCM, "rb").read()
    now = int(time.time() * 1000)
    p = {"fpid": str(now), "area_code": "1", "include_unpublish": "1", "useid": "0",
         "multi_result": multi, "dfid": "-", "mid": md5hex(str(now)), "uuid": "-",
         "appid": appid, "clientver": cver, "clienttime": str(now // 1000)}
    joined = "".join(f"{k}={p[k]}" for k in sorted(p))
    md = hashlib.md5(); md.update(SALT.encode()); md.update(joined.encode()); md.update(body); md.update(SALT.encode())
    q = "&".join(f"{k}={urllib.parse.quote(str(p[k]))}" for k in sorted(p)) + "&signature=" + md.hexdigest()
    req = urllib.request.Request(f"https://{host}{path}?{q}", data=body, method="POST",
                                 headers={"User-Agent": UA, "mid": p["mid"], "dfid": "-",
                                          "Content-Type": "application/octet-stream"})
    try:
        with urllib.request.urlopen(req, timeout=20) as r:
            return r.status, r.read().decode("utf-8", "replace")[:120]
    except urllib.error.HTTPError as e:
        return e.code, e.read().decode("utf-8", "replace")[:60].replace("\n", " ")
    except Exception as e:
        return None, f"{type(e).__name__}: {e}"

print("=== 换 host 找第二个独立后端 ===")
for host in ("gateway.kugou.com", "fp.kugou.com", "trackid.kugou.com", "fingerprint.kugou.com", "fp.service.kugou.com"):
    st, body = call(host, "/fingerprint.service/v1/music_trackid_mulit")
    print(f"{host:26s} → {st} {body[:90]}")

print("\n=== multi_result 取不同值能拿多少条 ===")
for m in ("1", "2", "3", "5"):
    st, body = call("gateway.kugou.com", "/fingerprint.service/v1/music_trackid_mulit", multi=m)
    try:
        j = json.loads(body) if body.startswith("{") else {}
        n = len(j.get("data") or [])
    except Exception:
        n = "?"
    print(f"multi_result={m} → HTTP {st} data={n} {body[:60]}")
