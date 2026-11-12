# -*- coding: utf-8 -*-
import importlib.util
spec = importlib.util.spec_from_file_location("m", r"_tmp_build\mock_rec_page_2186.py")
m = importlib.util.module_from_spec(spec)
spec.loader.exec_module(m)
from PIL import Image
img, d = m.paper()
pad, y = m.header(d, mic_scale=0.72)
print("header", y)
y2 = m.card(d, pad, y, "Chemistry", "Alistair Griffin、Brian Howes", "《Albion Sky》")
print("card", y2, y2 - y)
y3 = m.playbar(d, pad, y2 + 12 * m.S, "播放这首歌")
print("playbar", y3)
y4 = y3 + 10 * m.S + m.text_h(12.5) + 4 * m.S + 10 * m.S + 4 * m.S
print("section start", y4)
y5 = m.section_head(d, pad, y4, "其他版本", "4 条")
print("section head ->", y5, "rowh", m.version_row_h(), "top_bar", m.D - 70 * m.S - 72 * m.S)
print("row1 ->", y5 + m.version_row_h(), "row2 ->", y5 + 2 * m.version_row_h())
