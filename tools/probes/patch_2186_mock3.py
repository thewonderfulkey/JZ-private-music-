# -*- coding: utf-8 -*-
import io

p = r"_tmp_build\mock_rec_page_2186.py"
s = io.open(p, encoding="utf-8").read()


def rep(old, new):
    global s
    assert old in s, old[:70]
    s = s.replace(old, new, 1)


rep('''def version_row(d, pad, y, name, meta, original=False):
    h = 12 * S + text_h(14.5) + 4 * S + text_h(11) + 11 * S''',
'''def version_row_h():
    return 12 * S + text_h(14.5) + 4 * S + text_h(11) + 11 * S


def version_row(d, pad, y, name, meta, original=False):
    h = version_row_h()''')

rep('''def footer(d, pad, seconds=10):
    t = "%d 秒采样只用于曲库比对，本机不留存" % seconds
    d.text((pad, D - 104 * S), t, font=f(10.5), fill=mix(T3, PAPER_BOT, 0.85))''',
'''def footer(d, pad, y, seconds=10):
    """页脚跟着内容走（滚动区末尾），不再固定贴底，避免和悬浮栏叠在一起"""
    t = "%d 秒采样只用于曲库比对，本机不留存" % seconds
    d.text((pad, y), t, font=f(10.5), fill=mix(T3, PAPER_BOT, 0.85))
    return y + text_h(10.5)''')

rep('''        for name, meta, orig in rows:
            if y + 62 * S > top_bar:
                break''',
'''        for name, meta, orig in rows:
            if y + version_row_h() > top_bar:
                break''')

rep('''        if y + 62 * S <= top_bar:
            y = version_row(d, pad, y, "IVORY TOWER", "池年 · 酷我", False)''',
'''        if y + version_row_h() <= top_bar:
            y = version_row(d, pad, y, "IVORY TOWER", "池年 · 酷我", False)''')

rep('''    # 页脚只在没被悬浮栏盖住时画（真实界面里它落在内容末尾，被悬浮栏遮住时不出现）
    if y + 34 * S < top_bar:
        footer(d, pad)''',
'''    if y + text_h(10.5) + 10 * S <= top_bar:
        footer(d, pad, y + 10 * S)''')

io.open(p, "w", encoding="utf-8", newline="\n").write(s)
print("footer/row guard patched")
