# -*- coding: utf-8 -*-
"""探活：Shazam（GitHub 上 shazamio / Numenorean/ShazamAPI 同源的非官方接口）能否识别中文歌"""
import asyncio, os, shutil, subprocess, sys, json

BASE = r"C:\Users\17948\DoubaoWork\chats\2026-10-22\new-chat-1\_tmp_build"
BIN = os.path.join(BASE, "bin"); os.makedirs(BIN, exist_ok=True)

import imageio_ffmpeg
src = imageio_ffmpeg.get_ffmpeg_exe()
dst = os.path.join(BIN, "ffmpeg.exe")
if not os.path.exists(dst):
    shutil.copy2(src, dst)
os.environ["PATH"] = BIN + os.pathsep + os.environ["PATH"]

MP3 = r"C:\Users\17948\DoubaoWork\chats\2026-10-22\new-chat-1\sunny_day_test\results\kuwo_51685512_320k.mp3"
WAV = os.path.join(BASE, "probe_shazam_10s.wav")
subprocess.run([dst, "-y", "-v", "error", "-ss", "40", "-t", "10", "-i", MP3,
                "-ac", "1", "-ar", "44100", WAV], check=True)
print("样本:", WAV, os.path.getsize(WAV), "B")

from shazamio import Shazam

async def main():
    sh = Shazam()
    res = await sh.recognize(WAV)
    track = res.get("track") or {}
    if not track:
        print("Shazam 结果: 未识别", json.dumps(res, ensure_ascii=False)[:300])
        return
    print("Shazam 结果:")
    print("  歌名:", track.get("title"))
    print("  歌手:", track.get("subtitle"))
    print("  专辑:", (track.get("sections") or [{}])[0].get("metadata", [{}])[0] if track.get("sections") else "")
    for s in track.get("sections") or []:
        for m in s.get("metadata") or []:
            if m.get("title") in ("Album", "专辑"):
                print("  专辑字段:", m.get("text"))

asyncio.run(main())
