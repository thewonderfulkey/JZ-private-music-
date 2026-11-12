# -*- coding: utf-8 -*-
"""v2.1.86 识曲结果页预览：1080px = 360dp = 3px/dp
两态：① 结果纸签 + 墨块主操作 + 文字链（同批候选）② 同版式 + 其他版本列表（原唱朱砂细签 + 原唱印）
另出一张"上一版 vs 这一版"对照条，说明改了什么。
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


def text_h(dp):
    """单行行高按 1.32 倍字号估（与 Compose 默认 lineHeight 一致）"""
    return dp * S * 1.32


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
    ax = x0 + 10 * S + tw + 5 * S
    ay = y + h / 2 - 2 * S
    d.polygon([(ax, ay), (ax + aw, ay), (ax + aw / 2, ay + 3.5 * S)], fill=T3)


def header(d, phase_text="再点一下麦克风，可以重听", mic_scale=1.0):
    pad = 22 * S
    y = 60
    d.text((pad, y), "听歌识曲", font=f(23), fill=INK)
    duration_button(d, pad, y + 23 * S / 2 - 16 * S)
    ly = y + 23 * S + 7 * S
    d.line([(pad, ly), (W - pad, ly)], fill=mix(INK, PAPER_TOP, 0.13), width=1)
    stage_top = ly + 10 * S
    stage_h = 252 * S * mic_scale
    cy = stage_top + stage_h / 2 - 6 * S
    cx = W / 2
    base = 54 * S * mic_scale
    for i in range(3):
        r = base * (1 + i * 0.42)
        d.ellipse([cx - r, cy - r, cx + r, cy + r], outline=mix(INK, PAPER_TOP, 0.17 - i * 0.045), width=1 + i)
    disc = 64 * S * mic_scale
    d.ellipse([cx - disc, cy - disc, cx + disc, cy + disc], fill=mix(INK, PAPER_TOP, 0.035))
    d.ellipse([cx - disc, cy - disc, cx + disc, cy + disc], outline=mix(INK, PAPER_TOP, 0.22), width=1)
    draw_mic_icon(d, cx, cy, 48 * S * mic_scale, mix(INK, PAPER_TOP, 0.86))
    ty = stage_top + stage_h + 4 * S
    d.text((cx - d.textlength(phase_text, font=f(11.5)) / 2, ty), phase_text, font=f(11.5), fill=T3)
    return pad, ty + 11.5 * S * 1.32 + 10 * S


def seal(d, x, y, ch, size=19):
    """朱砂小印：方框 + 一个字"""
    d.rectangle([x, y, x + size * S, y + size * S], fill=mix(CINNABAR, SURF, 0.05),
                outline=mix(CINNABAR, SURF, 0.52), width=1)
    tw = d.textlength(ch, font=f(9))
    d.text((x + (size * S - tw) / 2, y + (size * S - 9 * S * 1.32) / 2 + 1), ch, font=f(9), fill=CINNABAR)


def result_card(d, pad, y, title, artists, album, seal_ch="识"):
    x0, x1 = pad, W - pad
    top = y
    inner = 18 * S
    cy = y + 14 * S
    # 眉标
    mark = "识 所 得"
    d.text((x0 + inner, cy), mark, font=f(10.5), fill=T3)
    rx = x0 + inner + d.textlength(mark, font=f(10.5)) + 8 * S
    d.line([(rx, cy + 10.5 * S * 0.55), (rx + 26 * S, cy + 10.5 * S * 0.55)], fill=mix(INK, SURF, 0.22), width=1)
    seal(d, x1 - inner - 19 * S, cy - 2 * S, seal_ch)
    cy += text_h(10.5) + 12 * S
    # 歌名
    d.text((x0 + inner, cy), title, font=f(28), fill=INK)
    cy += text_h(28) + 11 * S
    # 短墨线
    d.line([(x0 + inner, cy), (x0 + inner + 28 * S, cy)], fill=mix(INK, SURF, 0.30), width=1)
    cy += 10 * S
    # 歌手
    d.text((x0 + inner, cy), artists, font=f(13), fill=T2)
    cy += text_h(13) + 4 * S
    # 专辑
    if album:
        d.text((x0 + inner, cy), album, font=f(11), fill=T3)
        cy += text_h(11)
    bottom = cy + 16 * S
    d.rectangle([x0, top, x1, bottom], fill=SURF, outline=mix(INK, PAPER_TOP, 0.10), width=1)
    # 重画内容（底色盖住了先画的部分，这里整块重描）
    return top, bottom


def card(d, pad, y, title, artists, album, seal_ch="识"):
    """先算高度铺纸，再落字（避免一次性算错）"""
    x0, x1 = pad, W - pad
    inner = 16 * S
    h = (12 * S + text_h(10.5) + 10 * S + text_h(26) + 9 * S + 9 * S
         + text_h(13) + 3 * S + (text_h(11) if album else 0) + 12 * S)
    d.rectangle([x0, y, x1, y + h], fill=SURF, outline=mix(INK, PAPER_TOP, 0.10), width=1)
    cy = y + 12 * S
    mark = "识 所 得"
    d.text((x0 + inner, cy), mark, font=f(10.5), fill=T3)
    rx = x0 + inner + d.textlength(mark, font=f(10.5)) + 8 * S
    d.line([(rx, cy + 10.5 * S * 1.32 / 2), (rx + 26 * S, cy + 10.5 * S * 1.32 / 2)], fill=mix(INK, SURF, 0.22), width=1)
    seal(d, x1 - inner - 19 * S, cy, seal_ch)
    cy += text_h(10.5) + 10 * S
    d.text((x0 + inner, cy), title, font=f(26), fill=INK)
    cy += text_h(26) + 9 * S
    d.line([(x0 + inner, cy), (x0 + inner + 28 * S, cy)], fill=mix(INK, SURF, 0.30), width=1)
    cy += 9 * S
    d.text((x0 + inner, cy), artists, font=f(13), fill=T2)
    cy += text_h(13) + 3 * S
    if album:
        d.text((x0 + inner, cy), album, font=f(11), fill=T3)
    return y + h


def playbar(d, pad, y, label, enabled=True):
    h = 44 * S
    d.rectangle([pad, y, W - pad, y + h], fill=INK if enabled else mix(INK, PAPER_TOP, 0.42))
    tw = d.textlength(label, font=f(14.5))
    tri_w = 16 * S
    gap = 8 * S
    total = tri_w + gap + tw
    x = (W - total) / 2
    cy = y + h / 2
    col = SURF if enabled else mix(SURF, PAPER_TOP, 0.55)
    d.polygon([(x + tri_w * 0.15, cy - tri_w * 0.42), (x + tri_w * 0.15, cy + tri_w * 0.42),
               (x + tri_w * 0.95, cy)], fill=col)
    d.text((x + tri_w + gap, cy - 14.5 * S * 1.32 / 2 + 1), label, font=f(14.5), fill=col)
    return y + h


def textlink(d, cx, y, label, enabled=True):
    col = T2 if enabled else mix(T2, PAPER_TOP, 0.42)
    tw = d.textlength(label, font=f(12.5))
    d.text((cx - tw / 2, y), label, font=f(12.5), fill=col)
    return tw


def section_head(d, pad, y, label, count=None):
    lw = d.textlength(label, font=f(10.5))
    d.text((pad, y), label, font=f(10.5), fill=T3)
    x0 = pad + lw + 10 * S
    x1 = W - pad
    if count:
        cw = d.textlength(count, font=f(10))
        d.text((x1 - cw, y + 1), count, font=f(10), fill=mix(T3, PAPER_TOP, 0.75))
        x1 = x1 - cw - 10 * S
    d.line([(x0, y + 10.5 * S * 1.32 / 2), (x1, y + 10.5 * S * 1.32 / 2)], fill=mix(INK, PAPER_TOP, 0.12), width=1)
    return y + text_h(10.5) + 4 * S


def version_row_h():
    return 10 * S + text_h(14.5) + 4 * S + text_h(11) + 9 * S


def version_row(d, pad, y, name, meta, original=False):
    h = version_row_h()
    if original:
        d.rectangle([pad, y + 10 * S, pad + 2 * S, y + h - 10 * S], fill=mix(CINNABAR, SURF, 0.75))
    x = pad + 12 * S
    d.text((x, y + 10 * S), name, font=f(14.5), fill=INK)
    nw = d.textlength(name, font=f(14.5))
    if original:
        bx = x + nw + 7 * S
        bw = d.textlength("原唱", font=f(9)) + 6 * S
        d.rectangle([bx, y + 10 * S + 2, bx + bw, y + 10 * S + 2 + 9 * S * 1.32 + 2],
                    outline=mix(CINNABAR, SURF, 0.50), width=1)
        d.text((bx + 3 * S, y + 10 * S + 3), "原唱", font=f(9), fill=CINNABAR)
    my = y + 10 * S + text_h(14.5) + 4 * S
    d.text((x, my), meta, font=f(11), fill=T3)
    d.line([(pad, y + h), (W - pad, y + h)], fill=mix(INK, PAPER_TOP, 0.07), width=1)
    return y + h


def note_bar(d, pad, y, text):
    lines = text
    h = 38 * S
    d.rectangle([pad, y, pad + 2 * S, y + h], fill=mix(CINNABAR, SURF, 0.55))
    d.text((pad + 10 * S, y), lines, font=f(11.5), fill=T2)
    return y + 12 * S


def footer(d, pad, y, seconds=10):
    """页脚跟着内容走（滚动区末尾），不再固定贴底，避免和悬浮栏叠在一起"""
    t = "%d 秒采样只用于曲库比对，本机不留存" % seconds
    d.text((pad, y), t, font=f(10.5), fill=mix(T3, PAPER_BOT, 0.85))
    return y + text_h(10.5)


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
    h = 72 * S
    nav_top = D - 70 * S
    top = nav_top - h
    d.rectangle([0, top, W, nav_top], fill=mix(SURF, PAPER_TOP, 0.94))
    d.line([(0, top), (W, top)], fill=mix(INK, PAPER_TOP, 0.12), width=1)
    pad = 22 * S
    d.text((pad, top + 14 * S), "IVORY TOWER", font=f(14), fill=INK)
    d.text((pad, top + 36 * S), "澤野弘之", font=f(10.5), fill=T3)
    r = 15 * S
    cy = top + h / 2
    xs = [W - pad - 2 * r, W - pad - 2 * r - 54 * S, W - pad - 2 * r - 108 * S]
    for i, x in enumerate(xs):
        d.ellipse([x - r, cy - r, x + r, cy + r], outline=mix(INK, PAPER_TOP, 0.30), width=1)
        if i == 1:
            d.polygon([(x - r * 0.30, cy - r * 0.52), (x - r * 0.30, cy + r * 0.52), (x + r * 0.66, cy)], fill=INK)
        else:
            s = 1 if i == 0 else -1
            d.polygon([(x - s * r * 0.30, cy - r * 0.45), (x - s * r * 0.30, cy + r * 0.45),
                       (x + s * r * 0.42, cy)], fill=INK)
            lx = x + s * r * 0.52
            d.line([(lx, cy - r * 0.45), (lx, cy + r * 0.45)], fill=INK, width=max(1, int(1.5 * S)))
    return top


def page_result(show_versions=False, title="Chemistry",
                artists="Alistair Griffin、Brian Howes", album="《Albion Sky》"):
    img, d = paper()
    pad, y = header(d, mic_scale=0.72)   # 出结果后麦克风缩到 0.72，把上方空间还给结果
    y = card(d, pad, y, title, artists, album)
    y += 12 * S
    y = playbar(d, pad, y, "播放这首歌")
    y += 10 * S
    # 次级动作：文字链（居中）
    labels = ["再听一次", "其他版本 · 4 条"]
    widths = [d.textlength(t, font=f(12.5)) for t in labels]
    gap = 20 * S
    div_w = 1 * S
    total = widths[0] + gap + div_w + gap + widths[1]
    x = (W - total) / 2
    d.text((x, y), labels[0], font=f(12.5), fill=T2)
    dx = x + widths[0] + gap
    d.line([(dx, y + 3 * S), (dx, y + 12.5 * S * 1.32 + 1)], fill=mix(INK, PAPER_TOP, 0.18), width=1)
    d.text((dx + gap, y), labels[1], font=f(12.5), fill=T2)
    y += text_h(12.5) + 4 * S + 10 * S

    top_bar = miniplayer(d)
    if show_versions:
        y += 4 * S
        y = section_head(d, pad, y, "其他版本", "4 条")
        rows = [("IVORY TOWER", "澤野弘之 · QQ", True), ("IVORY TOWER", "池年 · 酷我", False),
                ("IVORY TOWER", "SennaRin · 网易云", False), ("IVORY TOWER", "Blackmore' · QQ", False)]
        for name, meta, orig in rows:
            if y + version_row_h() > top_bar:
                break
            y = version_row(d, pad, y, name, meta, orig)
    else:
        y += 4 * S
        y = section_head(d, pad, y, "同批候选")
        if y + version_row_h() <= top_bar:
            y = version_row(d, pad, y, "IVORY TOWER", "池年 · 酷我", False)
    if y + text_h(10.5) + 10 * S <= top_bar:
        footer(d, pad, y + 10 * S)
    nav(d)
    assert y <= top_bar + 2, "内容压到悬浮栏：%d > %d" % (y, top_bar)
    return img


def compare():
    """上一版 vs 这一版：同一屏宽，各自按真实比例排一遍"""
    H = 2400
    img = Image.new("RGB", (W, H), PAPER_TOP)
    d = ImageDraw.Draw(img)
    for yy in range(H):
        c = tuple(int(PAPER_TOP[i] + (PAPER_BOT[i] - PAPER_TOP[i]) * yy / H) for i in range(3))
        d.line([(0, yy), (W, yy)], fill=c)
    pad = 22 * S

    # ---------- 上一版（v2.1.85）：细框大标题 + 两块矩形 + 整宽细框 ----------
    d.text((pad, 56), "上一版（v2.1.85）", font=f(12.5), fill=T3)
    y = 110
    h = 16 * S + 27 * S * 1.32 + 6 * S + 12.5 * S * 1.32 + 14 * S
    d.rectangle([pad, y, W - pad, y + h], fill=SURF, outline=mix(INK, PAPER_TOP, 0.16), width=1)
    d.text((pad + 18 * S, y + 16 * S), "Chemistry", font=f(27), fill=INK)
    d.text((pad + 18 * S, y + 16 * S + 34 * S),
           "Alistair Griffin、Brian Howes · Albion Sky", font=f(12.5), fill=T2)
    y += h + 12 * S
    bw = (W - 2 * pad - 10 * S) / 2
    d.rectangle([pad, y, pad + bw, y + 44 * S], outline=mix(INK, PAPER_TOP, 0.28), width=1)
    d.text((pad + bw / 2 - d.textlength("再听一次", font=f(14)) / 2, y + 22 * S - 14 * S * 0.66),
           "再听一次", font=f(14), fill=T2)
    d.rectangle([pad + bw + 10 * S, y, W - pad, y + 44 * S], fill=INK)
    d.text((pad + bw + 10 * S + bw / 2 - d.textlength("播放", font=f(14)) / 2, y + 22 * S - 14 * S * 0.66),
           "播放", font=f(14), fill=SURF)
    y += 44 * S + 10 * S
    d.rectangle([pad, y, W - pad, y + 44 * S], outline=mix(INK, PAPER_TOP, 0.28), width=1)
    d.text((W / 2 - d.textlength("其他版本", font=f(14)) / 2, y + 22 * S - 14 * S * 0.66),
           "其他版本", font=f(14), fill=T2)
    y_old = y + 44 * S

    # ---------- 这一版（v2.1.86） ----------
    label_y = y_old + 46 * S
    d.text((pad, label_y), "这一版（v2.1.86）", font=f(12.5), fill=T3)
    y = label_y + 34 * S
    y = card(d, pad, y, "Chemistry", "Alistair Griffin、Brian Howes", "《Albion Sky》")
    y += 12 * S
    y = playbar(d, pad, y, "播放这首歌")
    y += 10 * S
    labels = ["再听一次", "其他版本 · 4 条"]
    widths = [d.textlength(t, font=f(12.5)) for t in labels]
    gap = 20 * S
    total = widths[0] + gap + 1 * S + gap + widths[1]
    x = (W - total) / 2
    d.text((x, y), labels[0], font=f(12.5), fill=T2)
    dx = x + widths[0] + gap
    d.line([(dx, y + 3 * S), (dx, y + 12.5 * S * 1.32 + 1)], fill=mix(INK, PAPER_TOP, 0.18), width=1)
    d.text((dx + gap, y), labels[1], font=f(12.5), fill=T2)
    y += text_h(12.5) + 4 * S + 14 * S
    y = section_head(d, pad, y, "其他版本", "4 条")
    y = version_row(d, pad, y, "IVORY TOWER", "澤野弘之 · QQ", True)
    y = version_row(d, pad, y, "IVORY TOWER", "池年 · 酷我", False)

    # ---------- 改动说明（放在所有内容之后，按实际 y 落笔） ----------
    notes = ["① 主结果：细框大标题改成方角纸签，眉标 / 朱砂印 / 短墨线断句，歌手与专辑分层",
             "② 唯一实心块只给「播放这首歌」，其余动作降为文字链，不再两块矩形并排",
             "③ 列表用「标签 + 贯通细线 + 条数」书页式小标题，原唱行加朱砂细签，行间只留发丝线"]
    ny = y + 36 * S
    maxw = W - 2 * pad
    size = 10.0
    while size > 7.0:
        if max(d.textlength(n, font=f(size)) for n in notes) <= maxw:
            break
        size -= 0.5
    for n in notes:
        d.text((pad, ny), n, font=f(size), fill=T3)
        ny += size * S * 1.7
    return img.crop((0, 0, W, int(ny + 26 * S)))


imgs = {}
imgs["result"] = page_result(False)
imgs["versions"] = page_result(True)
imgs["compare"] = compare()

for k in ["result", "versions"]:
    imgs[k].save(r"C:\Users\17948\DoubaoWork\chats\2026-10-22\new-chat-1\_tmp_fb3\preview_2186_%s.jpg" % k, quality=92)
imgs["compare"].save(r"C:\Users\17948\DoubaoWork\chats\2026-10-22\new-chat-1\_tmp_fb3\preview_2186_compare.jpg", quality=90)

gap = 24
cols = ["result", "versions"]
sheet = Image.new("RGB", (W * len(cols) + gap * (len(cols) - 1), D), (232, 228, 218))
for i, k in enumerate(cols):
    sheet.paste(imgs[k], (i * (W + gap), 0))
sheet.save(r"C:\Users\17948\DoubaoWork\chats\2026-10-22\new-chat-1\_tmp_fb3\preview_2186_rec.jpg", quality=90)
print("ok sheet=%s" % (sheet.size,))
