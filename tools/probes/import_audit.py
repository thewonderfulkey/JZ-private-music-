#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""导入失败归因探针（一次性取证脚本，不参与出包）。

用法：
    python tools/probes/import_audit.py "D:\\某个有很多歌的文件夹" [--csv out.csv] [--limit 0] [--all]

它做的事，就是 JZ 音乐导入链路对每个文件做的**只读判定**（对应 iOS 端
`DownloadManager.importAudioFiles` → `localMetadata` → `AVURLAsset/AVAudioFile`）：

  1. 扩展名是否在 `ImportRules.playableExtensions` 里（不在 → 「不支持」）
  2. 头 64KB 判真容器（fLaC / MPEG 帧 / ftyp / RIFF-WAVE / FORM-AIFF / OggS / MAC / NCM …）
     —— 扩展名写 .flac 但字节不是 FLAC 的，这里能一眼看出来（加密包/改名/截断）
  3. 解析时长：FLAC=STREAMINFO 的 total_samples；MP3=首帧头；M4A=mvhd；WAV=fmt+data
     —— 时长读不出 = App 端「读取失败」的同一个判据
  4. 顺带报 0 字节 / 只有 ID3 没有帧 这些常见「没下载完」

输出：逐文件 verdict + 按原因/扩展名聚类，用来回答「600 多首里那 200 多首到底为什么失败」。
"""
from __future__ import annotations

import argparse
import csv
import os
import sys
from collections import Counter, defaultdict

PLAYABLE = {"mp3", "m4a", "m4b", "aac", "flac", "wav", "aiff", "aif", "caf", "alac"}
# iOS 系统本身没有解码器的（App 端判「不支持」）
NO_DECODER = {"ape", "wma", "dsf", "dff", "ogg", "opus", "tta", "wv"}


def syncsafe(b: bytes) -> int:
    return (b[0] << 21) | (b[1] << 14) | (b[2] << 7) | b[3]


def read_probe(path: str, want: int = 65536):
    """返回 (头 16 字节, 跳过 ID3 后的音频头, 跳过长度, 是否 ID3)"""
    with open(path, "rb") as fh:
        raw = fh.read(16)
        skip = 0
        if raw[:3] == b"ID3" and len(raw) >= 10:
            skip = 10 + syncsafe(raw[6:10])
            if raw[5] & 0x10:
                skip += 10
            fh.seek(skip)
            head = fh.read(want)
        else:
            fh.seek(0)
            head = fh.read(want)
    return raw, head, skip, skip > 0


def flac_info(buf: bytes):
    """返回 (sample_rate, channels, bits, total_samples) 或 None"""
    if buf[:4] != b"fLaC" or len(buf) < 4 + 4 + 34:
        return None
    p = 4
    for _ in range(16):
        if p + 4 > len(buf):
            return None
        head = buf[p]
        btype = head & 0x7F
        length = int.from_bytes(buf[p + 1:p + 4], "big")
        p += 4
        if btype == 0:  # STREAMINFO
            if p + 34 > len(buf):
                return None
            s = buf[p:p + 34]
            bits = int.from_bytes(s[10:18], "big")
            rate = (bits >> 44) & 0xFFFFF
            chans = ((bits >> 41) & 0x7) + 1
            bps = ((bits >> 36) & 0x1F) + 1
            total = bits & 0xFFFFFFFFF
            return rate, chans, bps, total
        p += length
    return None


BR_TAB = {
    3: {1: [0, 32, 64, 96, 128, 160, 192, 224, 256, 288, 320, 352, 384, 416, 448]},
    2: {1: [0, 32, 48, 56, 64, 80, 96, 112, 128, 160, 192, 224, 256, 320, 384]},
    1: {3: [0, 32, 40, 48, 56, 64, 80, 96, 112, 128, 160, 192, 224, 256, 320],
        2: [0, 32, 48, 56, 64, 80, 96, 112, 128, 160, 192, 224, 256, 320, 384],
        1: [0, 32, 64, 96, 128, 160, 192, 224, 256, 288, 320, 352, 384, 416, 448]},
}
SR_TAB = {3: [44100, 48000, 32000], 2: [22050, 24000, 16000], 0: [11025, 12000, 8000]}
BR_TAB[0] = BR_TAB[2]  # MPEG 2.5 用 MPEG2 的码率表


def mp3_first_frame(buf: bytes, strict: bool = True):
    """找第一个 MPEG 帧头 → (bitrate_kbps, sample_rate, samples_per_frame, version, layer)

    strict=True 时要求「下一帧的同步头也落在算出来的帧长上」——否则 PNG/zip 里的
    0xFFEx 会被误判成 mp3（误判过一次，别省这一步）。
    """
    i, n = 0, len(buf)
    while i + 4 <= n:
        if buf[i] == 0xFF and (buf[i + 1] & 0xE0) == 0xE0:
            b1, b2, b3 = buf[i + 1], buf[i + 2], buf[i + 3]
            ver = (b1 >> 3) & 0x3
            layer = (b1 >> 1) & 0x3
            br_i = (b2 >> 4) & 0xF
            sr_i = (b2 >> 2) & 0x3
            if ver != 1 and layer != 0 and br_i not in (0, 0xF) and sr_i != 3:
                sr = SR_TAB[ver][sr_i]
                table = BR_TAB[ver].get(layer)
                if table:
                    br = table[br_i]
                    if ver == 3:
                        spf = 1152 if layer in (1, 2) else 384
                        flen = (144 * br * 1000 // sr) + ((b3 >> 1) & 1) if layer == 1 else (
                            144 * br * 1000 // sr + ((b3 >> 1) & 1))
                    else:
                        spf = 576 if layer == 1 else 1152
                        flen = 72 * br * 1000 // sr + ((b3 >> 1) & 1)
                    if not strict:
                        return br, sr, spf, ver, layer
                    nxt = i + max(flen, 4)
                    if nxt + 1 >= n or (buf[nxt] == 0xFF and (buf[nxt + 1] & 0xE0) == 0xE0):
                        return br, sr, spf, ver, layer
        i += 1
    return None


def mp4_duration(buf: bytes):
    if buf[4:8] != b"ftyp":
        return None, None
    brand = buf[8:12].decode("latin1", "replace")

    def mvhd_at(p):
        ver = buf[p]
        if ver == 0:
            ts = int.from_bytes(buf[p + 12:p + 16], "big")
            du = int.from_bytes(buf[p + 16:p + 20], "big")
        else:
            ts = int.from_bytes(buf[p + 20:p + 24], "big")
            du = int.from_bytes(buf[p + 24:p + 32], "big")
        return (du / ts) if ts else None

    i, n = 0, len(buf)
    while i + 8 <= n:
        size = int.from_bytes(buf[i:i + 4], "big")
        typ = buf[i + 4:i + 8]
        if size < 8:
            break
        if typ == b"mvhd":
            return mvhd_at(i + 8), brand
        if typ == b"moov":
            j, end = i + 8, min(n, i + size)
            while j + 8 <= end:
                s2 = int.from_bytes(buf[j:j + 4], "big")
                if s2 < 8:
                    break
                if buf[j + 4:j + 8] == b"mvhd":
                    return mvhd_at(j + 8), brand
                j += s2
            return None, brand
        i += size
    return None, brand


def wav_duration(buf: bytes):
    if buf[0:4] != b"RIFF" or buf[8:12] != b"WAVE":
        return None
    i, n = 12, len(buf)
    fmt = data = None
    while i + 8 <= n:
        cid = buf[i:i + 4]
        csize = int.from_bytes(buf[i + 4:i + 8], "little")
        if cid == b"fmt ":
            rate = int.from_bytes(buf[i + 12:i + 16], "little")
            align = int.from_bytes(buf[i + 20:i + 22], "little")
            fmt = (rate, align)
        elif cid == b"data":
            data = csize
            break
        i += 8 + csize + (csize & 1)
    if not fmt or not data or not fmt[0] or not fmt[1]:
        return None
    return data / (fmt[0] * fmt[1])


NON_AUDIO_MAGIC = (
    b"PK\x03\x04", b"PK\x05\x06", b"Rar!", b"7z\xbc\xaf", b"%PDF", b"\x1f\x8b",
    b"\x89PNG", b"GIF8", b"\xff\xd8\xff", b"woff", b"wOFF",
)


def sniff(head: bytes):
    if head[:8] == b"CTENFDAM":
        return "ncm(网易云加密)"
    for mg in NON_AUDIO_MAGIC:
        if head.startswith(mg):
            return None
    if head[:4] == b"fLaC":
        return "flac"
    if head[:4] == b"OggS":
        return "ogg"
    if head[:3] == b"MAC":
        return "ape"
    if head[0:4] == b"RIFF" and head[8:12] == b"WAVE":
        return "wav"
    if head[0:4] == b"FORM" and head[8:12] in (b"AIFF", b"AIFC"):
        return "aiff"
    if head[4:8] == b"ftyp":
        return "mp4"
    if head[0:4] == b"DSD ":
        return "dsf"
    if head[0:4] == b"fLaC":
        return "flac"
    if mp3_first_frame(head):
        return "mp3"
    return None


def audit_one(path: str):
    ext = os.path.splitext(path)[1].lower().lstrip(".")
    try:
        size = os.path.getsize(path)
    except OSError as e:
        return {"ext": ext, "size": -1, "container": "", "dur": 0, "verdict": "读不到文件", "detail": str(e)}
    try:
        raw, head, skip, had_id3 = read_probe(path)
    except OSError as e:
        return {"ext": ext, "size": size, "container": "", "dur": 0, "verdict": "读不到文件", "detail": str(e)}

    if size == 0:
        return {"ext": ext, "size": 0, "container": "", "dur": 0, "verdict": "0 字节", "detail": "空文件"}
    if ext in NO_DECODER:
        return {"ext": ext, "size": size, "container": ext, "dur": 0, "verdict": "iOS 无解码器", "detail": ""}

    cont = sniff(head)
    dur, detail = 0.0, ""
    if had_id3:
        detail = f"ID3 头 {skip}B"

    if cont == "flac":
        info = flac_info(head)
        if info:
            rate, chans, bps, total = info
            dur = (total / rate) if rate else 0
            detail = f"{rate}Hz/{bps}bit/{chans}ch" + (" total_samples=0(没写完?)" if total == 0 else "")
        else:
            detail = "有 fLaC 魔数但读不到 STREAMINFO"
    elif cont == "mp3":
        f = mp3_first_frame(head)
        if f:
            br, sr, spf, ver, layer = f
            audio = max(0, size - skip)
            if br:
                dur = audio * 8 / (br * 1000)
            vname = {3: "1", 2: "2", 0: "2.5"}[ver]
            lname = {1: "3", 2: "2", 3: "1"}[layer]
            detail = f"{br}kbps/{sr}Hz/V{vname}L{lname}"
    elif cont == "mp4":
        d, brand = mp4_duration(head)
        dur = d or 0
        detail = f"brand={brand}"
    elif cont == "wav":
        dur = wav_duration(head) or 0
        detail = "RIFF/WAVE"
    elif cont == "aiff":
        detail = "FORM/AIFF"
        dur = 0
    elif cont in ("ogg", "ape", "dsf", "ncm(网易云加密)"):
        return {"ext": ext, "size": size, "container": cont, "dur": 0,
                "verdict": "iOS 无解码器/加密包", "detail": cont}
    else:
        detail = "头 16 字节: " + raw.hex(" ")

    if ext not in PLAYABLE:
        if cont in ("flac", "mp3", "mp4", "wav", "aiff"):
            verdict = "改了名的音频（App 会按嗅探导入）"
        else:
            verdict = "不支持（认不出容器）"
    elif not cont:
        verdict = "读取失败·容器认不出（可能加密/改名/没下载完）"
    elif cont == "aiff":
        verdict = "OK(容器合法)"
    elif dur > 0:
        verdict = "OK"
    else:
        verdict = "读取失败·读不出时长"
    return {"ext": ext, "size": size, "container": cont, "dur": round(dur, 1) if dur else 0,
            "verdict": verdict, "detail": detail}


def human(n: float) -> str:
    for unit in ("B", "KB", "MB", "GB"):
        if n < 1024 or unit == "GB":
            return f"{n:.2f} {unit}" if unit in ("MB", "GB") else f"{int(n)} {unit}"
        n /= 1024
    return f"{n:.2f} GB"


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("root")
    ap.add_argument("--csv", default="")
    ap.add_argument("--limit", type=int, default=0)
    ap.add_argument("--all", action="store_true", help="连非音频文件一起统计（默认只统计音频/疑似音频）")
    a = ap.parse_args()

    files = []
    for dirpath, dirnames, filenames in os.walk(a.root):
        dirnames[:] = [d for d in dirnames if not d.startswith(".")]
        for f in filenames:
            files.append(os.path.join(dirpath, f))
    files.sort()
    if a.limit:
        files = files[:a.limit]
    if not files:
        print("这个目录里没有文件:", a.root)
        return 1

    rows, skipped = [], 0
    by_verdict, by_ext = Counter(), defaultdict(Counter)
    ok_bytes = 0
    for p in files:
        r = audit_one(p)
        r["path"] = p
        if not a.all and r["verdict"] == "不支持（认不出容器）":
            skipped += 1
            continue
        rows.append(r)
        by_verdict[r["verdict"]] += 1
        by_ext[r["ext"]][r["verdict"]] += 1
        if r["verdict"].startswith("OK"):
            ok_bytes += max(0, r["size"])

    print(f"扫描 {len(files)} 个文件，其中按音频/疑似音频统计 {len(rows)} 个"
          f"（{human(sum(max(0, r['size']) for r in rows))}）"
          + (f"，跳过非音频 {skipped} 个" if skipped else ""))
    print(f"判定可导入合计 {human(ok_bytes)}\n")
    print("== 按判定 ==")
    for k, v in by_verdict.most_common():
        print(f"{v:6d}  {k}")
    print("\n== 按扩展名 × 判定 ==")
    for ext in sorted(by_ext, key=lambda e: -sum(by_ext[e].values())):
        parts = ", ".join(f"{k} {v}" for k, v in by_ext[ext].most_common())
        print(f"{ext or '(无扩展名)':12s} {parts}")
    print("\n== 不能导入的样本（前 15 个）==")
    bad = [r for r in rows if not r["verdict"].startswith("OK")]
    for r in bad[:15]:
        print(f"  {r['verdict']:36s} {r['size']:>10d}B  {r['container']:6s} "
              f"{os.path.basename(r['path'])[:52]}  {r['detail'][:36]}")
    if len(bad) > 15:
        print(f"  …（还有 {len(bad)-15} 个）")

    if a.csv:
        with open(a.csv, "w", newline="", encoding="utf-8-sig") as fh:
            w = csv.DictWriter(fh, fieldnames=["path", "ext", "size", "container", "dur", "verdict", "detail"])
            w.writeheader()
            for r in rows:
                w.writerow({k: r[k] for k in w.fieldnames})
        print("\n逐文件明细 →", a.csv)
    return 0


if __name__ == "__main__":
    sys.exit(main())
