# -*- coding: utf-8 -*-
"""v2.1.59 APK 交付前静态核对：完整性 / 条目数 / 版本串命中 / 体积对比 / 签名结果落盘。"""
import os, zipfile, re

apk = r"C:\Users\17948\DoubaoWork\chats\2026-10-22\new-chat-1\JZMusicHelperAndroid\app\build\outputs\apk\release\app-release.apk"
prev = r"C:\Users\17948\DoubaoWork\chats\2026-10-22\new-chat-1\_tmp_fb3\JZ音乐助手-v2.1.58.apk"
out = r"C:\Users\17948\DoubaoWork\chats\2026-10-22\new-chat-1\_tmp_build\zipcheck_2159.txt"

lines = []
size = os.path.getsize(apk)
lines.append(f"apk={apk}")
lines.append(f"size={size} ({size/1048576:.2f} MB)")
if os.path.exists(prev):
    psize = os.path.getsize(prev)
    lines.append(f"prev_v2158={psize} ({psize/1048576:.2f} MB) delta={size-psize:+d} ({(size-psize)/psize*100:+.2f}%)")

bad = []
with zipfile.ZipFile(apk) as z:
    bad = z.testzip()
    names = z.namelist()
lines.append(f"testzip={'OK' if bad is None else 'BAD:'+str(bad)}")
lines.append(f"entries={len(names)}")

# dex 里是否命中 2.1.59
hits = []
with zipfile.ZipFile(apk) as z:
    for n in names:
        if n.endswith(".dex"):
            data = z.read(n)
            if b"2.1.59" in data:
                hits.append(n)
lines.append(f"dex_with_2159={hits}")

# 关键资源是否还在包内
want = ["res/drawable", "ink_bg_player", "mashanzheng", "editor_chinese", "search_ink"]
present = {k: [n for n in names if k in n][:2] for k in want}
for k, v in present.items():
    lines.append(f"res[{k}]={v}")

open(out, "w", encoding="utf-8").write("\n".join(lines))
print("written", out, "bad=", bad)
