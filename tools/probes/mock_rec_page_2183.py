# -*- coding: utf-8 -*-
"""v2.1.83 识曲页预览：按 RecognizePage() 的实测排版（1080px = 360dp = 3px/dp）绘制纸墨界面"""
from PIL import Image, ImageDraw, ImageFont

W, D = 1080, 2340
S = 3  # px per dp

INK = (46, 42, 36)
T2 = (92, 84, 70)
T3 = (116, 108, 96)
PAPER_TOP = (250, 248, 243)
PAPER_BOT = (241, 237, 226)
SURF = (253, 252, 249)
SURF2 = (239, 235, 225)
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
    """Material Filled.Mic 的近似：胶囊 + 碗形弧 + 竖杆"""
    bw, bh = size * 0.34, size * 0.62
    d.rounded_rectangle([cx - bw / 2, cy - bh / 2 - size * 0.06, cx + bw / 2, cy + bh / 2 - size * 0.06],
                        radius=bw / 2, fill=color)
    r = size * 0.34
    d.arc([cx - r, cy - r + size * 0.10, cx + r, cy + r + size * 0.10], 0, 180, fill=color, width=int(size * 0.085))
    d.line([(cx, cy + r + size * 0.10), (cx, cy + size * 0.52)], fill=color, width=int(size * 0.085))
    d.line([(cx - size * 0.16, cy + size * 0.52), (cx + size * 0.16, cy + size * 0.52)], fill=color, width=int(size * 0.075))


