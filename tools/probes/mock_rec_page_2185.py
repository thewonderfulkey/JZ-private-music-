# -*- coding: utf-8 -*-
"""v2.1.85 识曲页预览：1080px = 360dp = 3px/dp
三态：① 结果（播放 + 其他版本按钮）② 结果 + 其他版本列表（原唱置顶标「原唱」）③ 最近识过 + 悬浮栏（84dp 让位）
另出一条进度条缓存段对比（0 / 40 / 70 / 100%）。
"""
from PIL import Image, ImageDraw, ImageFont

W, D = 1080, 2340
S = 3

INK = (46, 42, 36)
T2 = (92, 84, 70)
T3 = (116, 108, 96)
PAPER_TOP = (250, 248, 243)
PAPER_BOT = (241, 237, 226)
SURF = (253, 252, 249)
SURF2 = (239, 235, 225)
CINNABAR = (168, 62, 44)
FONT = r"C:\Users\17948\DoubaoWork\chats\2026-10-22\new-chat-1\JZMusicHelperAndroid\app\src\main\res\font\lxgw_wenkai_regular.ttf"


def f(dp):
    return ImageFont.truetype(FONT, int(dp * S))


def mix(a, b, alpha):
    return tuple(int(a[i] * alpha + b[i] * (1 - alpha)) for i in range(3))


def paper():
    img = Image.new("RGB", (W, D), PAPER_TOP)
    d = ImageDraw.Draw(img)
    for y in range(D):
        c = tuple(int(PAPER_TOP[i] + (PAPER_BOT[i] - PAPER_TOP[i]) * y / D) for i in range(3))
        d.line([(0, y), (W, y)], fill=c)
    return img, d


def draw_mic_icon(d, cx, cy, size, color):
    bw, bh = size * 0.34, size * 0.62
    d.rounded_rectangle([cx - bw / 2, cy - bh / 2 - size * 0.06, cx + bw / 2, cy + bh / 2 - size * 0.06],
                        radius=bw / 2, fill=color)
    r = size * 0.34
    d.arc([cx - r, cy - r + size * 0.10, cx + r, cy + r + size * 0.10], 0, 180, fill=color, width=int(size * 0.085))
    d.line([(cx, cy + r + size * 0.10), (cx, cy + size * 0.52)], fill=color, width=int(size * 0.085))
    d.line([(cx - size * 0.16, cy + size * 0.52), (cx + size * 0.16, cy + size * 0.52)], fill=color,
           width=int(size * 0.075))


def duration_button(d, pad, y, sec=10):
    h = 32 * S
    txt = "听 %d 秒" % sec
    tw = d.textlength(txt, font=f(11))
    aw = 5 * S
    wdt = 10 * S + tw + 5 * S + aw + 10 * S
    x1 = W - pad
    x0 = x1 - wdt
    d.rectangle([x0, y, x1, y + h], outline=mix(INK, PAPER_TOP, 0.24), width=1)
    d.text((x0 + 10 * S, y + h / 2 - 11 * S / 2 - 2), txt, font=f(11), fill=T2)
    # 下三角：直接画，别依赖字体里有 ▾ 这个字形
    ax = x0 + 10 * S + tw + 5 * S
    ay = y + h / 2 - 2 * S
    d.polygon([(ax, ay), (ax + aw, ay), (ax + aw / 2, ay + 3.5 * S)], fill=T3)


def button(d, x0, y, wdt, text, primary, h=44):
    x1 = x0 + wdt
    y1 = y + h * S
    if primary:
        d.rectangle([x0, y, x1, y1], fill=INK)
        col = SURF
    else:
        d.rectangle([x0, y, x1, y1], outline=mix(INK, PAPER_TOP, 0.28), width=1)
        col = T2
    tw = d.textlength(text, font=f(14))
    d.text((x0 + (wdt - tw) / 2, y + h * S / 2 - 14 * S / 2 - 1), text, font=f(14), fill=col)


