# -*- coding: utf-8 -*-
import io

kd = r"JZMusicHelperAndroid\app\src\main\java\com\jz\musichelper\ui\RecognizeScreen.kt"
s = io.open(kd, encoding="utf-8").read()
old = """            .fillMaxWidth()
            .padding(start = if (original) 12.dp else 12.dp, top = 12.dp, bottom = 11.dp)"""
if old not in s:
    # 打印实际的 VersionRow 内边距行，便于确认
    for line in s.splitlines():
        if "padding(" in line and "12" in line and "bottom" in line:
            print("CAND:", line)
    raise SystemExit("VersionRow padding not matched")

s = s.replace("""top = 12.dp, bottom = 11.dp)""", """top = 10.dp, bottom = 9.dp)""")
io.open(kd, "w", encoding="utf-8", newline="\n").write(s)
print("kotlin row padding patched")

p = r"_tmp_build\mock_rec_page_2186.py"
m = io.open(p, encoding="utf-8").read()
m = m.replace("""    return 12 * S + text_h(14.5) + 4 * S + text_h(11) + 11 * S""",
              """    return 10 * S + text_h(14.5) + 4 * S + text_h(11) + 9 * S""")
m = m.replace("""    h = version_row_h()
    if original:
        d.rectangle([pad, y + 12 * S, pad + 2 * S, y + h - 13 * S], fill=mix(CINNABAR, SURF, 0.75))
    x = pad + 12 * S
    d.text((x, y + 12 * S), name, font=f(14.5), fill=INK)""",
"""    h = version_row_h()
    if original:
        d.rectangle([pad, y + 10 * S, pad + 2 * S, y + h - 10 * S], fill=mix(CINNABAR, SURF, 0.75))
    x = pad + 12 * S
    d.text((x, y + 10 * S), name, font=f(14.5), fill=INK)""")
m = m.replace("""        d.rectangle([bx, y + 12 * S + 2, bx + bw, y + 12 * S + 2 + 9 * S * 1.32 + 2],
                    outline=mix(CINNABAR, SURF, 0.50), width=1)
        d.text((bx + 3 * S, y + 12 * S + 3), "原唱", font=f(9), fill=CINNABAR)
    my = y + 12 * S + text_h(14.5) + 4 * S""",
"""        d.rectangle([bx, y + 10 * S + 2, bx + bw, y + 10 * S + 2 + 9 * S * 1.32 + 2],
                    outline=mix(CINNABAR, SURF, 0.50), width=1)
        d.text((bx + 3 * S, y + 10 * S + 3), "原唱", font=f(9), fill=CINNABAR)
    my = y + 10 * S + text_h(14.5) + 4 * S""")
io.open(p, "w", encoding="utf-8", newline="\n").write(m)
print("mock row padding patched")
