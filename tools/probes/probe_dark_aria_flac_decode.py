# -*- coding: utf-8 -*-
"""整首解码校验：文件能不能完整解出来、有没有坏帧/静音段。

（上一版把 BytesIO 交给 sf.info 之后又接着读，指针停在末尾所以报错；这里先落盘再读。）
"""
import json
import os
import tempfile
import urllib.request

import numpy as np
import soundfile as sf

UA = ("Mozilla/5.0 (iPhone; CPU iPhone OS 16_6 like Mac OS X) AppleWebKit/605.1.15 "
      "(KHTML, like Gecko) Version/16.6 Mobile/15E148 Safari/604.1")
TMP = os.path.join(tempfile.gettempdir(), "jz_probe_flac")
os.makedirs(TMP, exist_ok=True)


def gd(sid, br="740"):
    u = ("https://music-api.gdstudio.xyz/api.php?use_xbridge3=true&loader_name=forest"
         f"&need_sec_link=1&sec_link_scene=im&theme=light&types=url&source=netease&id={sid}&br={br}")
    req = urllib.request.Request(u, headers={"User-Agent": "LX-Music-Mobile"})
    with urllib.request.urlopen(req, timeout=30) as r:
        return json.loads(r.read().decode())


def fetch(url, path):
    if os.path.exists(path) and os.path.getsize(path) > 0:
        return path
    req = urllib.request.Request(url, headers={"User-Agent": UA,
                                               "Referer": "https://music.163.com/"})
    with urllib.request.urlopen(req, timeout=300) as r, open(path, "wb") as f:
        f.write(r.read())
    return path


cases = [("2135545143", "DARK ARIA", 141.744),
         ("1845920219", "枝垂桜 (24bit 对照)", 209.57),
         ("1923910686", "DARK SAUCE (16bit 对照)", 149.083)]

for sid, label, expected in cases:
    try:
        j = gd(sid)
        url = j.get("url") or ""
        if not url:
            print(f"{sid} {label}: 没有 URL")
            continue
        path = fetch(url, os.path.join(TMP, f"{sid}.flac"))
        info = sf.info(path)
        print(f"\n{sid} {label}: {os.path.getsize(path)} B, "
              f"{info.format}/{info.subtype} {info.samplerate}Hz {info.channels}ch "
              f"{info.duration:.3f}s（元数据 {expected}s）")
        # 分块解码整首，统计坏帧 / 静音段
        total = 0
        peak = 0.0
        silent_blocks = 0
        with sf.SoundFile(path) as f:
            while True:
                block = f.read(48000, dtype="float32", always_2d=True)
                if len(block) == 0:
                    break
                total += len(block)
                p = float(np.abs(block).max())
                peak = max(peak, p)
                if p < 1e-6:
                    silent_blocks += 1
        print(f"  解码 {total} 帧 = {total / info.samplerate:.3f}s，峰值 {peak:.4f}，"
              f"整块静音的块数 {silent_blocks}")
        if abs(total / info.samplerate - expected) > 0.5:
            print("  ⚠️ 实际解码时长与元数据不一致")
    except Exception as e:  # noqa: BLE001
        print(f"{sid} {label}: 失败 {e!r}")
