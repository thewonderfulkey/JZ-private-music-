# -*- coding: utf-8 -*-
"""桌面歌词栏 UI 预览 v2：三个"纸面处理"方向，排版共用（全居中）。"""
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
INK_PAUSED = (110, 103, 92)
GREY = (138, 131, 120)

W, H = 1080, 2344
bg = Image.open(os.path.join(FB, "frames_dl", "t22.50.jpg")).convert("RGB").resize((W, H), Image.LANCZOS)

F_CUR = ImageFont.truetype(FONT, dp(18))
F_NXT = ImageFont.truetype(FONT, dp(11.5))
LW = 30  # 行高留白（sp）

def tw(f, s):
    b = f.getbbox(s)
    return b[2] - b[0]

def render(cfg, paused=False):
    canvas = bg.convert("RGBA")
    ov = Image.new("RGBA", canvas.size, (0, 0, 0, 0))
    d = ImageDraw.Draw(ov)

    gap = dp(5)
    h = dp(cfg["h_dp"])
    content_w = max(tw(F_CUR, CUR), tw(F_NXT, NXT))
    if cfg["width"] == "content":
        w = min(content_w + dp(cfg["pad_x_dp"]) * 2, dp(cfg["max_w_dp"]))
    else:
        w = dp(cfg["w_dp"])
    x0 = (W - w) // 2
    y1 = H - dp(cfg["bottom_dp"])
    y0 = y1 - h
    r = dp(cfg["radius_dp"])

    surf = cfg["surface"]
    if surf["fill"] is not None:
        d.rounded_rectangle([x0, y0, x0 + w, y1], radius=r, fill=surf["fill"])
    if surf.get("stroke"):
        d.rounded_rectangle([x0, y0, x0 + w, y1], radius=r, outline=surf["stroke"], width=dp(1))
    if surf.get("rules"):
        a = surf["rules"]
        d.line([x0 + dp(14), y0, x0 + w - dp(14), y0], fill=a, width=dp(1))
        d.line([x0 + dp(14), y1, x0 + w - dp(14), y1], fill=a, width=dp(1))

    asc_cur = F_CUR.getbbox("国")[3] - F_CUR.getbbox("国")[1]
    asc_nxt = F_NXT.getbbox("国")[3] - F_NXT.getbbox("国")[1]
    block = asc_cur + gap + asc_nxt
    ty = y0 + (h - block) // 2
    cx = W // 2

    cur_col = INK_PAUSED if paused else cfg.get("cur_color", INK)
    if paused:
        mark_w = dp(11)
        g = tw(F_CUR, CUR) + dp(9) + mark_w
        tx = cx - g // 2
        d.text((tx, ty), CUR, font=F_CUR, fill=cur_col)
        mx = tx + tw(F_CUR, CUR) + dp(9)
        bh = dp(14)
        my = ty + (asc_cur - bh) // 2
        d.line([mx, my, mx, my + bh], fill=GREY, width=dp(1))
        d.line([mx + dp(4), my, mx + dp(4), my + bh], fill=GREY, width=dp(1))
    else:
        d.text((cx - tw(F_CUR, CUR) // 2, ty), CUR, font=F_CUR, fill=cur_col)

    ty2 = ty + asc_cur + gap
    d.text((cx - tw(F_NXT, NXT) // 2, ty2), NXT, font=F_NXT, fill=GREY)

    return Image.alpha_composite(canvas, ov).convert("RGB")


# A 宣纸：半透暖纸、无描边、圆角 10、宽度贴内容
A = dict(name="A 宣纸", width="content", pad_x_dp=26, max_w_dp=302, h_dp=66, radius_dp=10, bottom_dp=120,
         surface=dict(fill=(248, 243, 231, 210), stroke=None, rules=None))
# B 白笺：实白、无描边、更窄（宽度贴内容，上限 78%）
B = dict(name="B 白笺", width="content", pad_x_dp=22, max_w_dp=281, h_dp=64, radius_dp=10, bottom_dp=120,
         surface=dict(fill=(252, 250, 244, 246), stroke=None, rules=None))
# C 双线签：极淡纸蒙版 + 上下两道细墨线（不围合）
Cc = dict(name="C 双线签", width="content", pad_x_dp=30, max_w_dp=302, h_dp=64, radius_dp=0, bottom_dp=120,
          surface=dict(fill=(250, 246, 236, 120), stroke=None, rules=(46, 42, 36, 110)))

rows = []
for cfg in (A, B, Cc):
    img = render(cfg)
    p = os.path.join(FB, "bar_ui_v2_%s.jpg" % cfg["name"][0])
    img.save(p, quality=93)
    rows.append((cfg["name"] + "｜播放", img))
imgA_pause = render(A, paused=True)
imgA_pause.save(os.path.join(FB, "bar_ui_v2_A_pause.jpg"), quality=93)
rows.append(("A 宣纸｜暂停", imgA_pause))

# 对比条
pad, lab = 24, 34
crop_top = H - dp(120) - dp(78)
crop_bot = H - dp(88)
crops = [(n, im.crop((0, crop_top, W, crop_bot))) for n, im in rows]
sh = crops[0][1].height
out = Image.new("RGB", (W, (sh + pad) * len(crops) + pad), (22, 20, 18))
d = ImageDraw.Draw(out)
lf = ImageFont.truetype(FONT, 30)
y = pad
for name, c in crops:
    out.paste(c, (0, y))
    d.text((16, y - lab), name, font=lf, fill=(238, 232, 222))
    y += sh + pad
out.save(os.path.join(FB, "bar_ui_v2_compare.jpg"), quality=93)
print("ok")
