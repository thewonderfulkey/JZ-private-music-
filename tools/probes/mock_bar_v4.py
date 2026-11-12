# -*- coding: utf-8 -*-
"""桌面歌词栏 UI 三方案（终选版）：共用排版，差异在纸面处理。"""
import os
from PIL import Image, ImageDraw, ImageFont

ROOT = r"C:\Users\17948\DoubaoWork\chats\2026-10-22\new-chat-1"
FB = os.path.join(ROOT, "_tmp_fb3")
FONT = os.path.join(ROOT, r"JZMusicHelperAndroid\app\src\main\res\font\lxgw_wenkai_regular.ttf")

D = 3.0
def dp(v): return int(round(v * D))

CUR = "拥有你我的世界才能完美"
NXT = "他们猜 随便猜 不重要"
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

def render(cfg, paused=False):
    canvas = bg.convert("RGBA")
    ov = Image.new("RGBA", canvas.size, (0, 0, 0, 0))
    d = ImageDraw.Draw(ov)
    gap = dp(6)
    h = dp(cfg["h_dp"])
    cw = max(tw(F_CUR, CUR), tw(F_NXT, NXT))
    w = min(cw + dp(cfg["pad_x_dp"]) * 2, dp(cfg["max_w_dp"])) if cfg["width"] == "content" else dp(cfg["w_dp"])
    x0 = (W - w) // 2
    y1 = H - dp(cfg["bottom_dp"])
    y0 = y1 - h
    r = dp(cfg["radius_dp"])

    d.rounded_rectangle([x0, y0, x0 + w, y1], radius=r, fill=cfg["paper"])
    if cfg.get("stroke"):
        d.rounded_rectangle([x0, y0, x0 + w, y1], radius=r, outline=cfg["stroke"], width=dp(1))
    if cfg.get("rule"):
        ry = y1 - dp(11)
        d.line([x0 + dp(20), ry, x0 + w - dp(20), ry], fill=cfg["rule"], width=dp(1))
    if cfg.get("spine"):
        sw = dp(3)
        sy0 = y0 + int(h * 0.22)
        sy1 = y1 - int(h * 0.22)
        d.rounded_rectangle([x0 + dp(14), sy0, x0 + dp(14) + sw, sy1], radius=dp(1.5), fill=cfg["spine"])

    asc_c = F_CUR.getbbox("国")[3] - F_CUR.getbbox("国")[1]
    asc_n = F_NXT.getbbox("国")[3] - F_NXT.getbbox("国")[1]
    block = asc_c + gap + asc_n
    ty = y0 + (h - block) // 2
    cx = W // 2
    col = INK_DIM if paused else INK

    if paused:
        mw = dp(11)
        g = tw(F_CUR, CUR) + dp(9) + mw
        tx = cx - g // 2
        d.text((tx, ty), CUR, font=F_CUR, fill=col)
        mx = tx + tw(F_CUR, CUR) + dp(9)
        bh = dp(14)
        my = ty + (asc_c - bh) // 2
        d.line([mx, my, mx, my + bh], fill=GREY, width=dp(1))
        d.line([mx + dp(4), my, mx + dp(4), my + bh], fill=GREY, width=dp(1))
    else:
        d.text((cx - tw(F_CUR, CUR) // 2, ty), CUR, font=F_CUR, fill=col)

    d.text((cx - tw(F_NXT, NXT) // 2, ty + asc_c + gap), NXT, font=F_NXT, fill=GREY)
    return Image.alpha_composite(canvas, ov).convert("RGB")


# 一 墨边纸签（推荐）
P1 = dict(name="一 墨边纸签", width="content", pad_x_dp=26, max_w_dp=302, h_dp=66, radius_dp=9, bottom_dp=120,
          paper=(251, 247, 237, 255), stroke=(46, 42, 36, 40))
# 二 素纸（无框，底部一道淡墨线）
P2 = dict(name="二 素纸", width="content", pad_x_dp=26, max_w_dp=302, h_dp=66, radius_dp=9, bottom_dp=120,
          paper=(253, 251, 245, 252), stroke=None, rule=(46, 42, 36, 34))
# 三 书签条（左侧一道墨脊）
P3 = dict(name="三 书签条", width="fixed", w_dp=248, h_dp=64, radius_dp=6, bottom_dp=120,
          paper=(251, 247, 237, 255), stroke=None, spine=(46, 42, 36, 120))

rows = []
for cfg in (P1, P2, P3):
    im = render(cfg)
    im.save(os.path.join(FB, "bar_ui_v3_%d.jpg" % (rows.__len__() + 1)), quality=93)
    rows.append((cfg["name"] + "｜播放", im))
im = render(P1, paused=True)
im.save(os.path.join(FB, "bar_ui_v3_pause.jpg"), quality=93)
rows.append(("一 墨边纸签｜暂停", im))

pad, lab = 48, 36
ct, cb = H - dp(120) - dp(80), H - dp(86)
crops = [(n, im.crop((0, ct, W, cb))) for n, im in rows]
sh = crops[0][1].height
out = Image.new("RGB", (W, (sh + pad) * len(crops) + pad), (22, 20, 18))
d = ImageDraw.Draw(out)
lf = ImageFont.truetype(FONT, 30)
y = pad
for name, c in crops:
    out.paste(c, (0, y))
    d.text((16, y - lab), name, font=lf, fill=(238, 232, 222))
    y += sh + pad
out.save(os.path.join(FB, "bar_ui_v3_compare.jpg"), quality=93)
print("ok")
