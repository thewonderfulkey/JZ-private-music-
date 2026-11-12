# -*- coding: utf-8 -*-
"""v6：桌面歌词设计（逐字染色 / 工具条 / 三主题），单方案单图"""
import os
from PIL import Image, ImageDraw, ImageFont

ROOT = r"C:\Users\17948\DoubaoWork\chats\2026-10-22\new-chat-1"
FB = os.path.join(ROOT, "_tmp_fb3")
FONT = os.path.join(ROOT, r"JZMusicHelperAndroid\app\src\main\res\font\lxgw_wenkai_regular.ttf")

def font(px): return ImageFont.truetype(FONT, int(round(px)))

def mix(base, ink, a):
    return tuple(int(round(base[i] * (1 - a) + ink[i] * a)) for i in range(3)) + (255,)
def tw(f, s):
    b = f.getbbox(s); return b[2] - b[0]

INK = (44, 40, 34)
THEMES = {
    "素纸": dict(paper=(251, 247, 237, 255), ink=INK, light=(176, 168, 152), line=(44, 40, 34, 120),
                 sub=(138, 131, 120), edge=(44, 40, 34, 28)),
    "旧黄": dict(paper=(242, 229, 196, 255), ink=(48, 40, 28), light=(168, 146, 108), line=(62, 46, 26, 165),
                 sub=(146, 124, 92), edge=(62, 46, 26, 40)),
    "夜墨": dict(paper=(36, 33, 29, 250), ink=(240, 234, 222), light=(112, 106, 94), line=(236, 228, 210, 55),
                 sub=(148, 143, 130), edge=(236, 228, 210, 16)),
}
CUR = "可是你不想一直走在黑暗的地方"
NXT = "想吹风 想自由 想要一起手牵手"

def screen():
    src = Image.open(os.path.join(FB, "frames_dl", "t22.50.jpg")).convert("RGB")
    return src.resize((1080, 2340), Image.LANCZOS).convert("RGBA")

def paper(d, x0, y0, x1, y1, th, s, radius=3.0, top_rule=True):
    """s = 每 dp 的像素数"""
    def P(v): return int(round(v * s))
    d.rounded_rectangle([x0, y0, x1, y1], radius=P(radius), fill=th["paper"])
    d.rounded_rectangle([x0, y0, x1, y1], radius=P(radius), outline=mix(th["paper"][:3], (44, 40, 34), 0.26), width=max(1, P(0.9)))
    if top_rule:
        d.line([x0 + P(7), y0 + P(1.5), x1 - P(7), y0 + P(1.5)], fill=mix(th["paper"][:3], (44, 40, 34), 0.46), width=max(1, P(1.3)))

def karaoke(d, s_text, cx, baseline, f, th, ratio):
    w = tw(f, s_text); left = cx - w // 2
    d.text((left, baseline), s_text, font=f, fill=th["light"])
    n = int(round(len(s_text) * ratio))
    if n > 0:
        d.text((left, baseline), s_text[:n], font=f, fill=th["ink"])

def icon_lock(d, x, y, s, color, P):
    d.arc([x - P(2.6), y - P(4.6), x + P(2.6), y + P(0.4)], 180, 360, fill=color, width=max(2, P(0.9)))
    d.rounded_rectangle([x - P(3.4), y - P(0.2), x + P(3.4), y + P(4.2)], radius=P(1.0), fill=color)

def icon_chevron(d, x, y, P, color, direction=-1):
    d.line([(x + P(2.6) * direction, y - P(3.6)), (x - P(2.2) * direction, y),
            (x + P(2.6) * direction, y + P(3.6))], fill=color, width=max(2, P(1.1)))

def icon_pause(d, x, y, P, color):
    bw = max(2, P(0.9))
    d.rectangle([x - P(2.6), y - P(3.6), x - P(2.6) + bw, y + P(3.6)], fill=color)
    d.rectangle([x + P(1.4), y - P(3.6), x + P(1.4) + bw, y + P(3.6)], fill=color)

def icon_close(d, x, y, P, color):
    d.line([(x - P(2.8), y - P(2.8)), (x + P(2.8), y + P(2.8))], fill=color, width=max(2, P(1.0)))
    d.line([(x + P(2.8), y - P(2.8)), (x - P(2.8), y + P(2.8))], fill=color, width=max(2, P(1.0)))

def caption(img, text, sub):
    W, H = img.size
    strip = Image.new("RGB", (W, H + 156), (20, 20, 20))
    strip.paste(img.convert("RGB"), (0, 0))
    d = ImageDraw.Draw(strip)
    d.text((40, H + 20), text, font=font(32), fill=(246, 243, 237))
    d.text((40, H + 84), sub, font=font(23), fill=(150, 146, 138))
    return strip

