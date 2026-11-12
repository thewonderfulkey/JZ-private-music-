# -*- coding: utf-8 -*-
"""v2.1.79 实装预览：底边进度条已删除、逐字染色按真实 KRC 逐字时间推进。
用的是《暗号》实测那行的真实毫秒（我 16211+0/156、想 +156/153、要 +309/198…），
三帧分别对应 16.40s（唱到「要」）、17.00s（唱到「的」六成）、19.60s（句已唱完、间奏中）。"""
import os
import numpy as np
from PIL import Image, ImageDraw, ImageFont, ImageChops

ROOT = r"C:\Users\17948\DoubaoWork\chats\2026-10-22\new-chat-1"
FB = os.path.join(ROOT, "_tmp_fb3")
FONT = os.path.join(ROOT, r"JZMusicHelperAndroid\app\src\main\res\font\lxgw_wenkai_regular.ttf")

def font(px): return ImageFont.truetype(FONT, int(round(px)))
def mix(base, ink, a): return tuple(int(round(base[i] * (1 - a) + ink[i] * a)) for i in range(3)) + (255,)

SU = dict(paper=(251, 247, 237, 255), ink=(44, 40, 34), light=(176, 168, 152), sub=(138, 131, 120))

LINE_START = 16211
CUR = "我想要的 想做的 你比谁都了"
NXT = "你想说的 想给的 我全都知道"
# 实测逐字（相对行首毫秒, 时长毫秒）
WORDS = [("我", 0, 156), ("想", 156, 153), ("要", 309, 198), ("的 ", 507, 457),
         ("想", 964, 223), ("做", 1187, 194), ("的 ", 1381, 524), ("你", 1905, 218),
         ("比", 2123, 248), ("谁", 2371, 545), ("都", 2916, 382), ("了", 3298, 193)]

def screen():
    src = Image.open(os.path.join(FB, "frames_dl", "t22.50.jpg")).convert("RGB")
    img = src.resize((1080, 2340), Image.LANCZOS).convert("RGBA")
    # 调暗一点，让纸签跳出来（预览用，不代表实装）
    shade = Image.new("RGBA", img.size, (0, 0, 0, 26))
    return Image.alpha_composite(img, shade)

def paper(d, x0, y0, x1, y1, s, th=SU):
    P = lambda v: int(round(v * s))
    d.rounded_rectangle([x0, y0, x1, y1], radius=P(3), fill=th["paper"])
    d.rounded_rectangle([x0, y0, x1, y1], radius=P(3),
                        outline=mix(th["paper"][:3], (44, 40, 34), 0.26), width=max(1, P(0.9)))
    d.line([x0 + P(7), y0 + P(1.6), x1 - P(7), y0 + P(1.6)],
           fill=mix(th["paper"][:3], (44, 40, 34), 0.46), width=max(1, P(1.3)))

def char_times(text, words):
    """与 Kotlin buildCharTimes 同口径：逐字时间映射到字符（空格不占时段）"""
    cs, ce = [None] * len(text), [None] * len(text)
    wi, wci = 0, 0
    for i, ch in enumerate(text):
        if ch == " ":
            continue
        while wi < len(words) and words[wi][0].strip() == "":
            wi += 1
            wci = 0
        if wi >= len(words):
            return cs, ce
        t, s, dur = words[wi]
        k = max(1, len([c for c in t if c != " "]))
        step = dur // k
        cs[i] = s + step * wci
        ce[i] = cs[i] + step
        wci += 1
        if wci >= k:
            wi += 1
            wci = 0
    return cs, ce

CS, CE = char_times(CUR, WORDS)

def fill_at(pos_abs):
    pos = pos_abs - LINE_START
    out = []
    for i, ch in enumerate(CUR):
        if ch == " ":
            continue
        s, e = CS[i], CE[i]
        f = 0.0 if pos <= s else (1.0 if pos >= e else (pos - s) / float(max(1, e - s)))
        out.append(f)
    return out

