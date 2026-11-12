# -*- coding: utf-8 -*-
"""v2.1.73 版式数值核算：不跑模拟器，只按代码里的约束推一遍每台设备上各块拿到多少空间。"""

def phone(w, h):
    print(f"  版式=手机竖屏 列宽={min(w,500)} 画心=min(258, {w}-28, hcap)")

def tablet(w, h):
    col = min(w, 720) - 48
    # 固定高：顶栏 52(40 按钮 + 12 padding) / 提示 ~18 / 题名两行 96 / 歌手 24 / 进度 9+11+? ~46 / 状态 20 / 音源 16+6
    fixed = 52 + 18 + 96 + 24 + 46 + 20 + 22
    left = h - fixed
    weights = 3.30 + 0.05 + 0.03 + 0.05 + 0.04
    cover_box = left * 3.30 / weights
    art = min(col - 28, cover_box - 36)
    print(f"  版式=平板竖屏 列={col}dp 封面区={cover_box:.0f}dp 画心={art:.0f}dp 白框={art+28:.0f}dp "
          f"占屏宽={100*(art+28)/w:.0f}% 空隙={left - cover_box:.0f}dp")

def landscape(w, h):
    pw = w - 36 - 18
    lw = pw * 0.46
    rw = pw * 0.54
    side = min(lw, h - 12)
    art = side - 30
    print(f"  版式=横屏左右 左栏={lw:.0f}×{h-12}dp 封面={art:.0f}dp(框{art+28:.0f}) 右栏={rw:.0f}dp")

devices = [
    ("Pixel 手机竖屏 411×914dp", 411, 914),
    ("Pixel 手机横屏 914×411dp", 914, 411),
    ("iPad 竖屏 800×1280dp", 800, 1280),
    ("iPad 横屏 1280×800dp", 1280, 800),
    ("小屏手机 360×780dp", 360, 780),
    ("平板小竖 600×960dp", 600, 960),
]
for name, w, h in devices:
    print(name)
    if w > h:
        landscape(w, h)
    elif w >= 600:
        tablet(w, h)
    else:
        phone(w, h)
    print()