def header(d, state_label=None):
    pad = 22 * S
    y = 60
    d.text((pad, y), "听歌识曲", font=f(23), fill=INK)
    duration_button(d, pad, y + 23 * S / 2 - 16 * S)
    ly = y + 23 * S + 7 * S
    d.line([(pad, ly), (W - pad, ly)], fill=mix(INK, PAPER_TOP, 0.13), width=1)
    stage_top = ly + 10 * S
    cy = stage_top + 108 * S
    cx = W / 2
    base = 54 * S
    for i in range(3):
        r = base * (1 + i * 0.42)
        d.ellipse([cx - r, cy - r, cx + r, cy + r], outline=mix(INK, PAPER_TOP, 0.17 - i * 0.045), width=1 + i)
    disc = 64 * S
    d.ellipse([cx - disc, cy - disc, cx + disc, cy + disc], fill=mix(INK, PAPER_TOP, 0.035))
    d.ellipse([cx - disc, cy - disc, cx + disc, cy + disc], outline=mix(INK, PAPER_TOP, 0.22), width=1)
    draw_mic_icon(d, cx, cy, 48 * S, mix(INK, PAPER_TOP, 0.86))
    ty = stage_top + 214 * S
    d.text((cx - d.textlength("点一下麦克风，开始听", font=f(13)) / 2, ty), "点一下麦克风，开始听",
           font=f(13), fill=T2)
    return pad, ty + 13 * S + 8 * S


def card(d, pad, y, title, sub):
    h = 16 * S + 27 * S * 1.15 + 6 * S + 12.5 * S + 14 * S
    d.rectangle([pad, y, W - pad, y + h], fill=SURF, outline=mix(INK, PAPER_TOP, 0.16), width=1)
    d.text((pad + 18 * S, y + 16 * S), title, font=f(27), fill=INK)
    d.text((pad + 18 * S, y + 16 * S + 31 * S), sub, font=f(12.5), fill=T2)
    return y + h


def section(d, pad, y, text):
    d.text((pad, y), text, font=f(11), fill=T3)
    return y + 11 * S + 4 * S


def row(d, pad, y, title, right, badge=None, right_col=None):
    tw = d.textlength(title, font=f(14))
    d.text((pad, y + 8 * S), title, font=f(14), fill=INK)
    if badge:
        bw = d.textlength(badge, font=f(9.5)) + 6 * S
        bx = pad + tw + 8 * S
        d.rectangle([bx, y + 9 * S, bx + bw, y + 9 * S + 9.5 * S + 4], outline=mix(CINNABAR, SURF, 0.55), width=1)
        d.text((bx + 3 * S, y + 9 * S + 1), badge, font=f(9.5), fill=CINNABAR)
    rw = d.textlength(right, font=f(11.5))
    d.text((W - pad - rw, y + 10 * S), right, font=f(11.5), fill=right_col or T3)
    rh = 14 * S + 11.5 * S + 10 * S
    d.line([(pad, y + rh), (W - pad, y + rh)], fill=mix(INK, PAPER_TOP, 0.08), width=1)
    return y + rh


def nav(d, active="识曲"):
    nav_h = 70 * S
    nav_top = D - nav_h
    d.rectangle([0, nav_top, W, D], fill=mix(PAPER_BOT, PAPER_TOP, 0.6))
    d.line([(0, nav_top), (W, nav_top)], fill=mix(INK, PAPER_TOP, 0.10), width=1)
    tabs = ["首页", "识曲", "收藏", "下载", "历史", "设置"]
    colw = W / len(tabs)
    for i, name in enumerate(tabs):
        cx0 = colw * i + colw / 2
        act = name == active
        ico_y = nav_top + 22 * S
        r = 7 * S
        if act:
            sq = 22 * S
            d.rectangle([cx0 - sq / 2, ico_y - sq / 2, cx0 + sq / 2, ico_y + sq / 2], fill=INK)
        d.ellipse([cx0 - r, ico_y - r, cx0 + r, ico_y + r], fill=SURF if act else mix(INK, PAPER_TOP, 0.28))
        if act:
            d.ellipse([cx0 + 8 * S, ico_y - 12 * S, cx0 + 12 * S, ico_y - 8 * S], fill=CINNABAR)
        d.text((cx0 - d.textlength(name, font=f(11)) / 2, nav_top + 42 * S), name, font=f(11),
               fill=INK if act else T3)


