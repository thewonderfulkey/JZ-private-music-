# -*- coding: utf-8 -*-
"""方案一（墨边纸签）在固定宽度下的长句/短句状态，验证居中与不抖动。"""
import os
from PIL import Image, ImageDraw, ImageFont

ROOT = r"C:\Users\17948\DoubaoWork\chats\2026-10-22\new-chat-1"
FB = os.path.join(ROOT, "_tmp_fb3")
FONT = os.path.join(ROOT, r"JZMusicHelperAndroid\app\src\main\res\font\lxgw_wenkai_regular.ttf")
D = 3.0
def dp(v): return int(round(v * D))

INK = (46, 42, 36)
INK_DIM = (108, 101, 90)
GREY = (138, 131, 120)
W, H = 1080, 2344
bg = Image.open(os.path.join(FB, "frames_dl", "t22.50.jpg")).convert("RGB").resize((W, H), Image.LANCZOS)
F_CUR = ImageFont.truetype(FONT, dp(17))
F_NXT = ImageFont.truetype(FONT, dp(11))

def tw(f, s):
    b = f.getbbox(s)
    return b[2] - b[0]

def render(cur, nxt, paused=False, w_dp=274):
    canvas = bg.convert("RGBA")
    ov = Image.new("RGBA", canvas.size, (0, 0, 0, 0))
    d = ImageDraw.Draw(ov)
    gap, h = dp(6), dp(66)
    w = dp(w_dp)
    x0 = (W - w) // 2
    y1 = H - dp(120)
    y0 = y1 - h
    d.rounded_rectangle([x0, y0, x0 + w, y1], radius=dp(9), fill=(251, 247, 237, 255), outline=(46, 42, 36, 52), width=dp(1))

    asc_c = F_CUR.getbbox("国")[3] - F_CUR.getbbox("国")[1]
    asc_n = F_NXT.getbbox("国")[3] - F_NXT.getbbox("国")[1]
    ty = y0 + (h - (asc_c + gap + asc_n)) // 2
    cx = W // 2
    col = INK_DIM if paused else INK
    if paused:
        g = tw(F_CUR, cur) + dp(9) + dp(11)
        tx = cx - g // 2
        d.text((tx, ty), cur, font=F_CUR, fill=col)
        mx = tx + tw(F_CUR, cur) + dp(9)
        my, bh = ty + (asc_c - dp(14)) // 2, dp(14)
        d.line([mx, my, mx, my + bh], fill=GREY, width=dp(1))
        d.line([mx + dp(4), my, mx + dp(4), my + bh], fill=GREY, width=dp(1))
    else:
        d.text((cx - tw(F_CUR, cur) // 2, ty), cur, font=F_CUR, fill=col)
    d.text((cx - tw(F_NXT, nxt) // 2, ty + asc_c + gap), nxt, font=F_NXT, fill=GREY)
    return Image.alpha_composite(canvas, ov).convert("RGB")

rows = [
    ("长句", render("拥有你我的世界才能完美", "他们猜 随便猜 不重要")),
    ("短句", render("不要说话", "请别告诉我")),
    ("暂停", render("拥有你我的世界才能完美", "他们猜 随便猜 不重要", paused=True)),
]
pad, lab = 48, 36
ct, cb = H - dp(120) - dp(80), H - dp(86)
crops = [(n, im.crop((0, ct, W, cb))) for n, im in rows]
sh = crops[0][1].height
out = Image.new("RGB", (W, (sh + pad) * len(crops) + pad), (22, 20, 18))
d = ImageDraw.Draw(out)
lf = ImageFont.truetype(FONT, 30)
y = pad
for n, c in crops:
    out.paste(c, (0, y))
    d.text((16, y - lab), "方案一 · " + n, font=lf, fill=(238, 232, 222))
    y += sh + pad
out.save(os.path.join(FB, "bar_ui_v3_states.jpg"), quality=93)
print("ok")
