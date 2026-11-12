# -*- coding: utf-8 -*-
"""桌面歌词栏 UI 三方向预览（不改代码，只出图）。
背景用实机录屏里的桌面帧（无歌词栏），2 倍放大到 1080 宽，与手机截图同尺度。
"""
import os
from PIL import Image, ImageDraw, ImageFont

ROOT = r"C:\Users\17948\DoubaoWork\chats\2026-10-22\new-chat-1"
FB = os.path.join(ROOT, "_tmp_fb3")
FONT = os.path.join(ROOT, r"JZMusicHelperAndroid\app\src\main\res\font\lxgw_wenkai_regular.ttf")

D = 3.0          # 1080px 宽 ≈ 360dp → density 3
def dp(v): return int(round(v * D))
def sp(v): return int(round(v * D))   # 字号按 sp≈dp 处理

CUR = "拥有你我的世界才能完美"
NXT = "他们猜 随便猜 不重要"

INK = (46, 42, 36)
GREY = (138, 131, 120)
PAPER = (251, 247, 239)

bg_base = Image.open(os.path.join(FB, "frames_dl", "t22.50.jpg")).convert("RGB")
W, H = 1080, 2344
bg_base = bg_base.resize((W, H), Image.LANCZOS)

f_cur17 = ImageFont.truetype(FONT, sp(17))
f_cur16 = ImageFont.truetype(FONT, sp(16))
f_cur18 = ImageFont.truetype(FONT, sp(18))
f_nxt125 = ImageFont.truetype(FONT, sp(12.5))
f_nxt12 = ImageFont.truetype(FONT, sp(12))


def text_w(font, s):
    b = font.getbbox(s)
    return b[2] - b[0]


def draw_bar(img, cfg):
    """cfg: dict(width_dp|width_mode, h_dp, radius_dp, bg_rgba, stroke_rgba, rule, progress, cur_font, nxt_font, gap_dp, pad_y_dp)"""
    canvas = img.convert("RGBA")
    ov = Image.new("RGBA", canvas.size, (0, 0, 0, 0))
    d = ImageDraw.Draw(ov)

    fcur, fnxt = cfg["cur_font"], cfg["nxt_font"]
    gap = dp(cfg["gap_dp"])
    h = dp(cfg["h_dp"])
    tw = max(text_w(fcur, cfg["cur"]), text_w(fnxt, cfg["nxt"]))
    if cfg.get("width_mode") == "content":
        w = min(tw + dp(cfg["pad_x_dp"]) * 2, dp(88) * 12 / 12 * 0 + dp(cfg["max_w_dp"]))
    else:
        w = dp(cfg["w_dp"])
    x0 = (W - w) // 2
    y1 = H - dp(cfg["bottom_dp"])
    y0 = y1 - h
    r = dp(cfg["radius_dp"])

    d.rounded_rectangle([x0, y0, x0 + w, y1], radius=r, fill=cfg["bg_rgba"], outline=cfg["stroke_rgba"], width=dp(1) if cfg["stroke_rgba"] else 0)

    # 文本块整体居中：当前行在上，次行在下
    asc_cur = fcur.getbbox("国")[3] - fcur.getbbox("国")[1]
    asc_nxt = fnxt.getbbox("国")[3] - fnxt.getbbox("国")[1]
    block_h = asc_cur + gap + asc_nxt
    ty = y0 + (h - block_h) // 2

    cur_color = cfg.get("cur_color", INK)
    cx = W // 2
    # 当前行（+ 暂停时的 ‖ 标记，作为整体居中）
    if cfg.get("paused"):
        mark_w = dp(10)
        group_w = text_w(fcur, cfg["cur"]) + dp(8) + mark_w
        tx = cx - group_w // 2
        d.text((tx, ty), cfg["cur"], font=fcur, fill=cur_color)
        mx = tx + text_w(fcur, cfg["cur"]) + dp(8)
        bh = dp(13)
        my = ty + (asc_cur - bh) // 2
        d.line([mx, my, mx, my + bh], fill=GREY, width=dp(1))
        d.line([mx + dp(4), my, mx + dp(4), my + bh], fill=GREY, width=dp(1))
    else:
        tx = cx - text_w(fcur, cfg["cur"]) // 2
        d.text((tx, ty), cfg["cur"], font=fcur, fill=cur_color)

    ty2 = ty + asc_cur + gap
    tx2 = cx - text_w(fnxt, cfg["nxt"]) // 2
    d.text((tx2, ty2), cfg["nxt"], font=fnxt, fill=cfg.get("nxt_color", GREY))

    if cfg.get("rule"):
        ry = y1 - dp(cfg["rule"]["inset_bottom_dp"])
        d.line([x0 + dp(cfg["rule"]["inset_x_dp"]), ry, x0 + w - dp(cfg["rule"]["inset_x_dp"]), ry],
               fill=cfg["rule"]["color"], width=dp(1))

    if cfg.get("progress") is not None:
        pr = cfg["progress"]
        py = y1 - dp(10)
        ix = dp(cfg["prog_inset_dp"])
        d.line([x0 + ix, py, x0 + w - ix, py], fill=(46, 42, 36, 26), width=dp(2))
        d.line([x0 + ix, py, x0 + ix + int((w - ix * 2) * pr), py], fill=(46, 42, 36, 120), width=dp(2))

    out = Image.alpha_composite(canvas, ov).convert("RGB")
    return out


