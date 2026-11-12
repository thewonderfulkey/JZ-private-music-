# -*- coding: utf-8 -*-
"""v7：v2.1.77 实装效果预览（参数与 DesktopLyricsView.kt 一致）"""
import os
from PIL import Image, ImageDraw, ImageFont

ROOT = r"C:\Users\17948\DoubaoWork\chats\2026-10-22\new-chat-1"
FB = os.path.join(ROOT, "_tmp_fb3")
FONT = os.path.join(ROOT, r"JZMusicHelperAndroid\app\src\main\res\font\lxgw_wenkai_regular.ttf")

def font(px): return ImageFont.truetype(FONT, int(round(px)))
def mix(base, ink, a): return tuple(int(round(base[i] * (1 - a) + ink[i] * a)) for i in range(3)) + (255,)
def tw(f, s):
    b = f.getbbox(s); return b[2] - b[0]

THEMES = {
    "素纸": dict(paper=(251, 247, 237, 255), ink=(44, 40, 34), light=(176, 168, 152), sub=(138, 131, 120)),
    "旧黄": dict(paper=(242, 229, 196, 255), ink=(48, 40, 28), light=(168, 146, 108), sub=(146, 124, 92)),
    "夜墨": dict(paper=(36, 33, 29, 255), ink=(240, 234, 222), light=(112, 106, 94), sub=(148, 143, 130)),
}
CUR = "可是你不想一直走在黑暗的地方"
NXT = "想吹风 想自由 想要一起手牵手"
LONG = "可是你不想一直走在黑暗的地方，可是你不想一直走在黑暗的地方"

def screen():
    src = Image.open(os.path.join(FB, "frames_dl", "t22.50.jpg")).convert("RGB")
    return src.resize((1080, 2340), Image.LANCZOS).convert("RGBA")

def paper(d, x0, y0, x1, y1, th, s, rule=True):
    P = lambda v: int(round(v * s))
    d.rounded_rectangle([x0, y0, x1, y1], radius=P(3), fill=th["paper"])
    d.rounded_rectangle([x0, y0, x1, y1], radius=P(3),
                        outline=mix(th["paper"][:3], (44, 40, 34), 0.26), width=max(1, P(0.9)))
    if rule:
        d.line([x0 + P(7), y0 + P(1.6), x1 - P(7), y0 + P(1.6)],
               fill=mix(th["paper"][:3], (44, 40, 34), 0.46), width=max(1, P(1.3)))

def karaoke(d, s_text, cx, baseline, f, th, ratio):
    w = tw(f, s_text); left = cx - w // 2
    d.text((left, baseline), s_text, font=f, fill=th["light"])
    n = int(round(len(s_text) * ratio))
    if n > 0: d.text((left, baseline), s_text[:n], font=f, fill=th["ink"])

def icon_lock(d, x, y, P, color):
    d.arc([x - P(2.5), y - P(4.4), x + P(2.5), y + P(0.2)], 180, 360, fill=color, width=max(2, P(1.0)))
    d.rounded_rectangle([x - P(3.2), y - P(0.4), x + P(3.2), y + P(4.0)], radius=P(1.0), fill=color)

def icon_chevron(d, x, y, P, color, direction=-1):
    d.line([(x - P(2.2) * direction, y - P(4.4)), (x + P(3.2) * direction, y),
            (x - P(2.2) * direction, y + P(4.4))], fill=color, width=max(2, P(1.2)))

def icon_pause(d, x, y, P, color):
    bw = max(2, P(1.1))
    d.rectangle([x - P(4.0), y - P(6.0), x - P(4.0) + bw, y + P(6.0)], fill=color)
    d.rectangle([x + P(2.5), y - P(6.0), x + P(2.5) + bw, y + P(6.0)], fill=color)

def icon_close(d, x, y, P, color):
    d.line([(x - P(4), y - P(4)), (x + P(4), y + P(4))], fill=color, width=max(2, P(1.2)))
    d.line([(x + P(4), y - P(4)), (x - P(4), y + P(4))], fill=color, width=max(2, P(1.2)))

