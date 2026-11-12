# -*- coding: utf-8 -*-
"""读取 mp4 tkhd 变换矩阵，判断录制是否有 90 度旋转标记。"""
import struct
import sys

p = sys.argv[1]
data = open(p, "rb").read()
idx = data.find(b"tkhd")
while idx != -1:
    ver = data[idx + 5]
    # version0: 4+4+4+4+4+... 直接定位到矩阵：v0 位于 box 内容
    body = idx + 4
    if ver == 0:
        off = body + 1 + 3 + 4 + 4 + 4 + 4 + 4 * 2  # flags+ct+mt+trackid+reserved+duration+...
    print("ver", ver)
    break
# 用更稳的办法：矩阵固定位于 tkhd 末尾 36 字节之前
m_start = idx + 4 + 84
m = struct.unpack(">9i", data[m_start:m_start + 36])
print("matrix raw:", m)
print("display: a=%.3f b=%.3f c=%.3f d=%.3f" % (m[0] / 65536.0, m[1] / 65536.0, m[3] / 65536.0, m[4] / 65536.0))
