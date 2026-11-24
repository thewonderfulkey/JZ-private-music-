# -*- coding: utf-8 -*-
"""把一个 FLAC 挖到底：STREAMINFO 写了什么、元数据块有什么、最后一个帧在哪、
文件尾有没有标签/垃圾、解码出来到底多少样本。

用途：老板问"文件头到底错没错"。用这个给数字，不猜。

用法：python tools/probes/flac_dissect.py <file.flac>
"""
import os
import subprocess
import sys

BLOCK_NAMES = {0: 'STREAMINFO', 1: 'PADDING', 2: 'APPLICATION', 3: 'SEEKTABLE',
               4: 'VORBIS_COMMENT', 5: 'CUESHEET', 6: 'PICTURE'}


def dissect(path):
    size = os.path.getsize(path)
    with open(path, 'rb') as f:
        head = f.read(4)
        print(f'文件：{os.path.basename(path)}')
        print(f'大小：{size:,} B')
        print(f'开头四字节：{head!r}')
        if head != b'fLaC':
            print('  不是 fLaC 开头（可能前挂了 ID3 / 别的容器）')
            return
        pos = 4
        seen = []
        info = None
        while True:
            hdr = f.read(4)
            if len(hdr) < 4:
                break
            last = hdr[0] & 0x80
            btype = hdr[0] & 0x7F
            length = int.from_bytes(hdr[1:4], 'big')
            body = f.read(length)
            seen.append((BLOCK_NAMES.get(btype, f'TYPE{btype}'), length, pos))
            if btype == 0 and len(body) >= 34:
                minbs = int.from_bytes(body[0:2], 'big')
                maxbs = int.from_bytes(body[2:4], 'big')
                rate = (body[10] << 12) | (body[11] << 4) | (body[12] >> 4)
                ch = ((body[12] >> 1) & 0x7) + 1
                bps = (((body[12] & 0x1) << 4) | (body[13] >> 4)) + 1
                total = ((body[13] & 0x0F) << 32) | int.from_bytes(body[14:18], 'big')
                info = dict(rate=rate, ch=ch, bps=bps, total=total,
                            minbs=minbs, maxbs=maxbs, md5=body[18:34].hex())
            pos += 4 + length
            if last:
                break
        audio_start = pos
        print('\n元数据块：')
        for name, length, off in seen:
            print(f'  {name:<14} {length:>10,} B  @{off:,}')
        print(f'  音频数据从 @{audio_start:,} 开始')
        if not info:
            print('  没有 STREAMINFO')
            return audio_start, info
        print('\nSTREAMINFO：')
        print(f'  采样率 {info["rate"]} Hz · {info["ch"]} 声道 · {info["bps"]} bit')
        print(f'  min/max 块大小 {info["minbs"]} / {info["maxbs"]}')
        print(f'  total_samples = {info["total"]:,}')
        if info['rate']:
            print(f'  → 声明时长 = {info["total"] / info["rate"]:.3f} s'
                  f' = {int(info["total"] / info["rate"]) // 60}:'
                  f'{int(info["total"] / info["rate"]) % 60:02d}')
        print(f'  MD5 = {info["md5"]}')
        return audio_start, info


def tail_analysis(path, audio_start):
    """文件尾：最后一个合法 FLAC 帧之后还有没有别的东西"""
    size = os.path.getsize(path)
    with open(path, 'rb') as f:
        f.seek(size - 200)
        tail = f.read(200)
    print('\n文件尾 200 字节：')
    print(f'  十六进制尾部：{tail[-64:].hex()}')
    tags = []
    if tail[-128:-125] == b'TAG':
        tags.append('ID3v1（128 字节）')
    if b'APETAGEX' in tail:
        tags.append('APE tag')
    print(f'  检测到的尾部标签：{tags or "无"}')
    if tags:
        real_end = size - 128 if 'ID3v1（128 字节）' in tags else size
        print(f'  去掉标签后的音频字节数：{real_end - audio_start:,}')
    return tags


def decode_count(path):
    """用 ffmpeg 真解码，数出到底有多少样本（这是"码流里到底有多少音频"的硬证据）"""
    import imageio_ffmpeg
    exe = imageio_ffmpeg.get_ffmpeg_exe()
    raw = subprocess.run([exe, '-v', 'error', '-i', path, '-ac', '1', '-ar', '44100',
                          '-f', 's16le', '-'], capture_output=True).stdout
    samples = len(raw) // 2
    print('\n解码实测（ffmpeg，44100Hz 单声道重采样）：')
    print(f'  样本数 {samples:,} → {samples / 44100:.3f} s = '
          f'{int(samples / 44100) // 60}:{int(samples / 44100) % 60:02d}')
    return samples / 44100


def main():
    path = sys.argv[1]
    audio_start, info = dissect(path)
    tail_analysis(path, audio_start or 0)
    dur = decode_count(path)
    if info and info['rate']:
        declared = info['total'] / info['rate']
        print(f'\n结论：声明 {declared:.3f}s / 解码 {dur:.3f}s / 差 {dur - declared:+.3f}s')


if __name__ == '__main__':
    main()
