# -*- coding: utf-8 -*-
"""v2.1.84：确认「时长可配置」不是空话——把 5/10/15/20 秒的 8k 单声道 PCM 逐个打酷狗指纹接口，
看是否都能正常返回候选（接口对音频长度可能有隐含要求，先实测再定 UI 档位）。"""
import hashlib, json, subprocess, time, urllib.parse, urllib.request, os

FF = r"D:\剪映\JianyingPro\11.6.0.14552\ffmpeg.exe"
MP3 = r"C:\Users\17948\DoubaoWork\chats\2026-10-22\new-chat-1\sunny_day_test\results\kuwo_51685512_320k.mp3"
TMP = r"C:\Users\17948\DoubaoWork\chats\2026-10-22\new-chat-1\_tmp_build"
SALT = "LnT6xpN3khm36zse0QzvmgTZ3waWdRSA"


def md5b(b):
    return hashlib.md5(b).hexdigest()


def make_pcm(seconds, out):
    subprocess.run(
        [FF, "-y", "-ss", "8", "-t", str(seconds), "-i", MP3,
         "-ac", "1", "-ar", "8000", "-f", "s16le", "-acodec", "pcm_s16le", out],
        stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL, check=True,
    )
    return open(out, "rb").read()


def run(body, label):
    mid = md5b(str(time.time()).encode() + label.encode())
    params = {
        "fpid": int(time.time() * 1000), "area_code": 1, "include_unpublish": 1,
        "useid": 0, "multi_result": 1, "dfid": "-", "mid": mid, "uuid": "-",
        "appid": 3116, "clientver": 11070, "clienttime": int(time.time()),
    }
    ps = "".join("%s=%s" % (k, params[k]) for k in sorted(params))
    sig = hashlib.md5(SALT.encode() + ps.encode() + body + SALT.encode()).hexdigest()
    url = "https://gateway.kugou.com/fingerprint.service/v1/music_trackid_mulit?" + \
        urllib.parse.urlencode(sorted(params.items())) + "&signature=" + sig
    req = urllib.request.Request(
        url, data=body,
        headers={"Content-Type": "application/octet-stream",
                 "User-Agent": "KuGou/11490 (Android)", "mid": mid, "dfid": "-"},
        method="POST",
    )
    try:
        with urllib.request.urlopen(req, timeout=60) as r:
            txt = r.read().decode("utf-8", "replace")
        o = json.loads(txt)
        data = o.get("data") or []
        top = None
        if data:
            d0 = data[0]
            top = "%s / %s" % (d0.get("songname"), d0.get("singername"))
        print("%-6s bytes=%-7d error_code=%s candidates=%d top=%s" % (
            label, len(body), o.get("error_code"), len(data), top))
        return len(data)
    except Exception as e:
        print("%-6s bytes=%-7d ERR %r" % (label, len(body), e))
        return -1


for sec in (5, 10, 15, 20):
    path = os.path.join(TMP, "pcm2184_%ds.pcm" % sec)
    pcm = make_pcm(sec, path)
    run(pcm, "%ds" % sec)
