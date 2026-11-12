# -*- coding: utf-8 -*-
import io

p = r"_tmp_build\mock_rec_page_2186.py"
s = io.open(p, encoding="utf-8").read()


def rep(old, new):
    global s
    assert old in s, old[:70]
    s = s.replace(old, new, 1)


rep('''    img, d = paper()
    pad, y = header(d)
    y = card(d, pad, y, title, artists, album)
    y += 14 * S
    y = playbar(d, pad, y, "播放这首歌")
    y += 12 * S''',
'''    img, d = paper()
    pad, y = header(d, mic_scale=0.72)   # 出结果后麦克风缩到 0.72，把上方空间还给结果
    y = card(d, pad, y, title, artists, album)
    y += 12 * S
    y = playbar(d, pad, y, "播放这首歌")
    y += 10 * S''')

rep('''    d.text((dx + gap, y), labels[1], font=f(12.5), fill=T2)
    y += text_h(12.5) + 12 * S''',
'''    d.text((dx + gap, y), labels[1], font=f(12.5), fill=T2)
    y += text_h(12.5) + 4 * S + 10 * S''')

rep('''    top_bar = miniplayer(d)
    if show_versions:
        y += 6 * S''',
'''    top_bar = miniplayer(d)
    if show_versions:
        y += 4 * S''')

rep('''        for name, meta, orig in rows:
            if y + 60 * S > top_bar:
                break
            y = version_row(d, pad, y, name, meta, orig)
    else:
        y += 6 * S''',
'''        for name, meta, orig in rows:
            if y + 62 * S > top_bar:
                break
            y = version_row(d, pad, y, name, meta, orig)
    else:
        y += 4 * S''')

rep('''        if y + 60 * S <= top_bar:
            y = version_row(d, pad, y, "IVORY TOWER", "池年 · 酷我", False)
    footer(d, pad)
    nav(d)''',
'''        if y + 62 * S <= top_bar:
            y = version_row(d, pad, y, "IVORY TOWER", "池年 · 酷我", False)
    # 页脚只在没被悬浮栏盖住时画（真实界面里它落在内容末尾，被悬浮栏遮住时不出现）
    if y + 34 * S < top_bar:
        footer(d, pad)
    nav(d)''')

io.open(p, "w", encoding="utf-8", newline="\n").write(s)
print("page_result patched")
