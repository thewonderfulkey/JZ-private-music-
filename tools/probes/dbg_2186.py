# -*- coding: utf-8 -*-
import importlib.util, sys
spec = importlib.util.spec_from_file_location("m", r"_tmp_build\mock_rec_page_2186.py")
m = importlib.util.module_from_spec(spec)
spec.loader.exec_module(m)
from PIL import Image, ImageDraw
img, d = m.paper()
pad = 22 * m.S
y0 = 700
y1 = m.playbar(d, pad, y0, "播放这首歌")
img.crop((0, 660, 1080, 900)).save(r"_tmp_fb3\dbg_2186_bar.jpg", quality=95)
print("y0=%d y1=%d" % (y0, y1))

# 逐段打印结果页的 y 轨迹
img2, d2 = m.paper()
pad2, y = m.header(d2)
print("header ->", y)
y2 = m.card(d2, pad2, y, "Chemistry", "Alistair Griffin、Brian Howes", "《Albion Sky》")
print("card ->", y2, "h=", y2 - y)
y3 = m.playbar(d2, pad2, y2 + 14 * m.S, "播放这首歌")
print("playbar ->", y3)
y4 = m.section_head(d2, pad2, y3 + 12 * m.S + m.text_h(12.5) + 12 * m.S + 6 * m.S, "其他版本", "4 条")
print("section ->", y4)
print("miniplayer top =", m.D - 70 * m.S - 72 * m.S)