def draw_bar(d, x0, y0, w, h, s, th, ratio, paused=False, locked=True, progress=True):
    P = lambda v: int(round(v * s))
    paper(d, x0, y0, x0 + w, y0 + h, th, s)
    FC, FN = font(P(17)), font(P(11))
    bb, bbn = FC.getbbox("国"), FN.getbbox("国")
    asc, ascn = bb[3] - bb[1], bbn[3] - bbn[1]
    gap = P(8)
    top = y0 + (h - (asc + gap + ascn)) // 2 - bb[1]
    cx = x0 + w // 2
    karaoke(d, CUR, cx, top, FC, th, 1.0 if paused else ratio)
    d.text((cx - tw(FN, NXT) // 2, top + bb[1] + asc + gap), NXT, font=FN, fill=th["sub"])
    if progress and not paused:
        total = w - P(20)
        d.line([x0 + P(10), y0 + h - P(5.0), x0 + P(10) + total, y0 + h - P(5.0)],
               fill=mix(th["paper"][:3], (44, 40, 34), 0.10), width=max(1, P(1.8)))
        d.line([x0 + P(10), y0 + h - P(5.0), x0 + P(10) + int(total * ratio), y0 + h - P(5.0)],
               fill=mix(th["paper"][:3], (44, 40, 34), 0.62), width=max(1, P(1.8)))
    if locked:
        icon_lock(d, x0 + w - P(11), y0 + P(13), s, th["ink"], P)

S = 3.0  # 每 dp 像素

# ---------- 1) A 逐字 ----------
img = screen(); d = ImageDraw.Draw(img)
w, h = int(308 * S), int(66 * S)
x0 = (1080 - w) // 2
y1 = int(2340 * 0.79); y0 = y1 - h
draw_bar(d, x0, y0, w, h, S, THEMES["素纸"], 0.45)
caption(img, "方案 A · 墨签逐字",
        "已唱的字压深墨、未唱留在淡墨；底边一道墨线走当前句进度；右上角小锁＝已锁定不会误拖").save(
    os.path.join(FB, "plan_A.jpg"), quality=93)

# ---------- 2) B 工具条 ----------
img = screen(); d = ImageDraw.Draw(img)
draw_bar(d, x0, y0, w, h, S, THEMES["素纸"], 0.45, progress=False)
P = lambda v: int(round(v * S))
tb_h = int(46 * S); ty0 = y1 + int(8 * S); ty1 = ty0 + tb_h
paper(d, x0, ty0, x0 + w, ty1, THEMES["素纸"], S, top_rule=False)
n = 6; pad = P(16); cw = (w - 2 * pad) // n; cy = (ty0 + ty1) // 2
for i in range(n):
    bx = x0 + pad + cw * i + cw // 2
    if i == 0: icon_chevron(d, bx, cy, P, INK, 1)
    elif i == 1: icon_pause(d, bx, cy, P, INK)
    elif i == 2: icon_chevron(d, bx, cy, P, INK, -1)
    elif i == 3:
        d.text((bx - P(20), cy - P(9)), "A-", font=font(P(14)), fill=INK)
        d.text((bx + P(2), cy - P(9)), "A+", font=font(P(14)), fill=INK)
    elif i == 4: icon_lock(d, bx, cy, S, INK, P)
    else: icon_close(d, bx, cy, P, INK)
    if i < n - 1:
        d.line([x0 + pad + cw * (i + 1), ty0 + P(10), x0 + pad + cw * (i + 1), ty1 - P(10)],
               fill=(44, 40, 34, 24), width=max(1, P(0.8)))
caption(img, "方案 B · 纸签＋工具条",
        "轻点纸签浮出一排按钮：上一句 / 暂停 / 下一句 / 字号 A- A+ / 锁定 / 关闭，3 秒无操作自动收起").save(
    os.path.join(FB, "plan_B.jpg"), quality=93)

# ---------- 3) 三主题 ----------
ST = 2.3
row_h = int(118 * ST)
OUT = Image.new("RGBA", (1080, 100 + row_h * 3 + 20), (32, 30, 27, 255))
d = ImageDraw.Draw(OUT)
for i, name in enumerate(["素纸", "旧黄", "夜墨"]):
    th = THEMES[name]
    bw, bh = int(308 * ST), int(66 * ST)
    bx0 = 1080 - bw - 40
    by1 = 100 + row_h * i + bh + 20
    by0 = by1 - bh
    draw_bar(d, bx0, by0, bw, bh, ST, th, 0.45)
    d.text((46, by0 + bh // 2 - 26), name, font=font(38), fill=(238, 234, 226))
    d.text((46, by0 + bh // 2 + 14), ["原纸色，最稳", "泛黄旧纸，暖", "深底浅字，花壁纸更清楚"][i],
           font=font(22), fill=(150, 146, 138))
OUT.convert("RGB").save(os.path.join(FB, "plan_themes.jpg"), quality=93)
print("ok")



