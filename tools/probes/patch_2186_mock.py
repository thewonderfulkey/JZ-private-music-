# -*- coding: utf-8 -*-
import io

p = r"_tmp_build\mock_rec_page_2186.py"
s = io.open(p, encoding="utf-8").read()

def rep(old, new):
    global s
    assert old in s, old[:70]
    s = s.replace(old, new, 1)

# header：支持 micScale，舞台高度与麦克风同步缩放
rep('''def header(d, phase_text="再点一下麦克风，可以重听"):
    pad = 22 * S
    y = 60
    d.text((pad, y), "听歌识曲", font=f(23), fill=INK)
    duration_button(d, pad, y + 23 * S / 2 - 16 * S)
    ly = y + 23 * S + 7 * S
    d.line([(pad, ly), (W - pad, ly)], fill=mix(INK, PAPER_TOP, 0.13), width=1)
    stage_top = ly + 10 * S
    cy = stage_top + 108 * S
    cx = W / 2
    base = 54 * S
    for i in range(3):
        r = base * (1 + i * 0.42)
        d.ellipse([cx - r, cy - r, cx + r, cy + r], outline=mix(INK, PAPER_TOP, 0.17 - i * 0.045), width=1 + i)
    disc = 64 * S
    d.ellipse([cx - disc, cy - disc, cx + disc, cy + disc], fill=mix(INK, PAPER_TOP, 0.035))
    d.ellipse([cx - disc, cy - disc, cx + disc, cy + disc], outline=mix(INK, PAPER_TOP, 0.22), width=1)
    draw_mic_icon(d, cx, cy, 48 * S, mix(INK, PAPER_TOP, 0.86))
    ty = stage_top + 214 * S
    d.text((cx - d.textlength(phase_text, font=f(11.5)) / 2, ty), phase_text, font=f(11.5), fill=T3)
    return pad, ty + 11.5 * S * 1.32 + 16 * S''',
'''def header(d, phase_text="再点一下麦克风，可以重听", mic_scale=1.0):
    pad = 22 * S
    y = 60
    d.text((pad, y), "听歌识曲", font=f(23), fill=INK)
    duration_button(d, pad, y + 23 * S / 2 - 16 * S)
    ly = y + 23 * S + 7 * S
    d.line([(pad, ly), (W - pad, ly)], fill=mix(INK, PAPER_TOP, 0.13), width=1)
    stage_top = ly + 10 * S
    stage_h = 252 * S * mic_scale
    cy = stage_top + stage_h / 2 - 6 * S
    cx = W / 2
    base = 54 * S * mic_scale
    for i in range(3):
        r = base * (1 + i * 0.42)
        d.ellipse([cx - r, cy - r, cx + r, cy + r], outline=mix(INK, PAPER_TOP, 0.17 - i * 0.045), width=1 + i)
    disc = 64 * S * mic_scale
    d.ellipse([cx - disc, cy - disc, cx + disc, cy + disc], fill=mix(INK, PAPER_TOP, 0.035))
    d.ellipse([cx - disc, cy - disc, cx + disc, cy + disc], outline=mix(INK, PAPER_TOP, 0.22), width=1)
    draw_mic_icon(d, cx, cy, 48 * S * mic_scale, mix(INK, PAPER_TOP, 0.86))
    ty = stage_top + stage_h + 4 * S
    d.text((cx - d.textlength(phase_text, font=f(11.5)) / 2, ty), phase_text, font=f(11.5), fill=T3)
    return pad, ty + 11.5 * S * 1.32 + 14 * S''')

# card：字号 26 / 内边距 12-16 / 间距 9-9-3-12
rep('''    inner = 18 * S
    h = (14 * S + text_h(10.5) + 12 * S + text_h(28) + 11 * S + 10 * S
         + text_h(13) + 4 * S + (text_h(11) if album else 0) + 16 * S)
    d.rectangle([x0, y, x1, y + h], fill=SURF, outline=mix(INK, PAPER_TOP, 0.10), width=1)
    cy = y + 14 * S''',
'''    inner = 16 * S
    h = (12 * S + text_h(10.5) + 10 * S + text_h(26) + 9 * S + 9 * S
         + text_h(13) + 3 * S + (text_h(11) if album else 0) + 12 * S)
    d.rectangle([x0, y, x1, y + h], fill=SURF, outline=mix(INK, PAPER_TOP, 0.10), width=1)
    cy = y + 12 * S''')

rep('''    cy += text_h(10.5) + 12 * S
    d.text((x0 + inner, cy), title, font=f(28), fill=INK)
    cy += text_h(28) + 11 * S
    d.line([(x0 + inner, cy), (x0 + inner + 28 * S, cy)], fill=mix(INK, SURF, 0.30), width=1)
    cy += 10 * S
    d.text((x0 + inner, cy), artists, font=f(13), fill=T2)
    cy += text_h(13) + 4 * S''',
'''    cy += text_h(10.5) + 10 * S
    d.text((x0 + inner, cy), title, font=f(26), fill=INK)
    cy += text_h(26) + 9 * S
    d.line([(x0 + inner, cy), (x0 + inner + 28 * S, cy)], fill=mix(INK, SURF, 0.30), width=1)
    cy += 9 * S
    d.text((x0 + inner, cy), artists, font=f(13), fill=T2)
    cy += text_h(13) + 3 * S''')

# playbar：44dp，文字用纸色（之前 alpha 用错成了墨色）
rep('''def playbar(d, pad, y, label, enabled=True):
    h = 46 * S
    d.rectangle([pad, y, W - pad, y + h], fill=mix(INK, SURF, 1.0 if enabled else 0.42))''',
'''def playbar(d, pad, y, label, enabled=True):
    h = 44 * S
    d.rectangle([pad, y, W - pad, y + h], fill=INK if enabled else mix(INK, PAPER_TOP, 0.42))''')

rep('''    col = mix(SURF, INK, 0.0)''',
'''    col = SURF if enabled else mix(SURF, PAPER_TOP, 0.55)''')

io.open(p, "w", encoding="utf-8", newline="\n").write(s)
print("mock patched")
