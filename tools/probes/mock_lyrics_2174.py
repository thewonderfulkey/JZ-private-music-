# -*- coding: utf-8 -*-
"""按 v2.1.74 方案规格渲染桌面歌词栏预览：纸白胶囊 + 墨线描边 + 霞鹜文楷，两行歌词。
用工程里真实的内嵌字体，色值/尺寸与 DesktopLyricsView.kt 一一对应。"""
from PIL import Image, ImageDraw, ImageFont
import os

ROOT = r"C:\Users\17948\DoubaoWork\chats\2026-10-22\new-chat-1\JZMusicHelperAndroid\app\src\main\res\font"
FONT = os.path.join(ROOT, "lxgw_wenkai_regular.ttf")
OUT = r"C:\Users\17948\DoubaoWork\chats\2026-10-22\new-chat-1\_tmp_fb3"
os.makedirs(OUT, exist_ok=True)

S = 3  # 1080px 宽 ≈ 360dp@3x

def dp(v):
    return int(round(v * S))

def lerp(a, b, t):
    return tuple(int(round(a[i] + (b[i] - a[i]) * t)) for i in range(3))

def paper_bg(w, h):
    top = (0xFA, 0xF8, 0xF3)
    bot = (0xF1, 0xED, 0xE2)
    img = Image.new("RGB", (w, h), top)
    d = ImageDraw.Draw(img)
    for y in range(h):
        d.line([(0, y), (w, y)], fill=lerp(top, bot, y / max(1, h - 1)))
    return img

def make(state, cur, nxt, path):
    W, H = 1080, 1920
    img = paper_bg(W, H)
    d = ImageDraw.Draw(img, "RGBA")

    # 背景示意：桌面图标（压得很淡，只为交代“这是桌面”）
    d.rounded_rectangle([dp(40), dp(60), dp(140), dp(160)], radius=dp(18), fill=(46, 42, 36, 16))
    d.rounded_rectangle([dp(160), dp(60), dp(260), dp(160)], radius=dp(18), fill=(46, 42, 36, 16))
    d.rounded_rectangle([dp(280), dp(60), dp(380), dp(160)], radius=dp(18), fill=(46, 42, 36, 16))
    d.rounded_rectangle([dp(40), dp(178), dp(140), dp(278)], radius=dp(18), fill=(46, 42, 36, 16))

    # 歌词胶囊
    bw = min(dp(360 - 32), dp(480))
    bh = dp(88)
    x0 = (W - bw) // 2
    y1 = H - dp(120)
    y0 = y1 - bh
    cap = Image.new("RGBA", (bw, bh), (0, 0, 0, 0))
    cd = ImageDraw.Draw(cap)
    cd.rounded_rectangle([0, 0, bw - 1, bh - 1], radius=dp(18), fill=(0xFA, 0xF8, 0xF3, 0xF2))
    cd.rounded_rectangle([1, 1, bw - 3, bh - 3], radius=dp(18), outline=(0xDE, 0xD7, 0xC8, 255), width=dp(1))
    img.paste(cap, (x0, y0), cap)

    cur_font = ImageFont.truetype(FONT, dp(15))
    next_font = ImageFont.truetype(FONT, dp(13))

    pad = dp(18)
    cur_col = (0x2E, 0x2A, 0x24)
    if state == "paused":
        cur_col = lerp((0xFA, 0xF8, 0xF3), (0x2E, 0x2A, 0x24), 0.6)
    nxt_col = lerp((0xFA, 0xF8, 0xF3), (0x8A, 0x83, 0x78), 0.75)

    d.text((x0 + pad, y0 + bh * 0.35), cur, font=cur_font, fill=cur_col, anchor="lm")
    d.text((x0 + pad, y0 + bh * 0.70), nxt, font=next_font, fill=nxt_col, anchor="lm")

    if state == "paused":
        bx = x0 + bw - dp(16)
        h = dp(9)
        w = dp(1.8)
        gap = dp(4)
        top = y0 + bh * 0.35 - h / 2
        d.rounded_rectangle([bx - gap - w * 2, top, bx - gap - w, top + h], radius=dp(1), fill=lerp((0xFA, 0xF8, 0xF3), (0x5C, 0x54, 0x46), 0.75))
        d.rounded_rectangle([bx - w, top, bx, top + h], radius=dp(1), fill=lerp((0xFA, 0xF8, 0xF3), (0x5C, 0x54, 0x46), 0.75))

    label_font = ImageFont.truetype(FONT, dp(12))
    d.text((dp(40), H - dp(64)), "播放中" if state == "playing" else "暂停（保留最后一帧、变灰、右侧 ‖）",
           font=label_font, fill=(0x5C, 0x54, 0x46), anchor="lm")

    img.save(path, quality=95)
    print("saved", path, img.size)

make("playing", "你像一首慢歌 把我唱进夜里", "灯一暗 城市就开始呼吸", os.path.join(OUT, "mock_lyrics_playing.jpg"))
make("paused", "你像一首慢歌 把我唱进夜里", "灯一暗 城市就开始呼吸", os.path.join(OUT, "mock_lyrics_paused.jpg"))
