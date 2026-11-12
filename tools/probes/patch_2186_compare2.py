# -*- coding: utf-8 -*-
import io

p = r"_tmp_build\mock_rec_page_2186.py"
s = io.open(p, encoding="utf-8").read()

# 1) 标签与纸签间距收紧：标签画完 34dp 就落卡片
old = '''    d.text((pad, y_old + 46 * S), "这一版（v2.1.86）", font=f(12.5), fill=T3)
    y = y_old + 100 * S'''
new = '''    label_y = y_old + 46 * S
    d.text((pad, label_y), "这一版（v2.1.86）", font=f(12.5), fill=T3)
    y = label_y + 34 * S'''
assert old in s
s = s.replace(old, new)

# 2) 改动说明改短 + 自适应字号，避免右侧裁切
old2 = '''    notes = ["① 主结果从「细框大标题」变成方角纸签：眉标 + 朱砂印 + 短墨线断句，歌手与专辑分层",
             "② 唯一实心块只留给「播放这首歌」；其余动作降为文字链，不再两块矩形并排",
             "③ 列表用「标签 + 贯通细线 + 条数」的书页式小标题，原唱行加朱砂细签，行间只留发丝线"]
    ny = y + 36 * S
    for n in notes:
        d.text((pad, ny), n, font=f(10.5), fill=T3)
        ny += 10.5 * S * 1.5'''
new2 = '''    notes = ["① 主结果：细框大标题改成方角纸签，眉标 / 朱砂印 / 短墨线断句，歌手与专辑分层",
             "② 唯一实心块只给「播放这首歌」，其余动作降为文字链，不再两块矩形并排",
             "③ 列表用「标签 + 贯通细线 + 条数」书页式小标题，原唱行加朱砂细签，行间只留发丝线"]
    ny = y + 36 * S
    maxw = W - 2 * pad
    size = 10.0
    while size > 7.0:
        if max(d.textlength(n, font=f(size)) for n in notes) <= maxw:
            break
        size -= 0.5
    for n in notes:
        d.text((pad, ny), n, font=f(size), fill=T3)
        ny += size * S * 1.7'''
assert old2 in s
s = s.replace(old2, new2)

io.open(p, "w", encoding="utf-8", newline="\n").write(s)
print("compare fixed")