def page(state):
    """state: 'idle' | 'result'"""
    img, d = paper()
    pad = 22 * S
    # ---- 题字行 ----
    y = 60
    d.text((pad, y), "听歌识曲", font=f(23), fill=INK)
    t = "听十秒"
    tw = d.textlength(t, font=f(11))
    d.text((W - pad - tw, y + 22), t, font=f(11), fill=T3)
    # ---- 发丝线 ----
    ly = y + 23 * S + 7 * S
    d.line([(pad, ly), (W - pad, ly)], fill=mix(INK, PAPER_TOP, 0.13), width=1)

    # ---- 麦克风舞台 252dp ----
    stage_top = ly + 10 * S
    cy = stage_top + 126 * S
    cx = W / 2
    base = 62 * S
    for i in range(3):
        r = base * (0.92 if state == "idle" else 1.10) * (1 + i * 0.44)
        a = 0.17 - i * 0.045
        d.ellipse([cx - r, cy - r, cx + r, cy + r], outline=mix(INK, PAPER_TOP, a), width=1 + i)
    disc = 73 * S
    d.ellipse([cx - disc, cy - disc, cx + disc, cy + disc], fill=mix(INK, PAPER_TOP, 0.035))
    d.ellipse([cx - disc, cy - disc, cx + disc, cy + disc], outline=mix(INK, PAPER_TOP, 0.22), width=1)
    draw_mic_icon(d, cx, cy, 54 * S, mix(INK, PAPER_TOP, 0.86))

    # ---- 阶段文案 ----
    ty = stage_top + 252 * S + 6
    t1 = "点一下麦克风，开始听" if state == "idle" else "再点一下麦克风，可以重听"
    fs = 13 if state == "idle" else 11.5
    col = T2 if state == "idle" else T3
    d.text((cx - d.textlength(t1, font=f(fs)) / 2, ty), t1, font=f(fs), fill=col)

    # ---- 内容区 ----
    by = ty + 13 * S + 16 * S
    if state == "idle":
        d.text((pad, by), "第一次用？", font=f(17), fill=INK)
        by2 = by + 17 * S + 6 * S
        for line in ["把手机靠近正在外放的音箱，点上面的麦克风，", "听满十秒就会出结果。"]:
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
        # 结果纸签
        ch = 16 * S + 27 * S + 6 * S + 12.5 * S + 14 * S
        d.rectangle([pad, by, W - pad, by + ch], fill=SURF, outline=mix(INK, PAPER_TOP, 0.16), width=1)
        d.text((pad + 18 * S, by + 16 * S), "晴天", font=f(27), fill=INK)
        meta = "周杰伦 · 叶惠美"
        d.text((pad + 18 * S, by + 16 * S + 27 * S + 6 * S), meta, font=f(12.5), fill=T2)
        # 按钮行
        bry = by + ch + 12 * S
        bh = 44 * S
        bw = (W - 2 * pad - 10 * S) / 2
        d.rectangle([pad, bry, pad + bw, bry + bh], outline=mix(INK, PAPER_TOP, 0.28), width=1)
        for t, x0, x1, fill, col in [("再听一次", pad, pad + bw, PAPER_TOP, T2),
                                     ("播放", pad + bw + 10 * S, W - pad, INK, SURF)]:
            if fill == INK:
                d.rectangle([x0, bry, x1, bry + bh], fill=INK)
            d.text(((x0 + x1 - d.textlength(t, font=f(14))) / 2, bry + bh / 2 - 14 * S / 2), t, font=f(14), fill=col)
        # 其他版本
        oy = bry + bh + 18 * S
        d.text((pad, oy), "其他版本", font=f(11), fill=T3)
        oy += 11 * S + 4 * S
        for title, singer in [("晴天 (Live)", "周杰伦"), ("晴天 (伴奏)", "周杰伦"), ("晴天 (节目版)", "周杰伦")]:
            d.text((pad, oy + 11 * S), title, font=f(14), fill=INK)
            sw = d.textlength(singer, font=f(11.5))
            d.text((W - pad - sw, oy + 12 * S), singer, font=f(11.5), fill=T3)
            row_h = 11 * S * 2 + 8 * S
            d.line([(pad, oy + row_h), (W - pad, oy + row_h)], fill=mix(INK, PAPER_TOP, 0.08), width=1)
            oy += row_h
    # ---- 页脚（把余白收成版面留白）----
    foot = "十秒采样只用于曲库比对，本机不留存"
    d.text((pad, D - 70 * S - 34 * S), foot, font=f(10.5), fill=mix(T3, PAPER_BOT, 0.85))
    # ---- 底部导航（6 格，识曲为选中格）----
    nav_h = 70 * S
    nav_top = D - nav_h
    d.rectangle([0, nav_top, W, D], fill=mix(PAPER_BOT, PAPER_TOP, 0.6))
    d.line([(0, nav_top), (W, nav_top)], fill=mix(INK, PAPER_TOP, 0.10), width=1)
    tabs = ["首页", "识曲", "收藏", "下载", "历史", "设置"]
    colw = W / len(tabs)
    for i, name in enumerate(tabs):
        cx0 = colw * i + colw / 2
        active = name == "识曲"
        # 图标：简化为一枚 4dp 圆点占位（预览只表达位置与选中态）
        ico_y = nav_top + 22 * S
        r = 7 * S
        d.ellipse([cx0 - r, ico_y - r, cx0 + r, ico_y + r],
                  fill=mix(INK, PAPER_TOP, 0.80 if active else 0.28))
        if active:
            d.ellipse([cx0 + 8 * S, ico_y - 12 * S, cx0 + 12 * S, ico_y - 8 * S], fill=(168, 62, 44))
        lab = name
        d.text((cx0 - d.textlength(lab, font=f(11)) / 2, nav_top + 42 * S), lab, font=f(11),
               fill=INK if active else T3)
    # 选中墨印
    if True:
        pass
    return img


idle = page("idle")
res = page("result")
idle.save(r"C:\Users\17948\DoubaoWork\chats\2026-10-22\new-chat-1\_tmp_fb3\preview_2183_rec_idle.jpg", quality=92)
res.save(r"C:\Users\17948\DoubaoWork\chats\2026-10-22\new-chat-1\_tmp_fb3\preview_2183_rec_result.jpg", quality=92)

# 并排合成一张（左：进页初始态；右：识别结果态）
sheet = Image.new("RGB", (W * 2 + 24, D), (235, 231, 221))
sheet.paste(idle, (0, 0))
sheet.paste(res, (W + 24, 0))
sheet.save(r"C:\Users\17948\DoubaoWork\chats\2026-10-22\new-chat-1\_tmp_fb3\preview_2183_rec.jpg", quality=90)
print("ok")
