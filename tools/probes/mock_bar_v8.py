# -*- coding: utf-8 -*-
"""v2.1.78 实装效果预览：箭头方向 / 逐字均分（部分字连续压深）/ 进度线对齐文字"""
import os
import numpy as np
from PIL import Image, ImageDraw, ImageFont, ImageChops

ROOT = r"C:\Users\17948\DoubaoWork\chats\2026-10-22\new-chat-1"
FB = os.path.join(ROOT, "_tmp_fb3")
FONT = os.path.join(ROOT, r"JZMusicHelperAndroid\app\src\main\res\font\lxgw_wenkai_regular.ttf")

def font(px): return ImageFont.truetype(FONT, int(round(px)))
def mix(base, ink, a): return tuple(int(round(base[i] * (1 - a) + ink[i] * a)) for i in range(3)) + (255,)

THEMES = {
    "素纸": dict(paper=(251, 247, 237, 255), ink=(44, 40, 34), light=(176, 168, 152), sub=(138, 131, 120)),
    "旧黄": dict(paper=(242, 229, 196, 255), ink=(48, 40, 28), light=(168, 146, 108), sub=(146, 124, 92)),
    "夜墨": dict(paper=(36, 33, 29, 255), ink=(240, 234, 222), light=(112, 106, 94), sub=(148, 143, 130)),
}
CUR = "可是你不想一直走在黑暗的地方"
NXT = "想吹风 想自由 想要一起手牵手"

def screen():
    src = Image.open(os.path.join(FB, "frames_dl", "t22.50.jpg")).convert("RGB")
    return src.resize((1080, 2340), Image.LANCZOS).convert("RGBA")

def paper(d, x0, y0, x1, y1, th, s):
    P = lambda v: int(round(v * s))
    d.rounded_rectangle([x0, y0, x1, y1], radius=P(3), fill=th["paper"])
    d.rounded_rectangle([x0, y0, x1, y1], radius=P(3),
                        outline=mix(th["paper"][:3], (44, 40, 34), 0.26), width=max(1, P(0.9)))
    d.line([x0 + P(7), y0 + P(1.6), x1 - P(7), y0 + P(1.6)],
           fill=mix(th["paper"][:3], (44, 40, 34), 0.46), width=max(1, P(1.3)))

def karaoke(img, text, cx, top, f, th, ratio):
    """逐字均分：每个可见字等权，当前字按比例连续压深（与实装 drawPairAt 同口径）"""
    full_w = f.getlength(text)
    left = int(round(cx - full_w / 2))
    ImageDraw.Draw(img).text((left, top), text, font=f, fill=th["light"])

    total_vis = sum(1 for c in text if c != " ")
    n = ratio * total_vis
    w, used, done = 0.0, 0.0, False
    for ch in text:
        cw = f.getlength(ch)
        if ch == " ":
            w += cw
            continue
        if used + 1 <= n:
            w += cw
            used += 1
        else:
            part = n - used
            if part > 0:
                w += cw * part
            done = True
            break

    ov = Image.new("RGBA", img.size, (0, 0, 0, 0))
    ImageDraw.Draw(ov).text((left, top), text, font=f, fill=th["ink"])
    mask = Image.new("L", img.size, 0)
    ImageDraw.Draw(mask).rectangle([0, 0, left + int(round(w)), img.size[1]], fill=255)
    img.paste(ov, (0, 0), ImageChops.multiply(mask, ov.getchannel("A")))

def icon_lock(d, x, y, P, color):
    d.arc([x - P(2.5), y - P(4.4), x + P(2.5), y + P(0.2)], 180, 360, fill=color, width=max(2, P(1.0)))
    d.rounded_rectangle([x - P(3.2), y - P(0.4), x + P(3.2), y + P(4.0)], radius=P(1.0), fill=color)

def icon_chevron(d, x, y, P, color, left=True):
    s = 1 if left else -1
    d.line([(x + s * P(3.6), y - P(5.6)), (x - s * P(3.6), y), (x + s * P(3.6), y + P(5.6))],
           fill=color, width=max(2, P(1.4)))

def icon_pause(d, x, y, P, color):
    bw = max(2, P(1.1))
    d.rectangle([x - P(4.0), y - P(6.0), x - P(4.0) + bw, y + P(6.0)], fill=color)
    d.rectangle([x + P(2.5), y - P(6.0), x + P(2.5) + bw, y + P(6.0)], fill=color)

def icon_close(d, x, y, P, color):
    d.line([(x - P(4), y - P(4)), (x + P(4), y + P(4))], fill=color, width=max(2, P(1.2)))
    d.line([(x + P(4), y - P(4)), (x - P(4), y + P(4))], fill=color, width=max(2, P(1.2)))

