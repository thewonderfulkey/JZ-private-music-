# -*- coding: utf-8 -*-
import io

p = r"_tmp_build\mock_rec_page_2186.py"
s = io.open(p, encoding="utf-8").read()

NEW = '''def compare():
    """上一版 vs 这一版：同一屏宽，各自按真实比例排一遍"""
    H = 2400
    img = Image.new("RGB", (W, H), PAPER_TOP)
    d = ImageDraw.Draw(img)
    for yy in range(H):
        c = tuple(int(PAPER_TOP[i] + (PAPER_BOT[i] - PAPER_TOP[i]) * yy / H) for i in range(3))
        d.line([(0, yy), (W, yy)], fill=c)
    pad = 22 * S

    # ---------- 上一版（v2.1.85）：细框大标题 + 两块矩形 + 整宽细框 ----------
    d.text((pad, 56), "上一版（v2.1.85）", font=f(12.5), fill=T3)
    y = 110
    h = 16 * S + 27 * S * 1.32 + 6 * S + 12.5 * S * 1.32 + 14 * S
    d.rectangle([pad, y, W - pad, y + h], fill=SURF, outline=mix(INK, PAPER_TOP, 0.16), width=1)
    d.text((pad + 18 * S, y + 16 * S), "Chemistry", font=f(27), fill=INK)
    d.text((pad + 18 * S, y + 16 * S + 34 * S),
           "Alistair Griffin、Brian Howes · Albion Sky", font=f(12.5), fill=T2)
    y += h + 12 * S
    bw = (W - 2 * pad - 10 * S) / 2
    d.rectangle([pad, y, pad + bw, y + 44 * S], outline=mix(INK, PAPER_TOP, 0.28), width=1)
    d.text((pad + bw / 2 - d.textlength("再听一次", font=f(14)) / 2, y + 22 * S - 14 * S * 0.66),
           "再听一次", font=f(14), fill=T2)
    d.rectangle([pad + bw + 10 * S, y, W - pad, y + 44 * S], fill=INK)
    d.text((pad + bw + 10 * S + bw / 2 - d.textlength("播放", font=f(14)) / 2, y + 22 * S - 14 * S * 0.66),
           "播放", font=f(14), fill=SURF)
    y += 44 * S + 10 * S
    d.rectangle([pad, y, W - pad, y + 44 * S], outline=mix(INK, PAPER_TOP, 0.28), width=1)
    d.text((W / 2 - d.textlength("其他版本", font=f(14)) / 2, y + 22 * S - 14 * S * 0.66),
           "其他版本", font=f(14), fill=T2)
    y_old = y + 44 * S

    # ---------- 这一版（v2.1.86） ----------
    d.text((pad, y_old + 46 * S), "这一版（v2.1.86）", font=f(12.5), fill=T3)
    y = y_old + 100 * S
    y = card(d, pad, y, "Chemistry", "Alistair Griffin、Brian Howes", "《Albion Sky》")
    y += 12 * S
    y = playbar(d, pad, y, "播放这首歌")
    y += 10 * S
    labels = ["再听一次", "其他版本 · 4 条"]
    widths = [d.textlength(t, font=f(12.5)) for t in labels]
    gap = 20 * S
    total = widths[0] + gap + 1 * S + gap + widths[1]
    x = (W - total) / 2
    d.text((x, y), labels[0], font=f(12.5), fill=T2)
    dx = x + widths[0] + gap
    d.line([(dx, y + 3 * S), (dx, y + 12.5 * S * 1.32 + 1)], fill=mix(INK, PAPER_TOP, 0.18), width=1)
    d.text((dx + gap, y), labels[1], font=f(12.5), fill=T2)
    y += text_h(12.5) + 4 * S + 14 * S
    y = section_head(d, pad, y, "其他版本", "4 条")
    y = version_row(d, pad, y, "IVORY TOWER", "澤野弘之 · QQ", True)
    y = version_row(d, pad, y, "IVORY TOWER", "池年 · 酷我", False)

    # ---------- 改动说明（放在所有内容之后，按实际 y 落笔） ----------
    notes = ["① 主结果从「细框大标题」变成方角纸签：眉标 + 朱砂印 + 短墨线断句，歌手与专辑分层",
             "② 唯一实心块只留给「播放这首歌」；其余动作降为文字链，不再两块矩形并排",
             "③ 列表用「标签 + 贯通细线 + 条数」的书页式小标题，原唱行加朱砂细签，行间只留发丝线"]
    ny = y + 36 * S
    for n in notes:
        d.text((pad, ny), n, font=f(10.5), fill=T3)
        ny += 10.5 * S * 1.5
    return img.crop((0, 0, W, int(ny + 26 * S)))


'''

i = s.index("def compare():")
j = s.index("imgs = {}")
s = s[:i] + NEW + s[j:]
io.open(p, "w", encoding="utf-8", newline="\n").write(s)
print("compare rewritten")
