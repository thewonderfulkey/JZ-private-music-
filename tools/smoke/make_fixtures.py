# -*- coding: utf-8 -*-
"""生成识曲冒烟用的 PCM 样本（12 秒 / 8kHz / 单声道 / 16bit，网易与酷狗都吃这个口径）。

来源：通过项目里在用的妖狐酷我通道拿直链 → 下载 mp3 → miniaudio 解码 →
重采样到 8k → 取第 30 秒起的 12 秒（避开前奏，保证有唱段）。

用法：
  python tools/smoke/make_fixtures.py
产物：
  tools/smoke/fixtures/qingtian_8k.pcm      晴天 / 周杰伦（期望：酷狗 is_original 命中）
  tools/smoke/fixtures/womendouyiyang_8k.pcm 我们都一样 / 张杰（期望：酷狗给翻唱、网易给原唱）
"""
import array
import json
import math
import os
import sys
import urllib.parse
import urllib.request

import miniaudio

ROOT = os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
OUT = os.path.join(ROOT, "tools", "smoke", "fixtures")
YAOHU = "https://api.yaohud.cn/api/music/kuwo?key=nvgKtvzw7CFSNFrDhA6&action=search&msg={}&n=1"
UA = ("Mozilla/5.0 (iPhone; CPU iPhone OS 16_6 like Mac OS X) AppleWebKit/605.1.15 "
      "(KHTML, like Gecko) Version/16.6 Mobile/15E148 Safari/604.1")

SONGS = [
    ("qingtian_8k.pcm", "晴天 周杰伦", 0),
    ("womendouyiyang_8k.pcm", "我们都一样 张杰", 30),
]


def http_get(url, timeout=40):
    req = urllib.request.Request(url, headers={"User-Agent": UA, "Referer": "https://www.kuwo.cn/"})
    with urllib.request.urlopen(req, timeout=timeout) as r:
        return r.read()


def resolve(keyword):
    raw = http_get(YAOHU.format(urllib.parse.quote(keyword))).decode("utf-8", "ignore")
    data = json.loads(raw)
    # 兼容几种返回形状
    node = data.get("data") or data.get("result") or data
    if isinstance(node, list):
        node = node[0]
    if isinstance(node, dict):
        # 妖狐酷我：直链在 data.vipmusic.url
        for k in ("vipmusic", "data", "result"):
            sub = node.get(k)
            if isinstance(sub, dict):
                for key in ("url", "link", "music_url", "src"):
                    if sub.get(key):
                        return sub[key], node
        for key in ("url", "link", "music_url", "src"):
            if node.get(key):
                return node[key], node
    raise RuntimeError(f"没拿到直链：{raw[:300]}")


def decode_12s_8k(mp3_bytes, start_sec):
    dec = miniaudio.decode(mp3_bytes, output_format=miniaudio.SampleFormat.SIGNED16,
                           nchannels=1, sample_rate=44100)
    pcm = array.array("h")
    pcm.frombytes(dec.samples.tobytes() if hasattr(dec.samples, "tobytes") else bytes(dec.samples))
    rate = dec.sample_rate or 44100
    start = int(start_sec * rate)
    seg = pcm[start: start + 12 * rate]
    if len(seg) < 12 * rate:
        raise RuntimeError(f"音频太短：{len(pcm)/rate:.1f}s")
    # 线性重采样到 8k
    n_out = int(len(seg) * 8000 / rate)
    step = rate / 8000.0
    out = array.array("h", bytes(2 * n_out))
    for i in range(n_out):
        x = i * step
        i0 = int(x)
        frac = x - i0
        i1 = min(i0 + 1, len(seg) - 1)
        out[i] = int(seg[i0] * (1 - frac) + seg[i1] * frac)
    # 峰值归一化到 -3dBFS（外放/手机录音都远低于满量程，归一化更接近"听得清"）
    peak = max(1, max(abs(v) for v in out))
    gain = (0.7 * 32767) / peak
    if gain > 1.0:
        out = array.array("h", [max(-32768, min(32767, int(v * gain))) for v in out])
    return out.tobytes()


def rms(pcm):
    a = array.array("h")
    a.frombytes(pcm[: len(pcm) // 2 * 2])
    s = a[::5]
    return math.sqrt(sum(x * x for x in s) / max(1, len(s))) / 32768.0


def main():
    os.makedirs(OUT, exist_ok=True)
    for name, keyword, start in SONGS:
        print(f"==> {keyword}")
        url, meta = resolve(keyword)
        print("    url:", url[:90])
        mp3 = http_get(url)
        print(f"    mp3: {len(mp3):,} B")
        pcm = decode_12s_8k(mp3, start)
        path = os.path.join(OUT, name)
        with open(path, "wb") as f:
            f.write(pcm)
        print(f"    pcm: {len(pcm):,} B  rms={rms(pcm):.3f}  -> {path}")


if __name__ == "__main__":
    sys.exit(main())


