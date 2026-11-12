# -*- coding: utf-8 -*-
"""v2.1.82 采集口径离线实测：
把同一段 10 秒音乐分别做成
  A 直接 8k（旧版口径）
  B 16k -> 2 点平均 -> 8k
  C 48k -> 6 点平均 -> 8k（新版口径，6 点平均完全照抄 Kotlin to8k 的整倍数分支）
再逐个打酷狗指纹识曲接口，比较识别结果。
"""
import hashlib
import json
import math
import os
import time
import urllib.parse
import urllib.request

BASE = os.path.dirname(os.path.abspath(__file__))
SALT = "LnT6xpN3khm36zse0QzvmgTZ3waWdRSA"
ENDPOINT = "https://gateway.kugou.com/fingerprint.service/v1/music_trackid_mulit"


def to8k(src, source_rate):
    """完全照抄 VoiceCapture.to8k 的整倍数分支（PCM16 小端）"""
    if source_rate == 8000:
        return src
    samples = len(src) // 2
    factor = source_rate // 8000
    out_samples = samples // factor
    dst = bytearray(out_samples * 2)
    for o in range(out_samples):
        acc = 0
        base = o * factor
        for k in range(factor):
            i = (base + k) * 2
            lo = src[i]
            hi = src[i + 1]
            v = (hi << 8) | lo
            if v >= 32768:
                v -= 65536
            acc += v
        v = int(acc / factor)
        if v < 0:
            v += 65536
        dst[o * 2] = v & 0xFF
        dst[o * 2 + 1] = (v >> 8) & 0xFF
    return bytes(dst)


def rms_of(pcm):
    n = len(pcm) // 2
    s = 0.0
    ss = 0.0
    for i in range(0, len(pcm) - 1, 2):
        lo = pcm[i]
        hi = pcm[i + 1]
        v = (hi << 8) | lo
        if v >= 32768:
            v -= 65536
        s += v
        ss += v * v
    if n == 0:
        return 0.0, 0.0
    mean = s / n
    var = max(ss - n * mean * mean, 0.0)
    return (var / n) ** 0.5 / 32768.0, abs(mean) / 32768.0


def recog(body):
    mid = hashlib.md5(str(time.time()).encode()).hexdigest()
    params = {"fpid": int(time.time() * 1000), "area_code": 1, "include_unpublish": 1,
              "useid": 0, "multi_result": 1, "dfid": "-", "mid": mid, "uuid": "-",
              "appid": 3116, "clientver": 11070, "clienttime": int(time.time())}
    ps = "".join("%s=%s" % (k, params[k]) for k in sorted(params))
    sig = hashlib.md5(SALT.encode() + ps.encode() + body + SALT.encode()).hexdigest()
    url = ENDPOINT + "?" + urllib.parse.urlencode(sorted(params.items())) + "&signature=" + sig
    req = urllib.request.Request(
        url, data=body,
        headers={"Content-Type": "application/octet-stream",
                 "User-Agent": "KuGou/11490 (Android)",
                 "mid": mid, "dfid": "-"}, method="POST")
    txt = urllib.request.urlopen(req, timeout=60).read().decode("utf-8", "replace")
    try:
        j = json.loads(txt)
    except Exception:
        return "PARSE_FAIL " + txt[:80]
    code = j.get("error_code")
    data = j.get("data") or []
    if not data:
        return "error_code=%s data=[]" % code
    top = data[0]
    return "error_code=%s top=%s / %s (hits=%d)" % (
        code, top.get("songname"), top.get("singername"), len(data))


def main():
    src8 = open(os.path.join(BASE, "pcm2182_8k.pcm"), "rb").read()
    src16 = open(os.path.join(BASE, "pcm2182_16k.pcm"), "rb").read()
    src48 = open(os.path.join(BASE, "pcm2182_48k.pcm"), "rb").read()
    print("raw bytes  8k=%d 16k=%d 48k=%d" % (len(src8), len(src16), len(src48)))

    variants = [
        ("A 直接8k(旧口径)", src8),
        ("B 16k→平均→8k", to8k(src16, 16000)),
        ("C 48k→平均→8k(新口径)", to8k(src48, 48000)),
    ]
    for name, pcm in variants:
        rms, dc = rms_of(pcm)
        db = 20 * math.log10(max(rms, 1e-9))
        print("\n[%s] bytes=%d (=%.1f 秒) RMS=%.4f (%.0fdB) DC=%.4f"
              % (name, len(pcm), len(pcm) / 16000.0, rms, db, dc))
        try:
            print("  ->", recog(pcm))
        except Exception as e:
            print("  -> EXC", repr(e))
        time.sleep(1)


main()
