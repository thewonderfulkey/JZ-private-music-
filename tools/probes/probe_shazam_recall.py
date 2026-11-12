# -*- coding: utf-8 -*-
"""Shazam 通道召回实测：时长 3/5/8/10s + 加噪 10dB/0dB，以及直连 amp.shazam.com 是否无 key 可用"""
import asyncio, json, math, os, random, struct, subprocess, urllib.request, uuid

BASE = r"C:\Users\17948\DoubaoWork\chats\2026-10-22\new-chat-1\_tmp_build"
FFMPEG = os.path.join(BASE, "bin", "ffmpeg.exe")
MP3 = r"C:\Users\17948\DoubaoWork\chats\2026-10-22\new-chat-1\sunny_day_test\results\kuwo_51685512_320k.mp3"

def clip(seconds, offset=40, out=None, snr=None):
    out = out or os.path.join(BASE, f"sh_{seconds}s_{snr}.wav")
    subprocess.run([FFMPEG, "-y", "-v", "error", "-ss", str(offset), "-t", str(seconds), "-i", MP3,
                    "-ac", "1", "-ar", "44100", out], check=True)
    if snr is not None:
        data = open(out, "rb").read()
        hdr, pcm = data[:44], data[44:]
        n = len(pcm) // 2
        vals = struct.unpack("<%dh" % n, pcm)
        rms = math.sqrt(sum(v * v for v in vals) / n) or 1.0
        amp = rms / (10 ** (snr / 20))
        noisy = [max(-32768, min(32767, int(v + random.gauss(0, amp)))) for v in vals]
        open(out, "wb").write(hdr + struct.pack("<%dh" % n, *noisy))
    return out

async def main():
    from shazamio import Shazam
    from shazamio_core import SearchParams
    sh = Shazam()

    print("=== A. 时长对召回的影响（同一首歌，40s 处开始）===")
    for sec in (3, 5, 8, 10):
        wav = clip(sec)
        try:
            res = await sh.recognize(wav)
            t = res.get("track") or {}
            print(f"  {sec:>2}s: {(t.get('title') or '未识别')} / {(t.get('subtitle') or '-')}")
        except Exception as e:
            print(f"  {sec:>2}s: 异常 {type(e).__name__} {str(e)[:80]}")

    print("\n=== B. 加噪（10s，SNR 10dB / 0dB）===")
    for snr in (10, 0):
        wav = clip(10, snr=snr)
        try:
            res = await sh.recognize(wav)
            t = res.get("track") or {}
            print(f"  SNR {snr:>2}dB: {(t.get('title') or '未识别')} / {(t.get('subtitle') or '-')}")
        except Exception as e:
            print(f"  SNR {snr:>2}dB: 异常 {type(e).__name__} {str(e)[:80]}")

    print("\n=== C. 直连 amp.shazam.com/discovery/v5（Audile 用的端点，检查是否需要 key）===")
    wav = clip(10)
    sig = await sh.core_recognizer.recognize_path(value=wav, options=SearchParams())
    body = json.dumps({
        "geolocation": {"altitude": 100.0, "latitude": 0.0, "longitude": 0.0},
        "signature": {"samplems": 10000, "timestamp": 0, "uri": sig.signature.uri},
        "timestamp": 0, "timezone": "Asia/Shanghai",
    }).encode()
    url = ("https://amp.shazam.com/discovery/v5/en/US/android/-/tag/"
           + str(uuid.uuid4()).upper() + "/" + str(uuid.uuid4())
           + "?sync=true&webv3=true&sampling=true&connected=&shazamapiversion=v3&sharehub=true&video=v3")
    req = urllib.request.Request(url, data=body, method="POST", headers={
        "user-agent": "Dalvik/2.1.0 (Linux; U; Android 5.1.1; SM-J500FN Build/LMY48B)",
        "content-type": "application/json", "content-language": "en_US"})
    try:
        with urllib.request.urlopen(req, timeout=30) as r:
            d = json.loads(r.read().decode("utf-8", "replace"))
            print("  HTTP", r.status, "| matches:", 1 if d.get("matches") else 0)
            for m in (d.get("matches") or [])[:1]:
                print("  命中:", m.get("title"), "/", m.get("subtitle"))
    except urllib.error.HTTPError as e:
        print("  HTTP", e.code, e.read().decode("utf-8", "replace")[:160])

asyncio.run(main())
