# -*- coding: utf-8 -*-
"""生成给网易指纹用的 8k Float32 PCM（12 秒，48k 录后 6:1 抽取），存成 base64 文本"""
import base64, os, struct, subprocess

BASE = r"C:\Users\17948\DoubaoWork\chats\2026-10-22\new-chat-1\_tmp_build"
FFMPEG = os.path.join(BASE, "bin", "ffmpeg.exe")
MP3 = r"C:\Users\17948\DoubaoWork\chats\2026-10-22\new-chat-1\sunny_day_test\results\kuwo_51685512_320k.mp3"

raw = os.path.join(BASE, "ncm_48k_12s.pcm")
subprocess.run([FFMPEG, "-y", "-v", "error", "-ss", "30", "-t", "12", "-i", MP3,
                "-ac", "1", "-ar", "48000", "-f", "f32le", raw], check=True)
data = open(raw, "rb").read()
vals = struct.unpack("<%df" % (len(data) // 4), data)[::6]  # 48000 -> 8000
print("8k 样本数:", len(vals))

b64 = base64.b64encode(struct.pack("<%df" % len(vals), *vals)).decode()
out = os.path.join(BASE, "pcm8k_b64.txt")
open(out, "w", encoding="utf-8").write(b64)
print("写出:", out, len(b64), "字符")
