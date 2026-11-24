# -*- coding: utf-8 -*-
"""拿真实文件验"拖到 X% 是不是那一段"：两种 seek 方式取同一时刻，比对字节。"""
import hashlib
import subprocess
import sys

import imageio_ffmpeg

exe = imageio_ffmpeg.get_ffmpeg_exe()
p = sys.argv[1]
dur = float(sys.argv[2]) if len(sys.argv) > 2 else 252.133

print(f'文件：{p}')
print(f'按文件头锁定总长：{dur:.3f}s = {int(dur)//60}:{int(dur)%60:02d}')
print()
hashes = {}
for frac in (0.0, 0.25, 0.5, 0.75, 0.99):
    t = dur * frac
    a = subprocess.run([exe, '-v', 'error', '-ss', f'{t:.3f}', '-i', p,
                        '-t', '2', '-f', 's16le', '-ac', '2', '-'], capture_output=True).stdout
    b = subprocess.run([exe, '-v', 'error', '-i', p, '-ss', f'{t:.3f}',
                        '-t', '2', '-f', 's16le', '-ac', '2', '-'], capture_output=True).stdout
    ha, hb = hashlib.md5(a).hexdigest()[:10], hashlib.md5(b).hexdigest()[:10]
    c = subprocess.run([exe, '-v', 'error', '-ss', f'{t:.3f}', '-i', p,
                        '-t', '1', '-f', 's16le', '-ac', '1', '-'], capture_output=True).stdout
    hashes[frac] = hashlib.md5(c).hexdigest()[:10]
    same = '一致' if ha == hb else '不一致'
    print(f'{frac:5.0%} → {t:7.3f}s  精确 {len(a):,}B/{ha}  快速 {len(b):,}B/{hb}  {same}')

print()
vals = list(hashes.values())
print('五个落点的内容指纹：', ' '.join(f'{k:.0%}={v}' for k, v in hashes.items()))
print('互不相同：', len(set(vals)) == len(vals))