variants = []

# A 墨签：紧凑胶囊，宽度贴内容，全居中
A = dict(name="A 墨签", width_mode="content", pad_x_dp=24, max_w_dp=302, h_dp=62, radius_dp=31,
         bottom_dp=120, gap_dp=6, cur_font=f_cur17, nxt_font=f_nxt125,
         bg_rgba=(251, 247, 239, 255), stroke_rgba=(46, 42, 36, 42), cur=CUR, nxt=NXT)
variants.append(A)

# B 纸页：宽签、无描边、底部一条细墨线
B = dict(name="B 纸页", w_dp=302, h_dp=68, radius_dp=16, bottom_dp=120, gap_dp=8,
         cur_font=f_cur16, nxt_font=f_nxt12,
         bg_rgba=(250, 246, 236, 242), stroke_rgba=None, cur=CUR, nxt=NXT,
         rule=dict(inset_x_dp=20, inset_bottom_dp=12, color=(46, 42, 36, 56)))
variants.append(B)

# C 纸片：方一点、带播放进度细线
Cc = dict(name="C 纸片", w_dp=296, h_dp=72, radius_dp=8, bottom_dp=120, gap_dp=7,
          cur_font=f_cur18, nxt_font=f_nxt12,
          bg_rgba=(252, 250, 245, 250), stroke_rgba=(46, 42, 36, 30), cur=CUR, nxt=NXT,
          progress=0.38, prog_inset_dp=18)
variants.append(Cc)

outs = []
for cfg in variants:
    img = draw_bar(bg_base, cfg)
    p = os.path.join(FB, "bar_ui_%s.jpg" % cfg["name"][:1])
    img.save(p, quality=92)
    outs.append((cfg["name"], img))
    # 暂停态（仅 A）
    if cfg["name"].startswith("A"):
        paused = dict(cfg)
        paused["paused"] = True
        paused["cur_color"] = (110, 103, 92)
        pimg = draw_bar(bg_base, paused)
        pp = os.path.join(FB, "bar_ui_A_paused.jpg")
        pimg.save(pp, quality=92)
        outs.append(("A 墨签（暂停态）", pimg))

# 对比条：三个方向各裁一条（含桌面背景），竖排拼在一张
strip_imgs = []
for cfg in variants:
    img = draw_bar(bg_base, cfg)
    top = H - dp(120) - dp(80)
    bot = H - dp(80)
    crop = img.crop((0, top, W, bot))
    strip_imgs.append((cfg["name"], crop))
paused_cfg = dict(A)
paused_cfg["paused"] = True
paused_cfg["cur_color"] = (110, 103, 92)
crop_top = H - dp(120) - dp(80)
crop_bot = H - dp(80)
paused_img = draw_bar(bg_base, paused_cfg).crop((0, crop_top, W, crop_bot))
strip_imgs.append(("A 墨签（暂停）", paused_img))

pad = 26
sh = strip_imgs[0][1].height
out = Image.new("RGB", (W, (sh + pad) * len(strip_imgs) + pad), (24, 22, 20))
d = ImageDraw.Draw(out)
label_font = ImageFont.truetype(FONT, 30)
y = pad
for name, crop in strip_imgs:
    out.paste(crop, (0, y))
    d.text((18, y + 6), name, font=label_font, fill=(240, 236, 226))
    y += sh + pad
out.save(os.path.join(FB, "bar_ui_compare.jpg"), quality=92)
print("done:", os.listdir(FB))