def bar(img, x0, y0, w, h, s, th, ratio, locked=True, progress=True, paused=False):
    P = lambda v: int(round(v * s))
    d = ImageDraw.Draw(img)
    paper(d, x0, y0, x0 + w, y0 + h, th, s)
    FC, FN = font(17 * s), font(11 * s)
    bb, bbn = FC.getbbox("国"), FN.getbbox("国")
    asc, ascn = bb[3] - bb[1], bbn[3] - bbn[1]
    gap = P(8)
    top = y0 + (h - (asc + gap + ascn)) // 2 - bb[1]
    cx = x0 + w // 2
    if paused:
        d.text((cx - FC.getlength(CUR) / 2, top), CUR, font=FC, fill=th["sub"])
    else:
        karaoke(img, CUR, cx, top, FC, th, ratio)
    d.text((cx - FN.getlength(NXT) / 2, top + bb[1] + asc + gap), NXT, font=FN, fill=th["sub"])

    if progress:
        blockW = FC.getlength(CUR)
        left = x0 + (w - blockW) / 2
        right = left + blockW
        thk = int(round(1.8 * s))
        yy = y0 + h - int(round(5.4 * s))
        grad = np.zeros((thk, int(round(blockW)), 3), dtype=float)
        t = np.linspace(0, 1, int(round(blockW)))
        a = np.where(t < 0.09, t / 0.09, np.where(t > 0.91, (1 - t) / 0.09, 1.0))
        trk = mix(th["paper"][:3], (44, 40, 34), 0.10)
        for i in range(3):
            grad[:, :, i] = np.array(th["paper"][:3])[i] * (1 - a)[None, :] + trk[i] * a[None, :]
        strip = Image.fromarray(grad.astype("uint8")).convert("RGBA")
        mk = Image.new("L", strip.size, 0)
        ImageDraw.Draw(mk).rounded_rectangle([0, 0, strip.size[0] - 1, strip.size[1] - 1],
                                            radius=strip.size[1] / 2, fill=255)
        img.paste(strip, (int(round(left)), int(yy)), mk)
        if ratio > 0:
            head = max(left + thk, left + blockW * ratio)
            d.rounded_rectangle([left, yy, head, yy + thk], radius=thk / 2,
                                fill=mix(th["paper"][:3], (44, 40, 34), 0.26 if paused else 0.62))
    if locked:
        icon_lock(d, x0 + w - P(11), y0 + P(13), P, th["ink"])

def toolbar(img, x0, ty0, w, s, th, paused=False, locked=True):
    P = lambda v: int(round(v * s))
    d = ImageDraw.Draw(img)
    h = int(46 * s)
    paper(d, x0, ty0, x0 + w, ty0 + h, th, s)
    n, pad = 6, P(16)
    cw = (w - 2 * pad) // n
    cy = ty0 + h // 2
    for i in range(n):
        bx = x0 + pad + cw * i + cw // 2
        if i == 0:
            icon_chevron(d, bx, cy, P, th["ink"], left=True)     # 上一句：指左
        elif i == 1:
            if paused:
                d.polygon([(bx - P(4), cy - P(6)), (bx - P(4), cy + P(6)), (bx + P(6.5), cy)], fill=th["ink"])
            else:
                icon_pause(d, bx, cy, P, th["ink"])
        elif i == 2:
            icon_chevron(d, bx, cy, P, th["ink"], left=False)    # 下一句：指右
        elif i == 3:
            f14 = font(13 * s)
            d.text((bx - P(13) - f14.getlength("A-") / 2, cy - P(6)), "A-", font=f14, fill=th["ink"])
            d.text((bx + P(13) - f14.getlength("A+") / 2, cy - P(6)), "A+", font=f14, fill=th["ink"])
        elif i == 4:
            icon_lock(d, bx, cy, P, th["ink"])
        else:
            icon_close(d, bx, cy, P, th["ink"])
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
y1 = int(2340 * 0.80)
y0 = y1 - h
x0 = (1080 - w) // 2

# 左：逐字 47%（第 7 个字只压深一半，说明"连续推进"）
A = screen()
bar(A, x0, y0, w, h, S, THEMES["素纸"], 0.47)
A = caption(A, "实装 · 逐字均分 47%（第 7 字压深一半）",
            "每字等权、字内连续推开；底部墨线与文字左右边缘对齐、圆头")

# 右：工具条，箭头方向已修正
B = screen()
bar(B, x0, y0, w, h, S, THEMES["素纸"], 0.62)
toolbar(B, x0, y1 + int(8 * S), w, S, THEMES["素纸"])
B = caption(B, "实装 · ‹ 上一句 / › 下一句",
            "最左箭头指左＝上一句，第三格指右＝下一句；按钮顺序与功能不变")

OUT = Image.new("RGB", (2160, A.size[1]), (22, 21, 19))
OUT.paste(A, (0, 0))
OUT.paste(B, (1080, 0))
OUT.save(os.path.join(FB, "impl_v8_states.jpg"), quality=92)

# 第三张：20 / 50 / 80 三档对照，证明"均分"
ST = 2.6
row_h = int(104 * ST)
OUT2 = Image.new("RGB", (1080, row_h * 3 + 40), (32, 30, 27))
d = ImageDraw.Draw(OUT2)
for i, r in enumerate((0.2, 0.5, 0.8)):
    bw, bh = int(308 * ST), int(66 * ST)
    bx0, by0 = 60, 20 + row_h * i + (row_h - bh) // 2 - 10
    bar(OUT2, bx0, by0, bw, bh, ST, THEMES["素纸"], r, locked=False)
    f = font(30)
    d.text((bx0 + bw + 40, by0 + bh // 2 - 16), "%d%%" % int(r * 100), font=f, fill=(238, 234, 226))
    f2 = font(19)
    d.text((bx0 + bw + 40, by0 + bh // 2 + 16), "%d / 14 字" % round(r * 14), font=f2, fill=(150, 146, 138))

OUT2.save(os.path.join(FB, "impl_v8_step.jpg"), quality=92)
print("ok")