def miniplayer(d):
    """悬浮栏：宽/5 = 72dp 高，底边贴在底栏上沿（BOTTOM_BAR_HEIGHT=70dp）"""
    h = 72 * S
    nav_top = D - 70 * S
    top = nav_top - h
    d.rectangle([0, top, W, nav_top], fill=mix(SURF, PAPER_TOP, 0.94))
    d.line([(0, top), (W, top)], fill=mix(INK, PAPER_TOP, 0.12), width=1)
    pad = 22 * S
    d.text((pad, top + 14 * S), "IVORY TOWER", font=f(14), fill=INK)
    d.text((pad, top + 36 * S), "澤野弘之", font=f(10.5), fill=T3)
    # 右侧三钮：上一首 / 播放 / 下一首（墨线圆 + 小三角/墨块）
    r = 15 * S
    cy = top + h / 2
    xs = [W - pad - 2 * r, W - pad - 2 * r - 54 * S, W - pad - 2 * r - 108 * S]
    for i, x in enumerate(xs):
        d.ellipse([x - r, cy - r, x + r, cy + r], outline=mix(INK, PAPER_TOP, 0.30), width=1)
        if i == 1:   # 播放：实心三角
            d.polygon([(x - r * 0.30, cy - r * 0.52), (x - r * 0.30, cy + r * 0.52), (x + r * 0.58, cy)], fill=INK)
        else:        # 上/下一首：墨块 + 竖线
            s = 1 if i == 0 else -1
            d.polygon([(x - s * r * 0.30, cy - r * 0.45), (x - s * r * 0.30, cy + r * 0.45),
                       (x + s * r * 0.42, cy)], fill=INK)
            lx = x + s * r * 0.52
            d.line([(lx, cy - r * 0.45), (lx, cy + r * 0.45)], fill=INK, width=max(1, int(1.5 * S)))
    return top


def page_result(show_versions=False):
    img, d = paper()
    pad, y = header(d)
    y = card(d, pad, y, "IVORY TOWER", "澤野弘之、SennaRin、龙族 动画OST")
    y += 12 * S
    bw = (W - 2 * pad - 10 * S) / 2
    button(d, pad, y, bw, "再听一次", False)
    button(d, pad + bw + 10 * S, y, bw, "播放", True)
    y += 44 * S + 10 * S
    n = 4 if show_versions else 0
    button(d, pad, y, W - 2 * pad, ("其他版本（%d）" % n) if show_versions else "其他版本", False)
    y += 44 * S + 16 * S
    if show_versions:
        y = section(d, pad, y, "其他版本")
        rows = [("IVORY TOWER", "澤野弘之 · QQ", "原唱"), ("IVORY TOWER", "池年 · 酷我", None),
                ("IVORY TOWER", "SennaRin · 网易云", None), ("IVORY TOWER", "Blackmore' · QQ", None)]
        for t, s, b in rows:
            y = row(d, pad, y, t, s, b)
    else:
        y = section(d, pad, y, "同批候选")
        y = row(d, pad, y, "IVORY TOWER", "池年")
    d.text((pad, D - 104 * S), "10 秒采样只用于曲库比对，本机不留存", font=f(10.5), fill=mix(T3, PAPER_BOT, 0.85))
    nav(d)
    return img


