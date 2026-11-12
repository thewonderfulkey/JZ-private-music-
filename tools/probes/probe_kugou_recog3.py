# -*- coding: utf-8 -*-
"""酷狗识曲第三轮：在 kmr 主机上试 /kmr/... 路径。"""
import hashlib, time, urllib.parse, urllib.request

PCM = r"C:\Users\17948\DoubaoWork\chats\2026-10-22\new-chat-1\_tmp_build\probe_kugou_recognize.pcm"
SALT = "LnT6xpN3khm36zse0QzvmgTZ3waWdRSA"
raw = open(PCM, "rb").read()


def md5(s):
    return hashlib.md5(s.encode("utf-8")).hexdigest()


def kg_query(mid):
    params = {"userid": "0", "appid": "3116", "token": "", "clienttime": int(time.time()),
              "iscorrection": "1", "uuid": "-", "mid": mid, "dfid": "-",
              "clientver": "11070", "platform": "AndroidFilter"}
    ordered = sorted(params.items())
    sig = md5(SALT + "".join("%s=%s" % (k, v) for k, v in ordered) + SALT)
    return urllib.parse.urlencode(ordered) + "&signature=" + sig


mid = md5(str(time.time()))
paths = ["/kmr/audio/match", "/kmr/audio/recognize", "/kmr/match", "/kmr/audio/matches"]
hosts = ["http://kmr.service.kugou.com", "http://kugou.com", "http://mobile.kugou.com"]
for host in hosts:
    for p in paths:
        url = host + p + "?" + kg_query(mid)
        headers = {"User-Agent": "Android14-1070-11070-201-0-KmrAudioMatch-wifi",
                   "Content-Type": "application/octet-stream", "mid": mid,
                   "KG-CLIENTTIMEMS": str(int(time.time() * 1000))}
        try:
            req = urllib.request.Request(url, data=raw, headers=headers, method="POST")
            r = urllib.request.urlopen(req, timeout=30)
            body = r.read().decode("utf-8", "replace")
            print("[%s%s] HTTP %s -> %s" % (host, p, r.status, body[:300]))
        except Exception as e:
            code = getattr(e, "code", None)
            print("[%s%s] ERR %s" % (host, p, code or e))