def karaoke_timed(img, text, cx, top, f, s, th=SU, pos_abs=0):
    full_w = f.getlength(text)
    left = int(round(cx - full_w / 2))
    d = ImageDraw.Draw(img)
    d.text((left, top), text, font=f, fill=th["light"])

    fills = fill_at(pos_abs)
    wsum, k = 0.0, 0
    for ch in text:
        cw = f.getlength(ch)
        if ch == " ":
            wsum += cw
            continue
        wsum += cw * fills[k]
        k += 1

    ov = Image.new("RGBA", img.size, (0, 0, 0, 0))
    ImageDraw.Draw(ov).text((left, top), text, font=f, fill=th["ink"])
    mask = Image.new("L", img.size, 0)
    ImageDraw.Draw(mask).rectangle([0, 0, left + int(round(wsum)), img.size[1]], fill=255)
    img.paste(ov, (0, 0), ImageChops.multiply(mask, ov.getchannel("A")))

def icon_lock(d, x, y, P, color):
    d.arc([x - P(2.5), y - P(4.4), x + P(2.5), y + P(0.2)], 180, 360, fill=color, width=max(2, P(1.0)))
    d.rounded_rectangle([x - P(3.2), y - P(0.4), x + P(3.2), y + P(4.0)], radius=P(1.0), fill=color)

def bar(img, x0, y0, s, pos_abs, th=SU):
    P = lambda v: int(round(v * s))
    w, h = P(308), P(66)
    d = ImageDraw.Draw(img)
    paper(d, x0, y0, x0 + w, y0 + h, s, th)
    FC, FN = font(17 * s), font(11 * s)
    bb, bbn = FC.getbbox("国"), FN.getbbox("国")
    asc, ascn = bb[3] - bb[1], bbn[3] - bbn[1]
    gap = P(8)
    top = y0 + (h - (asc + gap + ascn)) // 2 - bb[1]
    cx = x0 + w // 2
    karaoke_timed(img, CUR, cx, top, FC, s, th, pos_abs)
    d.text((cx - FN.getlength(NXT) / 2, top + bb[1] + asc + gap), NXT, font=FN, fill=th["sub"])
    icon_lock(d, x0 + w - P(11), y0 + P(13), P, th["ink"])
    return w, h

def label(img, x, y, text, size=30, color=(246, 243, 237)):
    ImageDraw.Draw(img).text((x, y), text, font=font(size), fill=color)

def build():
    S = 2.35
    img = screen()
    frames = [(16400, "16.40s  只亮了第 1 字「我」，「想」刚起 22%"),
              (17000, "17.00s  「我 / 想 / 要」已亮，「的」唱到 62%"),
              (19900, "19.90s  整句已唱完、还在间奏 —— 全亮，不再欠染")]
    y = 470
    for pos, cap in frames:
        w, h = int(308 * S), int(66 * S)
        x0 = (1080 - w) // 2
        bar(img, x0, y, S, pos, SU)
        label(img, x0, y + h + 14, cap, 26, (238, 235, 228))
        y += h + 96
    return img

def crop(img):
    out = Image.new("RGB", (1080, 1440), (22, 21, 19))
    out.paste(img.convert("RGB").crop((0, 380, 1080, 1820)), (0, 0))
    return out

if __name__ == "__main__":
    im = build()
    im.convert("RGB").save(os.path.join(FB, "impl_v9_timed.jpg"), quality=92)
    crop(im).save(os.path.join(FB, "impl_v9_timed_crop.jpg"), quality=92)
    # 量化自检：三帧的已亮字数与片段
    for pos in (16400, 17000, 19900):
        fs = fill_at(pos)
        lit = sum(1 for f in fs if f >= 1.0)
        part = [round(f, 2) for f in fs if 0 < f < 1]
        print("pos=%d abs -> line+%d  lit=%d  partial=%s" % (pos, pos - LINE_START, lit, part))
    print("OK")
