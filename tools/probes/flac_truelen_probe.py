# -*- coding: utf-8 -*-
"""FLAC 真实时长的"扫帧"算法原型（Python 先验，验完再移植到 Swift）。

真相来自字节：不信任 STREAMINFO 的 total_samples，而是找到**最后一个合法帧头**，
用帧头里的「帧号/样本号 + 本帧块大小」算出总样本数。

合法帧头 = 同步码 + 阻塞策略 + 块大小码 + 采样率码 + 声道/位深 + UTF-8 帧号/样本号
           + 可选块大小 + 可选采样率 + 头 CRC-8（对头所有字节校验）。

用法：python tools/probes/flac_truelen_probe.py <file.flac> [more.flac]
"""
import sys

BLOCKSIZE_TABLE = {
    1: 192, 2: 576, 3: 1152, 4: 2304, 5: 4608,
    8: 256, 9: 512, 10: 1024, 11: 2048, 12: 4096, 13: 8192, 14: 16384, 15: 32768,
}
SAMPLE_RATE_TABLE = {
    1: 88200, 2: 176400, 3: 192000, 4: 8000, 5: 16000, 6: 22050,
    7: 24000, 8: 32000, 9: 44100, 10: 48000, 11: 96000,
}


def crc8_table():
    t = []
    for i in range(256):
        c = i
        for _ in range(8):
            c = ((c << 1) ^ 0x07) & 0xFF if c & 0x80 else (c << 1) & 0xFF
        t.append(c)
    return t


CRC8 = crc8_table()


def crc8(data, start, end):
    c = 0
    for i in range(start, end):
        c = CRC8[c ^ data[i]]
    return c


def streaminfo(data):
    """→ (sample_rate, declared_total_samples, min_blocksize, max_blocksize) or None"""
    if data[:4] != b'fLaC':
        return None
    pos = 4
    n = len(data)
    while pos + 4 <= n:
        hdr = data[pos]
        last = hdr & 0x80
        btype = hdr & 0x7F
        length = int.from_bytes(data[pos + 1:pos + 4], 'big')
        body = data[pos + 4:pos + 4 + length]
        if btype == 0 and len(body) >= 18:
            b = body
            rate = (b[10] << 12) | (b[11] << 4) | (b[12] >> 4)
            total = ((b[13] & 0x0F) << 32) | (b[14] << 24) | (b[15] << 16) | (b[16] << 8) | b[17]
            minbs = (b[0] << 8) | b[1]
            maxbs = (b[2] << 8) | b[3]
            return rate, total, minbs, maxbs
        if last:
            break
        pos += 4 + length
    return None


def parse_header(data, i, n):
    """在 i 处试解析一个 FLAC 帧头。→ (header_len, sample_rate, blocksize, start_sample, variable) or None"""
    if i + 6 > n:
        return None
    if data[i] != 0xFF or (data[i + 1] & 0xFE) != 0xF8:
        return None
    variable = bool(data[i + 1] & 0x01)
    bsc = data[i + 2] >> 4
    src = data[i + 2] & 0x0F
    j = i + 4
    # UTF-8 编码的帧号/样本号
    b0 = data[j]
    if b0 < 0x80:
        extra = 0
    elif b0 & 0xE0 == 0xC0:
        extra = 1
    elif b0 & 0xF0 == 0xE0:
        extra = 2
    elif b0 & 0xF8 == 0xF0:
        extra = 3
    elif b0 & 0xFC == 0xF8:
        extra = 4
    elif b0 & 0xFE == 0xFC:
        extra = 5
    elif b0 == 0xFE:
        extra = 6
    else:
        return None
    if extra == 0:
        num = b0
    else:
        num = b0 & (0x3F >> extra)
        for k in range(1, extra + 1):
            if j + k >= n or (data[j + k] & 0xC0) != 0x80:
                return None
            num = (num << 6) | (data[j + k] & 0x3F)
    j += 1 + extra
    if j + 1 > n:
        return None
    # 块大小
    if bsc == 0:
        return None  # 保留
    if bsc == 6:
        bs = data[j] + 1
        j += 1
    elif bsc == 7:
        bs = int.from_bytes(data[j:j + 2], 'big') + 1
        j += 2
    else:
        bs = BLOCKSIZE_TABLE.get(bsc)
        if bs is None:
            return None
    # 采样率
    rate = None
    if src == 12:
        if j >= n:
            return None
        rate = data[j] * 1000
        j += 1
    elif src == 13:
        rate = int.from_bytes(data[j:j + 2], 'big')
        j += 2
    elif src == 14:
        rate = int.from_bytes(data[j:j + 2], 'big') * 10
        j += 2
    elif src in SAMPLE_RATE_TABLE:
        rate = SAMPLE_RATE_TABLE[src]
    elif src == 0:
        rate = None
    else:
        return None
    if j >= n:
        return None
    if crc8(data, i, j) != data[j]:
        return None
    hdr_len = j - i + 1
    return hdr_len, rate, bs, num, variable


def true_samples(data):
    """扫全文件，找最后一个合法帧头 → 总样本数"""
    info = streaminfo(data)
    if not info:
        return None
    rate0, declared, minbs, maxbs = info
    n = len(data)
    i = 4
    # 跳过所有元数据块
    pos = 4
    while pos + 4 <= n:
        last = data[pos] & 0x80
        length = int.from_bytes(data[pos + 1:pos + 4], 'big')
        pos += 4 + length
        if last:
            break
    last_hdr = None
    frames = 0
    i = pos
    while i < n - 6:
        h = parse_header(data, i, n)
        if h:
            hdr_len, rate, bs, num, variable = h
            last_hdr = (i, hdr_len, rate, bs, num, variable)
            frames += 1
            i += hdr_len
            # 跳到下一个候选同步字（不逐字节暴力扫，快很多）
            k = i
            while True:
                k = data.find(b'\xff', k)
                if k < 0 or k >= n - 1:
                    k = n
                    break
                if data[k + 1] & 0xFE == 0xF8:
                    break
                k += 1
            i = k
        else:
            i += 1
    if last_hdr is None:
        return None
    i0, hdr_len, rate, bs, num, variable = last_hdr
    rate = rate or rate0
    if variable:
        total = num + bs
    else:
        total = num * bs + bs
    return dict(rate=rate, declared=declared, frames=frames, total=total,
                seconds=total / rate if rate else None,
                declared_seconds=(declared / rate0) if (rate0 and declared) else None)


def main():
    for p in sys.argv[1:]:
        data = open(p, 'rb').read()
        r = true_samples(data)
        print(f'--- {p}  {len(data)} B')
        if not r:
            print('   扫不出（不是 FLAC / 没有合法帧）')
            continue
        print(f'   帧数 {r["frames"]}  采样率 {r["rate"]}')
        print(f'   头里写的总样本 {r["declared"]} → {r["declared_seconds"]:.3f}s'
              if r["declared_seconds"] else '   头里没写总样本')
        print(f'   扫出来 {r["total"]} → {r["seconds"]:.3f}s')


if __name__ == '__main__':
    main()