def bar(d, x0, y0, w, h, s, th, ratio, paused=False, locked=True, progress=True,
        cur=None, nxt=None, cur_sp=17, nxt_sp=11):
    P = lambda v: int(round(v * s))
    paper(d, x0, y0, x0 + w, y0 + h, th, s)
    FC, FN = font(cur_sp * s), font(nxt_sp * s)
    bb, bbn = FC.getbbox("国"), FN.getbbox("国")
    asc, ascn = bb[3] - bb[1], bbn[3] - bbn[1]
    gap = P(8)
    top = y0 + (h - (asc + gap + ascn)) // 2 - bb[1]
    cx = x0 + w // 2
    karaoke(d, cur or CUR, cx, top, FC, th, 1.0 if paused else ratio)
    d.text((cx - tw(FN, nxt or NXT) // 2, top + bb[1] + asc + gap), nxt or NXT, font=FN, fill=th["sub"])
    if progress and not paused:
        total = w - P(20)
        d.line([x0 + P(10), y0 + h - P(4.4), x0 + P(10) + total, y0 + h - P(4.4)],
               fill=mix(th["paper"][:3], (44, 40, 34), 0.10), width=max(1, P(1.8)))
        d.line([x0 + P(10), y0 + h - P(4.4), x0 + P(10) + int(total * ratio), y0 + h - P(4.4)],
               fill=mix(th["paper"][:3], (44, 40, 34), 0.62), width=max(1, P(1.8)))
    if locked: icon_lock(d, x0 + w - P(11), y0 + P(13), P, th["ink"])

def toolbar(d, x0, ty0, w, s, th, paused=False, locked=True):
    P = lambda v: int(round(v * s))
    h = int(46 * s)
    paper(d, x0, ty0, x0 + w, ty0 + h, th, s, rule=False)
    n, pad = 6, P(16)
    cw = (w - 2 * pad) // n
    cy = ty0 + h // 2
    for i in range(n):
        bx = x0 + pad + cw * i + cw // 2
        if i == 0: icon_chevron(d, bx, cy, P, th["ink"], -1)
        elif i == 1:
            if paused:
                d.polygon([(bx - P(4), cy - P(6)), (bx - P(4), cy + P(6)), (bx + P(6.5), cy)], fill=th["ink"])
            else: icon_pause(d, bx, cy, P, th["ink"])
        elif i == 2: icon_chevron(d, bx, cy, P, th["ink"], 1)
        elif i == 3:
            f14 = font(13 * s)
            d.text((bx - P(13) - tw(f14, "A-") // 2, cy - P(6)), "A-", font=f14, fill=th["ink"])
            d.text((bx + P(13) - tw(f14, "A+") // 2, cy - P(6)), "A+", font=f14, fill=th["ink"])
        elif i == 4: icon_lock(d, bx, cy, P, th["ink"])
        else: icon_close(d, bx, cy, P, th["ink"])
        if i < n - 1:
            d.line([(x0 + pad + cw * (i + 1), ty0 + P(9)), (x0 + pad + cw * (i + 1), ty0 + h - P(9))],
                   fill=mix(th["paper"][:3], (44, 40, 34), 0.10), width=max(1, P(0.8)))

def caption(img, text, sub):
    W, H = img.size
    strip = Image.new("RGB", (W, H + 150), (22, 21, 19))
    strip.paste(img.convert("RGB"), (0, 0))
    d = ImageDraw.Draw(strip)
    d.text((40, H + 22), text, font=font(32), fill=(246, 243, 237))
    d.text((40, H + 82), sub, font=font(22), fill=(152, 148, 140))
    return strip

S = 3.0
w, h = int(308 * S), int(66 * S)
y1 = int(2340 * 0.80); y0 = y1 - h
x0 = (1080 - w) // 2

# 1) 双屏对照：逐字默认 / 工具条展开
A = screen(); d = ImageDraw.Draw(A)
bar(d, x0, y0, w, h, S, THEMES["素纸"], 0.45)
A = caption(A, "实装 · 逐字染色 + 进度线", "整句先铺淡墨、已唱压深墨；底边墨线走当前句进度；右上小锁＝已锁定不可拖")

B = screen(); d = ImageDraw.Draw(B)
bar(d, x0, y0, w, h, S, THEMES["素纸"], 0.55, progress=False)
toolbar(d, x0, y1 + int(8 * S), w, S, THEMES["素纸"])
B = caption(B, "实装 · 轻点浮出工具条", "上一句 / 暂停 / 下一句 / 字号 A- A+ / 锁定 / 关闭；3 秒无操作自动收起")

OUT = Image.new("RGB", (2160, A.size[1]), (22, 21, 19))
OUT.paste(A, (0, 0)); OUT.paste(B, (1080, 0))
OUT.save(os.path.join(FB, "impl_v7_states.jpg"), quality=92)

# 2) 三主题 + 长句折行
ST = 2.35
row_h = int(132 * ST)
rows = 4
OUT2 = Image.new("RGBA", (1080, 40 + row_h * rows), (32, 30, 27, 255))
d = ImageDraw.Draw(OUT2)
names = ["素纸", "旧黄", "夜墨"]
for i, name in enumerate(names):
    th = THEMES[name]
    bw, bh = int(308 * ST), int(66 * ST)
    bx0 = 1080 - bw - 38
    by1 = 20 + row_h * i + bh + 20
    bar(d, bx0, by1 - bh, bw, bh, ST, th, 0.45)
    d.text((44, by1 - bh + bh // 2 - 26), name, font=font(38), fill=(238, 234, 226))
    d.text((44, by1 - bh + bh // 2 + 14),
           ["原纸色，最稳", "泛黄旧纸，暖", "深底浅字，花壁纸上最清楚"][i],
           font=font(21), fill=(150, 146, 138))

# 长句折行（自动降到 0.72 倍，两行）
th = THEMES["素纸"]
bw = int(308 * ST)
line_h = int(17 * 0.72 * ST * 1.35)
bh2 = int((line_h * 2 + 8 * ST) + 28 * ST)
bx0 = 1080 - bw - 38
by1 = 20 + row_h * 3 + bh2 + 20
paper(d, bx0, by1 - bh2, bx0 + bw, by1, th, ST)
f14 = font(17 * 0.72 * ST)
part1 = "可是你不想一直走在黑暗的地方，"
part2 = "可是你不想一直走在黑暗的地方"
cx = bx0 + bw // 2
top = by1 - bh2 + int(14 * ST)
karaoke(d, part1, cx, top, f14, th, 1.0)
karaoke(d, part2, cx, top + line_h, f14, th, 0.35)
total = bw - int(20 * ST)
d.line([(bx0 + int(10 * ST), by1 - int(4.4 * ST)), (bx0 + int(10 * ST) + total, by1 - int(4.4 * ST))],
       fill=mix(th["paper"][:3], (44, 40, 34), 0.10), width=max(1, int(1.8 * ST)))
d.line([(bx0 + int(10 * ST), by1 - int(4.4 * ST)), (bx0 + int(10 * ST) + int(total * 0.30), by1 - int(4.4 * ST))],
       fill=mix(th["paper"][:3], (44, 40, 34), 0.62), width=max(1, int(1.8 * ST)))
icon_lock(d, bx0 + bw - int(11 * ST), by1 - bh2 + int(13 * ST), lambda v: int(v * ST), th["ink"])
d.text((44, by1 - bh2 + bh2 // 2 - 34), "超长句", font=font(38), fill=(238, 234, 226))
d.text((44, by1 - bh2 + bh2 // 2 + 6), "自动降字号 + 折两行", font=font(21), fill=(150, 146, 138))
d.text((44, by1 - bh2 + bh2 // 2 + 38), "框体随行数长高", font=font(21), fill=(150, 146, 138))

OUT2.convert("RGB").save(os.path.join(FB, "impl_v7_theme.jpg"), quality=92)
print("ok")