def page_recent():
    img, d = paper()
    pad, y = header(d)
    d.text((pad, y), "最近识过", font=f(11), fill=T3)
    hint = "点一条直接播放"
    d.text((W - pad - d.textlength(hint, font=f(10.5)), y), hint, font=f(10.5), fill=mix(T3, PAPER_BOT, 0.85))
    y += 11 * S + 4 * S
    items = [("光之黎明", "黄霄雲"), ("诀爱", "Faye 詹雯婷、张远"), ("fuzzy wuzzy", "凯瑞"),
             ("Outlaws of Love", "Adam Lambert"), ("IVORY TOWER", "澤野弘之"),
             ("晴天", "周杰伦"), ("夜曲", "周杰伦"), ("稻香", "周杰伦"),
             ("手写的从前", "周杰伦"), ("有一种爱叫做放手", "阿木")]
    clip_bottom = D - 70 * S - 84 * S   # 内容区底部让位 84dp 之后的可视底边
    rh = 14 * S + 11.5 * S + 10 * S
    last_bottom = y
    for t, s in items:
        if y + rh > clip_bottom:
            break
        d.text((pad, y + 8 * S), t, font=f(14), fill=INK)
        sw = d.textlength(s, font=f(11.5))
        d.text((W - pad - sw, y + 10 * S), s, font=f(11.5), fill=T3)
        d.line([(pad, y + rh), (W - pad, y + rh)], fill=mix(INK, PAPER_TOP, 0.08), width=1)
        y += rh
        last_bottom = y
    nav(d)
    top = miniplayer(d)
    # 让位校验：最后一条底边必须落在悬浮栏上方（真实 Compose 里靠 84dp 底部 Spacer 顶起）
    assert last_bottom <= top, "最后一条被悬浮栏压住：%d > %d" % (last_bottom, top)
    return img, last_bottom, top


def strip():
    """播放页进度条：缓存段（淡墨带）随下载增长，0 / 40 / 70 / 100%"""
    img, d = paper()
    pad = 24 * S
    d.text((pad, 150), "播放进度条上的缓存段", font=f(18), fill=INK)
    d.text((pad, 236), "淡墨带＝这一首已缓存到本地的部分", font=f(11), fill=T3)
    d.text((pad, 284), "墨线＝已播放；朱砂点＝当前位置", font=f(11), fill=T3)
    played = 0.30
    for i, fr in enumerate([0.0, 0.4, 0.7, 1.0]):
        y = 440 + i * 450
        d.text((pad, y), "缓存 %d%%" % int(fr * 100), font=f(12), fill=T2)
        x0, x1 = pad, W - pad
        cy = y + 60
        d.line([(x0, cy), (x1, cy)], fill=(201, 194, 178), width=1)
        if fr > 0:
            d.rounded_rectangle([x0, cy - 7, x0 + (x1 - x0) * fr, cy + 7], radius=7,
                                fill=mix(INK, PAPER_TOP, 0.13))
        d.line([(x0, cy), (x0 + (x1 - x0) * played, cy)], fill=INK, width=3)
        px = x0 + (x1 - x0) * played
        r = 8
        d.ellipse([px - r, cy - r, px + r, cy + r], fill=CINNABAR)
        d.text((pad, cy + 34), "0:12", font=f(10.5), fill=T3)
        tot = "3:41"
        d.text((W - pad - d.textlength(tot, font=f(10.5)), cy + 30), tot, font=f(10.5), fill=T3)
    return img


imgs = {}
imgs["result"] = page_result(False)
imgs["versions"] = page_result(True)
imgs["recent"], lb, tp = page_recent()
imgs["strip"] = strip()

for k in ["result", "versions", "recent"]:
    imgs[k].save(r"C:\Users\17948\DoubaoWork\chats\2026-10-22\new-chat-1\_tmp_fb3\preview_2185_%s.jpg" % k, quality=92)
strip().save(r"C:\Users\17948\DoubaoWork\chats\2026-10-22\new-chat-1\_tmp_fb3\crop_2185_cache.jpg", quality=90)

gap = 24
sheet = Image.new("RGB", (W * 2 + gap, D * 2 + gap), (232, 228, 218))
order = ["result", "versions", "recent", "strip"]
for i, k in enumerate(order):
    sheet.paste(imgs[k], ((i % 2) * (W + gap), (i // 2) * (D + gap)))
sheet.save(r"C:\Users\17948\DoubaoWork\chats\2026-10-22\new-chat-1\_tmp_fb3\preview_2185_rec.jpg", quality=90)
print("ok sheet=%s  last_row_bottom=%d miniplayer_top=%d gap=%dpx(%.1fdp)" % (sheet.size, lb, tp, tp - lb, (tp - lb) / S))
