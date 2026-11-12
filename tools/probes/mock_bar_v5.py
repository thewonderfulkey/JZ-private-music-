# -*- coding: utf-8 -*-
"""v2.1.76 复盘：样式加强方向 + 完整显示档位（单图分栏，标签独立不压栏）"""
import os
from PIL import Image, ImageDraw, ImageFont

ROOT = r"C:\Users\17948\DoubaoWork\chats\2026-10-22\new-chat-1"
FB = os.path.join(ROOT, "_tmp_fb3")
FONT = os.path.join(ROOT, r"JZMusicHelperAndroid\app\src\main\res\font\lxgw_wenkai_regular.ttf")

D = 3.0
def dp(v): return int(round(v * D))

SHOT = Image.open(os.path.join(FB, "shot_dl_2176.jpg")).convert("RGB")
W = SHOT.size[0]
INK = (46, 42, 36)
INK_DIM = (108, 101, 90)
GREY = (138, 131, 120)

CUR = "可是你不想一直走在黑暗的地方"
NXT = "想吹风 想自由 想要一起手牵手"
SAMPLE = "这是一句用来测试完整显示效果的比较长的歌词"

def font(px): return ImageFont.truetype(FONT, int(round(px)))
def tw(f, s):
    b = f.getbbox(s); return b[2] - b[0]

def fit_text(s, f, avail, spacing_px):
    width = tw(f, s) + spacing_px * (len(s) - 1)
    if width <= avail:
        return s
    n = 1
    while n < len(s):
        if tw(f, s[:n]) + spacing_px * (n - 1) + tw(f, "…") > avail:
            break
        n += 1
    return s[:n - 1] + "…"

