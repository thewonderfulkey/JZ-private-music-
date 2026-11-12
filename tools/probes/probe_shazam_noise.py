# -*- coding: utf-8 -*-
"""重测加噪（上一版自己拼 WAV 头拼错了，导致 SignatureError；这次用 ffmpeg 输出裸 PCM 再自己封头）"""
import asyncio, math, os, random, struct, subprocess, wave

BASE = r"C:\Users\17948\DoubaoWork\chats\2026-10-22\new-chat-1\_tmp_build"
FFMPEG = os.path.join(BASE, "bin", "ffmpeg.exe")
MP3 = r"C:\Users\17948\DoubaoWork\chats\2026-10-22\new-chat-1\sunny_day_test\results\kuwo_51685512_320k.mp3"
RAW = os.path.join(BASE, "sh_raw.pcm")

def noisy_wav(seconds, snr, offset=40):
    subprocess.run([FFMPEG, "-y", "-v", "error", "-ss", str(offset), "-t", str(seconds), "-i", MP3,
                    "-ac", "1", "-ar", "44100", "-f", "s16le", RAW], check=True)
    data = open(RAW, "rb").read()
    n = len(data) // 2
    vals = struct.unpack("<%dh" % n, data)
    rms = math.sqrt(sum(v * v for v in vals) / n) or 1.0
    amp = rms / (10 ** (snr / 20))
    noisy = [max(-32768, min(32767, int(v + random.gauss(0, amp)))) for v in vals]
    out = os.path.join(BASE, f"sh_{seconds}s_snr{snr}.wav")
    with wave.open(out, "wb") as w:
        w.setnchannels(1); w.setsampwidth(2); w.setframerate(44100)
        w.writeframes(struct.pack("<%dh" % n, *noisy))
    return out

async def main():
    from shazamio import Shazam
    sh = Shazam()
    print("=== 加噪召回（10s，起点 40s）===")
    for snr in (20, 10, 5, 0):
        wav = noisy_wav(10, snr)
        try:
            res = await sh.recognize(wav)
            t = res.get("track") or {}
            print(f"  SNR {snr:>2}dB: {(t.get('title') or '未识别')} / {(t.get('subtitle') or '-')}")
        except Exception as e:
            print(f"  SNR {snr:>2}dB: 异常 {type(e).__name__} {str(e)[:60]}")

    print("\n=== 起点位置影响（10s，起点 0s / 80s / 200s）===")
    for off in (0, 80, 200):
        wav = noisy_wav(10, 99, offset=off)  # 99dB ≈ 几乎不加噪
        try:
            res = await sh.recognize(wav)
            t = res.get("track") or {}
            print(f"  起点 {off:>3}s: {(t.get('title') or '未识别')} / {(t.get('subtitle') or '-')}")
        except Exception as e:
            print(f"  起点 {off:>3}s: 异常 {type(e).__name__} {str(e)[:60]}")

asyncio.run(main())
