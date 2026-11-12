# -*- coding: utf-8 -*-
"""酷狗识曲第二轮：kmr 走 http（https 证书不匹配）、试路径与返回结构。"""
import hashlib, json, os, time, urllib.parse, urllib.request

PCM = r"C:\Users\17948\DoubaoWork\chats\2026-10-22\new-chat-1\_tmp_build\probe_kugou_recognize.pcm"
SALT = "LnT6xpN3khm36zse0QzvmgTZ3waWdRSA"
raw = open(PCM, "rb").read()


def md5(s):
    return hashlib.md5(s.encode("utf-8")).hexdigest()


def kg_query(mid, public=True, extra=None):
    params = dict(extra or {})
    if public:
        params.update({"userid": "0", "appid": "3116", "token": "", "clienttime": int(time.time()),
                       "iscorrection": "1", "uuid": "-", "mid": mid, "dfid": "-",
                       "clientver": "11070", "platform": "AndroidFilter"})
    else:
        params.update({"appid": "3116", "clientver": "11070"})
    ordered = sorted(params.items())
    sig = md5(SALT + "".join("%s=%s" % (k, v) for k, v in ordered) + SALT)
    return urllib.parse.urlencode(ordered) + "&signature=" + sig


mid = md5(str(time.time()))
tries = [
    ("http", "kmr.service.kugou.com", "/audio/match", True),
    ("http", "kmr.service.kugou.com", "/audio/match", False),
    ("http", "kmr.service.kugou.com", "/v1/audio/match", True),
    ("https", "kmr.service.kugou.com", "/v1/audio/match", True),
]
for scheme, host, path, public in tries:
    url = "%s://%s%s?%s" % (scheme, host, path, kg_query(mid, public))
    headers = {
        "User-Agent": "Android14-1070-11070-201-0-KmrAudioMatch-wifi",
        "Content-Type": "application/octet-stream",
        "KG-Rec": "1", "KG-RC": "1", "mid": mid,
        "KG-CLIENTTIMEMS": str(int(time.time() * 1000)),
        "Accept": "*/*",
    }
    try:
        req = urllib.request.Request(url, data=raw, headers=headers, method="POST")
        r = urllib.request.urlopen(req, timeout=40)
        body = r.read().decode("utf-8", "replace")
        print("\n[%s %s %s public=%s] HTTP %s len=%d" % (scheme, host, path, public, r.status, len(body)))
        print(body[:900])
    except Exception as e:
        print("\n[%s %s %s public=%s] ERR %r" % (scheme, host, path, public, e))
        try:
            print("  body:", e.read().decode("utf-8", "replace")[:400])
        except Exception:
            pass
