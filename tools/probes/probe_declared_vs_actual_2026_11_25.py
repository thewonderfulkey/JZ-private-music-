# -*- coding: utf-8 -*-
"""2026-11-25 · 在线流「声明时长 vs 真实音频」实测（第 2 版）

只回答一个问题：App 在联网播放时**锁死**的那个总长（= AVPlayerItem.duration，
对远端流就是容器/帧头自报的数），和**真实能放出来的音频长度**，会不会不一致？

做法：
  1. 走 App 真在用的通道（GDAPI 网易 / 星海酷狗 / 妖狐酷我）拿到直链；
  2. 整首下载；
  3. 用 ffmpeg 读「容器声明时长」，再整段解码读「真实音频长度」；
  4. 对 mp3 额外读第一帧码率、有没有 Xing/Info 头——没有 Xing 头时，
     AVFoundation 只能按「字节数 ÷ 码率」估时长，这正是会估短的场景。

输出：tools/probes/out/declared_vs_actual/result.json
"""
import json
import os
import re
import ssl
import struct
import subprocess
import sys
import time
import urllib.parse
import urllib.request

import imageio_ffmpeg

FF = imageio_ffmpeg.get_ffmpeg_exe()
UA = ("Mozilla/5.0 (iPhone; CPU iPhone OS 16_6 like Mac OS X) AppleWebKit/605.1.15 "
      "(KHTML, like Gecko) Version/16.6 Mobile/15E148 Safari/604.1")
CTX = ssl.create_default_context()
CTX.check_hostname = False
CTX.verify_mode = ssl.CERT_NONE
OUT = os.path.join(os.path.dirname(__file__), "out", "declared_vs_actual")
os.makedirs(OUT, exist_ok=True)

BITRATES = {1: 32, 2: 40, 3: 48, 4: 56, 5: 64, 6: 80, 7: 96, 8: 112, 9: 128,
            10: 160, 11: 192, 12: 224, 13: 256, 14: 320}
SRATES = {0: 44100, 1: 48000, 2: 32000}


def get(url, headers=None, timeout=20, read=None):
    h = {"User-Agent": UA}
    h.update(headers or {})
    req = urllib.request.Request(url, headers=h)
    with urllib.request.urlopen(req, timeout=timeout, context=CTX) as r:
        data = r.read(read) if read else r.read()
        return r.status, data, dict(r.headers)


def download(url, dst, referer=None):
    h = {"User-Agent": UA}
    if referer:
        h["Referer"] = referer
    req = urllib.request.Request(url, headers=h)
    with urllib.request.urlopen(req, timeout=180, context=CTX) as r, open(dst, "wb") as f:
        total = int(r.headers.get("Content-Length") or 0)
        got = 0
        while True:
            b = r.read(262144)
            if not b:
                break
            f.write(b)
            got += len(b)
        return got, total, dict(r.headers)


def mp3_first_frame(path):
    """返回 (第一帧码率kbps, 是否有 Xing/Info 头, 容器声明时长或 None)。"""
    with open(path, "rb") as f:
        data = f.read(65536)
    i = 0
    if data[:3] == b"ID3":
        size = ((data[6] & 0x7F) << 21) | ((data[7] & 0x7F) << 14) | \
               ((data[8] & 0x7F) << 7) | (data[9] & 0x7F)
        i = 10 + size
    while i < len(data) - 4:
        if data[i] == 0xFF and (data[i + 1] & 0xE0) == 0xE0:
            ver = (data[i + 1] >> 3) & 3
            layer = (data[i + 1] >> 1) & 3
            br_idx = (data[i + 2] >> 4) & 0xF
            if layer == 1 and br_idx in BITRATES and ver != 1:
                frame_len = (144 * BITRATES[br_idx] * 1000) // SRATES[(data[i + 2] >> 2) & 3]
                side = data[i + 4:i + 4 + min(frame_len, 200)]
                has_xing = (b"Xing" in side) or (b"Info" in side)
                return BITRATES[br_idx], has_xing, None
        i += 1
    return None, None, None


