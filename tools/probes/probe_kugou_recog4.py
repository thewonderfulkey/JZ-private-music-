# -*- coding: utf-8 -*-
"""复刻 KuGouMusicApi 的听歌识曲：POST /fingerprint.service/v1/music_trackid_mulit
签名 = md5(salt + 排序后的 k=v 拼接 + body + salt)，salt 概念版 = LnT6xpN3khm36zse0QzvmgTZ3waWdRSA
"""
import hashlib, json, time, urllib.parse, urllib.request

PCM = r"C:\Users\17948\DoubaoWork\chats\2026-10-22\new-chat-1\_tmp_build\probe_kugou_recognize.pcm"
SALT = "LnT6xpN3khm36zse0QzvmgTZ3waWdRSA"
body = open(PCM, "rb").read()
print("pcm", len(body))


def md5b(b):
    return hashlib.md5(b).hexdigest()


def run(clientver):
    mid = md5b(str(time.time()).encode())
    params = {
        "fpid": int(time.time() * 1000),
        "area_code": 1,
        "include_unpublish": 1,
        "useid": 0,
        "multi_result": 1,
        "dfid": "-",
        "mid": mid,
        "uuid": "-",
        "appid": 3116,
        "clientver": clientver,
        "clienttime": int(time.time()),
    }
    ps = "".join("%s=%s" % (k, params[k]) for k in sorted(params))
    sig = hashlib.md5(SALT.encode() + ps.encode() + body + SALT.encode()).hexdigest()
    url = "https://gateway.kugou.com/fingerprint.service/v1/music_trackid_mulit?" + \
        urllib.parse.urlencode(sorted(params.items())) + "&signature=" + sig
    headers = {
        "Content-Type": "application/octet-stream",
        "User-Agent": "KuGou/11490 (Android)",
        "mid": mid, "dfid": "-",
    }
    req = urllib.request.Request(url, data=body, headers=headers, method="POST")
    r = urllib.request.urlopen(req, timeout=60)
    txt = r.read().decode("utf-8", "replace")
    print("\nclientver=%s HTTP %s len=%d" % (clientver, r.status, len(txt)))
    print(txt[:1200])
    return txt


for cv in (11070, 11440):
    try:
        run(cv)
    except Exception as e:
        print("clientver=%s ERR %r" % (cv, e))
        try:
            print("  body:", e.read().decode("utf-8", "replace")[:600])
        except Exception:
            pass