def bar(canvas_size, y1, cfg, cur, nxt, fcur_sp, fnxt_sp=11, paused=False, spacing=0.04):
    layer = Image.new("RGBA", canvas_size, (0, 0, 0, 0))
    d = ImageDraw.Draw(layer)
    FC, FN = font(dp(fcur_sp)), font(dp(fnxt_sp))
    h, w = dp(cfg["h_dp"]), dp(cfg["w_dp"])
    x0 = (canvas_size[0] - w) // 2
    y0 = y1 - h
    r = dp(cfg["radius_dp"])
    paper = cfg["paper"]
    style = cfg.get("style", "rounded")
    padx = dp(cfg.get("pad_x", 16))
    avail = w - padx * 2

    if style == "rounded":
        d.rounded_rectangle([x0, y0, x0 + w, y1], radius=r, fill=paper)
        if cfg.get("stroke"):
            d.rounded_rectangle([x0, y0, x0 + w, y1], radius=r, outline=cfg["stroke"], width=dp(cfg.get("sw", 1.0)))
    elif style == "deckle":
        import random
        rnd = random.Random(7); step = dp(2.2); pts = []
        xs = x0
        while xs < x0 + w:
            pts.append((xs, y0 + dp(rnd.choice([0, 0, 0.6, 1.2])))); xs += step
        pts.append((x0 + w, y0 + dp(0.8)))
        ys = y0
        while ys < y1:
            pts.append((x0 + w - dp(rnd.choice([0, 0, 0.6, 1.4])), ys)); ys += dp(3)
        pts.append((x0 + w - dp(0.9), y1))
        xs = x0 + w
        while xs > x0:
            pts.append((xs, y1 - dp(rnd.choice([0, 0.5, 1.2, 0.8])))); xs -= step
        pts.append((x0, y1 - dp(0.7)))
        ys = y1
        while ys > y0:
            pts.append((x0 + dp(rnd.choice([0, 0.5, 1.0, 1.5])), ys)); ys -= dp(3)
        d.polygon(pts, fill=paper)
        if cfg.get("edge_line"):
            d.line(pts + [pts[0]], fill=cfg["edge_line"], width=dp(0.8))
    elif style == "rules":
        d.rectangle([x0, y0, x0 + w, y1], fill=paper)
        d.line([x0, y0, x0 + w, y0], fill=cfg["rule_top"], width=dp(cfg["top_w"]))
        d.line([x0, y1, x0 + w, y1], fill=cfg["rule_bot"], width=dp(cfg["bot_w"]))
    elif style == "spine":
        d.rounded_rectangle([x0, y0, x0 + w, y1], radius=r, fill=paper)
        sp = dp(3.5)
        d.rectangle([x0, y0 + dp(4), x0 + sp, y1 - dp(4)], fill=cfg["spine"])
        if cfg.get("stroke"):
            d.rounded_rectangle([x0, y0, x0 + w, y1], radius=r, outline=cfg["stroke"], width=dp(0.8))

    if cfg.get("top_band"):
        d.rectangle([x0 + dp(1.2), y0 + dp(1.0), x0 + w - dp(1.2), y0 + dp(1.0) + dp(cfg["top_band_w"])], fill=cfg["top_band"])

    bb_c, bb_n = FC.getbbox("国"), FN.getbbox("国")
    asc_c, asc_n = bb_c[3] - bb_c[1], bb_n[3] - bb_n[1]
    gap = dp(6)
    ty = y0 + (h - (asc_c + gap + asc_n)) // 2 - bb_c[1]
    cx = canvas_size[0] // 2
    col = INK_DIM if paused else INK
    shown = fit_text(cur, FC, avail, dp(spacing))

    if paused:
        g = tw(FC, shown) + dp(9) + dp(6)
        tx = cx - g // 2
        d.text((tx, ty), shown, font=FC, fill=col)
        mx = tx + tw(FC, shown) + dp(9)
        bh = dp(14); my = ty + bb_c[1] + (asc_c - bh) // 2
        d.line([mx, my, mx, my + bh], fill=GREY, width=dp(1))
        d.line([mx + dp(4), my, mx + dp(4), my + bh], fill=GREY, width=dp(1))
    else:
        d.text((cx - tw(FC, shown) // 2, ty), shown, font=FC, fill=col)

    shown_n = fit_text(nxt, FN, avail, dp(0.03))
    d.text((cx - tw(FN, shown_n) // 2, ty + bb_c[1] + asc_c + gap), shown_n, font=FN, fill=GREY)
    return layer, shown

BG = Image.open(os.path.join(FB, "frames_dl", "t22.50.jpg")).convert("RGB")  # 无歌词栏的桌面帧

def make_bg(size):
    crop = BG.resize(size, Image.LANCZOS).convert("RGB")
    return Image.blend(crop, Image.new("RGB", size, (0, 0, 0)), 0.15)

def label(img, xy, text, size=25, fill=(255, 255, 255), stroke=True):
    d = ImageDraw.Draw(img)
    if stroke:
        for dx, dy in ((-2, 0), (2, 0), (0, -2), (0, 2)):
            d.text((xy[0] + dx, xy[1] + dy), text, font=font(size), fill=(20, 20, 20))
    d.text(xy, text, font=font(size), fill=fill)

# ---- 图一：样式方向 ----
CASES = [
    ("现状 v2.1.76（你装到的这版）：274dp / 圆角 9 / 墨线 18%",
     dict(w_dp=274, h_dp=66, radius_dp=9, paper=(251, 247, 237, 255), stroke=(46, 42, 36, 46), style="rounded", pad_x=16)),
    ("A 墨签·加强：更暖纸 + 上缘 2dp 压墨 + 圆角 4 + 墨线 30%",
     dict(w_dp=308, h_dp=66, radius_dp=4, paper=(247, 239, 220, 255), stroke=(46, 42, 36, 76), sw=1.2,
          style="rounded", pad_x=10, top_band=(46, 42, 36, 150), top_band_w=2.2)),
    ("B 毛边纸：撕口边缘，边缘只描一道淡墨（无直角框）",
     dict(w_dp=308, h_dp=66, radius_dp=0, paper=(250, 243, 228, 255), edge_line=(46, 42, 36, 70),
          style="deckle", pad_x=14)),
    ("C 墨脊书签：左侧 3.5dp 墨脊 + 细框，视觉重心偏左",
     dict(w_dp=308, h_dp=66, radius_dp=6, paper=(251, 247, 237, 255), stroke=(46, 42, 36, 56),
          spine=(52, 46, 38, 210), style="spine", pad_x=16)),
    ("D 题签双线：上下各一道墨线、无整框，像书页上的一行题字",
     dict(w_dp=308, h_dp=62, radius_dp=0, paper=(252, 249, 241, 255), rule_top=(46, 42, 36, 130), top_w=1.4,
          rule_bot=(46, 42, 36, 60), bot_w=0.7, style="rules", pad_x=12)),
]
CAN = (W, 300 + 268 * len(CASES))
IMG = make_bg(CAN)
for i, (name, cfg) in enumerate(CASES):
    yb = 300 + 268 * i
    lay, shown = bar(CAN, yb, cfg, CUR, NXT, 17)
    IMG = Image.alpha_composite(IMG.convert("RGBA"), lay).convert("RGB")
    label(IMG, (40, yb - 202), name, 25)
IMG.save(os.path.join(FB, "bar_ui_v5_style.jpg"), quality=93)

# ---- 图二：完整显示 ----
OLD = dict(w_dp=274, h_dp=66, radius_dp=9, paper=(251, 247, 237, 255), stroke=(46, 42, 36, 46), style="rounded")
A = dict(w_dp=308, h_dp=66, radius_dp=4, paper=(247, 239, 220, 255), stroke=(46, 42, 36, 76), sw=1.2,
         style="rounded", top_band=(46, 42, 36, 150), top_band_w=2.2)
FITS = [
    ("现状：274dp / 内边 16 / 17sp+0.04 → 只能 13 字，这就是你截图里的「…」", OLD, 17, 16, 0.04),
    ("加宽：308dp / 内边 10 / 17sp+0.04 → 约 15 字，仍会截", A, 17, 10, 0.04),
    ("降档：308dp / 内边 10 / 15.5sp+0.02 → 约 18 字", A, 15.5, 10, 0.02),
    ("降档：308dp / 内边 10 / 13.5sp+0.02 → 21 字示例全显示，不出现省略号", A, 13.5, 10, 0.02),
]
CAN2 = (W, 220 + 268 * len(FITS))
IMG2 = make_bg(CAN2)
for i, (name, cfg, fs, padx, spg) in enumerate(FITS):
    yb = 220 + 268 * i
    cfg = dict(cfg); cfg["pad_x"] = padx
    lay, shown = bar(CAN2, yb, cfg, SAMPLE, "下一行示例：想吹风 想自由", fs, spacing=spg)
    IMG2 = Image.alpha_composite(IMG2.convert("RGBA"), lay).convert("RGB")
    label(IMG2, (40, yb - 202), name, 24)
    print("fit %5.1fsp pad%d -> %s" % (fs, padx, shown))
IMG2.save(os.path.join(FB, "bar_ui_v5_fit.jpg"), quality=93)
print("done")
