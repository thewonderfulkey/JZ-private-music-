# -*- coding: utf-8 -*-
"""8k PCM 识别实测：多起止点取样，打印完整返回结构。"""
import hashlib, json, time, urllib.parse, urllib.request

SALT = "LnT6xpN3khm36zse0QzvmgTZ3waWdRSA"
PCM = r"C:\Users\17948\DoubaoWork\chats\2026-10-22\new-chat-1\_tmp_build\probe_kugou_recognize_8k.pcm"
body = open(PCM, "rb").read()
print("pcm bytes", len(body), "expected sec", len(body) / 16000)


def recog(body, cv=11070):
    mid = hashlib.md5(str(time.time()).encode()).hexdigest()
    params = {"fpid": int(time.time() * 1000), "area_code": 1, "include_unpublish": 1,
              "useid": 0, "multi_result": 1, "dfid": "-", "mid": mid, "uuid": "-",
              "appid": 3116, "clientver": cv, "clienttime": int(time.time())}
    ps = "".join("%s=%s" % (k, params[k]) for k in sorted(params))
    sig = hashlib.md5(SALT.encode() + ps.encode() + body + SALT.encode()).hexdigest()
    url = "https://gateway.kugou.com/fingerprint.service/v1/music_trackid_mulit?" + \
        urllib.parse.urlencode(sorted(params.items())) + "&signature=" + sig
    req = urllib.request.Request(url, data=body,
                                 headers={"Content-Type": "application/octet-stream",
                                          "User-Agent": "KuGou/11490 (Android)",
                                          "mid": mid, "dfid": "-"}, method="POST")
    r = urllib.request.urlopen(req, timeout=60)
    return r.read().decode("utf-8", "replace")


txt = recog(body)
print("\nRESP:", txt[:3000])
try:
    j = json.loads(txt)
    d = j.get("data") or {}
    print("\ndata keys:", list(d.keys()))
    print(json.dumps(d, ensure_ascii=False)[:2500])
except Exception as e:
    print("parse err", e)
