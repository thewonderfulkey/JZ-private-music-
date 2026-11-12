# -*- coding: utf-8 -*-
"""v2.1.84 识曲页预览：按 RecognizePage() 实际排版绘制（1080px = 360dp = 3px/dp）
四态：① 初始（右上角改墨线按钮）② 时长弹卡展开 ③ 聆听中（取消提示）④ 最近识过（可点直接播）
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


def duration_button(d, pad, y, sec=10, open_=False, dim=False):
    """右上角墨线时长方钮：32dp 高，1px 边，右对齐到 pad"""
    h = 32 * S
    txt = "听 %d 秒" % sec
    arrow = "▴" if open_ else "▾"
    tw = d.textlength(txt, font=f(11))
    aw = d.textlength(arrow, font=f(9))
    w = 10 * S + tw + 5 * S + aw + 10 * S
    x1 = W - pad
    x0 = x1 - w
    a = 0.4 if dim else 1.0
    d.rectangle([x0, y, x1, y + h], outline=mix(INK, PAPER_TOP, 0.24 * a), width=1)
    d.text((x0 + 10 * S, y + h / 2 - 11 * S / 2 - 2), txt, font=f(11), fill=mix(T2, PAPER_TOP, a))
    d.text((x0 + 10 * S + tw + 5 * S, y + h / 2 - 9 * S / 2 - 3), arrow, font=f(9),
           fill=mix(T3, PAPER_TOP, a))
    return y + h


def duration_menu(d, pad, top, cur=10):
    """时长弹卡：124dp 宽，纸面 + 墨线，四档竖排"""
    w = 124 * S
    x1 = W - pad
    x0 = x1 - w
    rows = [5, 10, 15, 20]
    head_h = 9 * S + 10.5 * S + 5 * S
    row_h = 9 * S * 2 + 13 * S
    total = head_h + row_h * len(rows) + 3 * S
    d.rectangle([x0, top, x1, top + total], fill=SURF, outline=mix(INK, PAPER_TOP, 0.18), width=1)
    d.text((x0 + 12 * S, top + 9 * S), "听多久", font=f(10.5), fill=T3)
    y = top + head_h
    for s in rows:
        txt = "%d 秒" % s
        col = INK if s == cur else T2
        d.text((x0 + 12 * S, y + 9 * S), txt, font=f(13), fill=col)
        if s == cur:
            r = 2 * S
            cx = x1 - 12 * S - r
            d.ellipse([cx - r, y + 9 * S + 13 * S / 2 - r, cx + r, y + 9 * S + 13 * S / 2 + r], fill=CINNABAR)
        y += row_h
        d.line([(x0 + 12 * S, y), (x1 - 12 * S, y)], fill=mix(INK, PAPER_TOP, 0.10), width=1)
    return top + total


def page(state):
    """state: idle | menu | listening | recent"""
    img, d = paper()
    pad = 22 * S
    y = 60
    d.text((pad, y), "听歌识曲", font=f(23), fill=INK)
    # 按钮与「听歌识曲」基线对齐（Row 居中）
    btn_y = y + 23 * S / 2 - 32 * S / 2
    listening = state == "listening"
    duration_button(d, pad, btn_y, 10, open_=(state == "menu"), dim=listening)
    menu_top = btn_y + 36 * S   # Popup 叠在最上层，最后再画（否则会被墨圈盖住）

    ly = y + 23 * S + 7 * S
    d.line([(pad, ly), (W - pad, ly)], fill=mix(INK, PAPER_TOP, 0.13), width=1)

    stage_top = ly + 10 * S
    cy = stage_top + 126 * S
    cx = W / 2
    base = 62 * S
    for i in range(3):
        r = base * (0.92 if not listening else 1.10) * (1 + i * 0.44)
        a = (0.17 - i * 0.045) if not listening else (0.26 - i * 0.06)
        d.ellipse([cx - r, cy - r, cx + r, cy + r], outline=mix(INK, PAPER_TOP, a), width=1 + i)
    disc = 73 * S
    d.ellipse([cx - disc, cy - disc, cx + disc, cy + disc], fill=mix(INK, PAPER_TOP, 0.035))
    d.ellipse([cx - disc, cy - disc, cx + disc, cy + disc], outline=mix(INK, PAPER_TOP, 0.22), width=1)
    draw_mic_icon(d, cx, cy, 54 * S, mix(INK, PAPER_TOP, 0.86))

    ty = stage_top + 252 * S + 6
    if state in ("idle", "menu", "recent"):
        t1, fs, col = "点一下麦克风，开始听", 13, T2
        d.text((cx - d.textlength(t1, font=f(fs)) / 2, ty), t1, font=f(fs), fill=col)
        ty += 13 * S
    else:
        t1 = "正在聆听…"
        d.text((cx - d.textlength(t1, font=f(14)) / 2, ty), t1, font=f(14), fill=INK)
        ty += 14 * S + 3 * S
        t2 = "还能听 7 秒"
        d.text((cx - d.textlength(t2, font=f(11.5)) / 2, ty), t2, font=f(11.5), fill=T3)
        ty += 11.5 * S + 5 * S
        t3 = "再点一下麦克风，就取消这次识别"
        d.text((cx - d.textlength(t3, font=f(10.5)) / 2, ty), t3, font=f(10.5), fill=mix(T3, PAPER_TOP, 0.85))
        ty += 10.5 * S

    by = ty + 16 * S
    if state in ("idle", "menu", "listening"):
        d.text((pad, by), "第一次用？", font=f(17), fill=INK)
        by2 = by + 17 * S + 6 * S
        for line in ["把手机靠近正在外放的音箱，点上面的麦克风，", "听满 10 秒就会出结果。"]:
            d.text((pad, by2), line, font=f(12.5), fill=T2)
            by2 += 19 * S
        by3 = by2 + 16 * S
        d.text((pad, by3), "三件小事", font=f(11), fill=T3)
        by3 += 11 * S + 6 * S
        for tip in ["外放不用开满，能听清就行，太吵反而听不准。",
                    "离音箱一米内、中间别挡着，成功率最高。",
                    "地铁、街边这类环境噪音大的地方，换个安静点的地方再听。"]:
            d.text((pad, by3), "· " + tip, font=f(11.5), fill=T2)
            by3 += 18 * S + 4 * S
    else:
        # 最近识过：标题行 + 4 行记录（列表可滚，最多 50 条）
        d.text((pad, by), "最近识过", font=f(11), fill=T3)
        hint = "点一条直接播放"
        d.text((W - pad - d.textlength(hint, font=f(10.5)), by), hint, font=f(10.5),
               fill=mix(T3, PAPER_BOT, 0.85))
        ry = by + 11 * S + 4 * S
        items = [("晴天", "周杰伦"), ("有一种爱叫做放手", "阿木"), ("手写的从前", "周杰伦"),
                 ("夜曲", "周杰伦"), ("稻香", "周杰伦")]
        for title, singer in items:
            row_h = 14 * S + 11.5 * S + 10 * S
            d.text((pad, ry + 8 * S), title, font=f(14), fill=INK)
            sw = d.textlength(singer, font=f(11.5))
            d.text((W - pad - sw, ry + 10 * S), singer, font=f(11.5), fill=T3)
            d.line([(pad, ry + row_h), (W - pad, ry + row_h)], fill=mix(INK, PAPER_TOP, 0.08), width=1)
            ry += row_h

    foot = "10 秒采样只用于曲库比对，本机不留存"
    d.text((pad, D - 70 * S - 34 * S), foot, font=f(10.5), fill=mix(T3, PAPER_BOT, 0.85))

    # Popup 浮层：最后画，压在墨圈之上（真实界面里 Popup 是独立窗口）
    if state == "menu":
        duration_menu(d, pad, menu_top, 10)

    nav_h = 70 * S
    nav_top = D - nav_h
    d.rectangle([0, nav_top, W, D], fill=mix(PAPER_BOT, PAPER_TOP, 0.6))
    d.line([(0, nav_top), (W, nav_top)], fill=mix(INK, PAPER_TOP, 0.10), width=1)
    tabs = ["首页", "识曲", "收藏", "下载", "历史", "设置"]
    colw = W / len(tabs)
    for i, name in enumerate(tabs):
        cx0 = colw * i + colw / 2
        active = name == "识曲"
        ico_y = nav_top + 22 * S
        r = 7 * S
        if active:
            # 选中：墨印方块盖住 44dp 图标区，标签落回墨色（本轮修的「白字写白纸」）
            sq = 22 * S
            d.rectangle([cx0 - sq / 2, ico_y - sq / 2, cx0 + sq / 2, ico_y + sq / 2], fill=INK)
        d.ellipse([cx0 - r, ico_y - r, cx0 + r, ico_y + r],
                  fill=SURF if active else mix(INK, PAPER_TOP, 0.28))
        if active:
            d.ellipse([cx0 + 8 * S, ico_y - 12 * S, cx0 + 12 * S, ico_y - 8 * S], fill=CINNABAR)
        lab = name
        d.text((cx0 - d.textlength(lab, font=f(11)) / 2, nav_top + 42 * S), lab, font=f(11),
               fill=INK if active else T3)
    return img


states = [("idle", "初始态：右上角变墨线按钮"), ("menu", "点开：5/10/15/20 秒"), ("listening", "聆听中：再点即取消"), ("recent", "最近识过：点一条直接播")]
imgs = {k: page(k) for k, _ in states}

for k, _ in states:
    imgs[k].save(r"C:\Users\17948\DoubaoWork\chats\2026-10-22\new-chat-1\_tmp_fb3\preview_2184_%s.jpg" % k, quality=92)

gap = 24
sheet = Image.new("RGB", (W * 2 + gap, D * 2 + gap), (232, 228, 218))
order = ["idle", "menu", "listening", "recent"]
for i, k in enumerate(order):
    sheet.paste(imgs[k], ((i % 2) * (W + gap), (i // 2) * (D + gap)))
sheet.save(r"C:\Users\17948\DoubaoWork\chats\2026-10-22\new-chat-1\_tmp_fb3\preview_2184_rec.jpg", quality=90)
print("ok size=%s" % (sheet.size,))
