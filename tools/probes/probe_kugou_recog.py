# -*- coding: utf-8 -*-
"""实测酷狗听歌识曲 /audio/match：确定 host、签名参数集、PCM 格式与返回结构。"""
import hashlib, json, os, subprocess, urllib.parse, urllib.request, time

FFMPEG = r"D:\剪映\JianyingPro\11.6.0.14552\ffmpeg.exe"
SRC = r"C:\Users\17948\DoubaoWork\chats\2026-10-22\new-chat-1\sunny_day_test\results\kuwo_51685512_320k.mp3"
OUT = r"C:\Users\17948\DoubaoWork\chats\2026-10-22\new-chat-1\_tmp_build\probe_kugou_recognize.pcm"
SALT = "LnT6xpN3khm36zse0QzvmgTZ3waWdRSA"

if not os.path.exists(OUT) or os.path.getsize(OUT) < 100000:
    subprocess.run([FFMPEG, "-y", "-i", SRC, "-ss", "00:00:40", "-t", "10",
                    "-f", "s16le", "-ac", "1", "-ar", "16000", OUT],
                   capture_output=True)
print("pcm bytes:", os.path.getsize(OUT) if os.path.exists(OUT) else 0)

raw = open(OUT, "rb").read()


def md5(s):
    return hashlib.md5(s.encode("utf-8")).hexdigest()


def kg_query(extra, mid, public=True):
    params = dict(extra)
    if public:
        params.update({"userid": "0", "appid": "3116", "token": "", "clienttime": int(time.time()),
                       "iscorrection": "1", "uuid": "-", "mid": mid, "dfid": "-",
                       "clientver": "11070", "platform": "AndroidFilter"})
    else:
        params.update({"appid": "3116", "clientver": "11070"})
    ordered = sorted(params.items())
    s = SALT + "".join("%s=%s" % (k, v) for k, v in ordered) + SALT
    sig = md5(s)
    return urllib.parse.urlencode(ordered) + "&signature=" + sig


mid = md5(str(time.time()))
variants = []
for host in ["kmr.service.kugou.com", "mobilekmr.kugou.com", "kugou.com"]:
    for public in (True, False):
        variants.append((host, public))
for mod in ["KmrAudioMatch", "audio-match", "AudioMatch"]:
    variants.append(("kmr.service.kugou.com", True, mod))

for v in variants:
    host, public = v[0], v[1]
    mod = v[2] if len(v) > 2 else "KmrAudioMatch"
    q = kg_query({}, mid, public)
    url = "https://%s/audio/match?%s" % (host, q)
    headers = {
        "User-Agent": "Android14-1070-11070-201-0-%s-wifi" % mod,
        "Content-Type": "application/octet-stream",
        "KG-Rec": "1", "KG-RC": "1", "mid": mid,
        "KG-CLIENTTIMEMS": str(int(time.time() * 1000)),
    }
    try:
        req = urllib.request.Request(url, data=raw, headers=headers, method="POST")
        resp = urllib.request.urlopen(req, timeout=30)
        body = resp.read().decode("utf-8", "replace")
        print("\n[%s public=%s mod=%s] HTTP %s" % (host, public, mod, resp.status))
        print(body[:800])
        try:
            j = json.loads(body)
            if j.get("status") == 0 or j.get("data"):
                print("*** 命中候选 host=%s public=%s mod=%s" % (host, public, mod))
                break
        except Exception:
            pass
    except Exception as e:
        print("\n[%s public=%s mod=%s] ERR %s" % (host, public, mod, e))