def ff_meta(path):
    p = subprocess.run([FF, "-hide_banner", "-i", path], capture_output=True, text=True,
                       encoding="utf-8", errors="replace")
    txt = p.stderr or ""
    declared = None
    m = re.search(r"Duration:\s*(\d+):(\d+):(\d+\.\d+)", txt)
    if m:
        declared = int(m.group(1)) * 3600 + int(m.group(2)) * 60 + float(m.group(3))
    p3 = subprocess.run([FF, "-hide_banner", "-nostats", "-progress", "pipe:1", "-i", path,
                         "-f", "null", "-"], capture_output=True, text=True,
                        encoding="utf-8", errors="replace")
    decoded = None
    for line in (p3.stdout or "").splitlines():
        if line.startswith("out_time_us="):
            v = line.split("=", 1)[1].strip()
            if v.isdigit():
                decoded = int(v) / 1e6
    codec = re.search(r"Audio:\s*([\w]+)", txt)
    return declared, decoded, (codec.group(1) if codec else None)


def gd_search(kw, count=4):
    u = ("https://music-api.gdstudio.xyz/api.php?types=search&source=netease&name="
         + urllib.parse.quote(kw) + "&count=%d" % count)
    st, b, _ = get(u)
    return json.loads(b.decode("utf-8", "replace"))


def gd_url(sid, br=320):
    u = ("https://music-api.gdstudio.xyz/api.php?types=url&source=netease&id=%s&br=%d"
         % (sid, br))
    st, b, _ = get(u)
    o = json.loads(b.decode("utf-8", "replace"))
    return o.get("url") or "", o.get("br"), o.get("size")


def main():
    print("ffmpeg:", FF)
    rows = []
    kws = ["晴天 周杰伦", "七里香 周杰伦", "稻香 周杰伦", "演员 薛之谦", "大鱼 周深", "红豆 方大同"]
    for kw in kws:
        try:
            cands = gd_search(kw, 3)
        except Exception as e:  # noqa: BLE001
            print("search fail", kw, e)
            continue
        for c in cands:
            name = "%s / %s" % (c.get("name"), "/".join(c.get("artist") or []))
            try:
                url, br, size = gd_url(c["id"])
            except Exception as e:  # noqa: BLE001
                print("url fail", name, e)
                continue
            if not url:
                print("no url", name)
                continue
            safe = re.sub(r"[^\w\-]+", "_", "%s_%s" % (c.get("name"), c["id"]))[:60]
            ext = os.path.splitext(urllib.parse.urlparse(url).path)[1] or ".mp3"
            dst = os.path.join(OUT, safe + ext)
            try:
                got, total, hdr = download(url, dst, referer="https://music.163.com/")
            except Exception as e:  # noqa: BLE001
                print("dl fail", name, e)
                continue
            declared, decoded, codec = ff_meta(dst)
            first_br, has_xing, _ = mp3_first_frame(dst) if dst.endswith(".mp3") else (None, None, None)
            est = round(got * 8 / (first_br * 1000), 2) if first_br else None
            row = {"song": name, "api_br": br, "api_size": size, "bytes": got,
                   "codec": codec, "declare": declared, "decoded": decoded,
                   "first_kbps": first_br, "has_xing": has_xing,
                   "byte_estimate": est,
                   "diff": None if (declared is None or decoded is None) else round(decoded - declared, 2),
                   "est_vs_real": None if (est is None or decoded is None) else round(decoded - est, 2),
                   "file": dst}
            rows.append(row)
            print(json.dumps(row, ensure_ascii=False))
            time.sleep(0.8)
    print("\n=== 汇总 ===")
    print("%-34s %-5s %9s %9s %9s %6s %5s %9s %9s" %
          ("song", "codec", "declare", "decoded", "diff", "1st", "xing", "byte_est", "est-real"))
    for r in rows:
        print("%-34s %-5s %9s %9s %9s %6s %5s %9s %9s" %
              (str(r["song"])[:34], r["codec"], r["declare"], r["decoded"], r["diff"],
               r["first_kbps"], r["has_xing"], r["byte_estimate"], r["est_vs_real"]))
    with open(os.path.join(OUT, "result.json"), "w", encoding="utf-8") as f:
        json.dump(rows, f, ensure_ascii=False, indent=2)


if __name__ == "__main__":
    sys.exit(main())
