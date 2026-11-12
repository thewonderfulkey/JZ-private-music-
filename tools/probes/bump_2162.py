# -*- coding: utf-8 -*-
"""v2.1.62 版本号：versionCode 119 -> 120、versionName 2.1.61 -> 2.1.62。"""
import io, os

P = r"C:\Users\17948\DoubaoWork\chats\2026-10-22\new-chat-1\JZMusicHelperAndroid\app\build.gradle.kts"
s = io.open(P, encoding="utf-8").read()
assert "versionCode = 119" in s, "versionCode not 119"
assert 'versionName = "2.1.61"' in s, "versionName not 2.1.61"

s = s.replace("versionCode = 119", "versionCode = 120")
s = s.replace('versionName = "2.1.61"', 'versionName = "2.1.62"')
io.open(P, "w", encoding="utf-8", newline="").write(s)

for ln in s.splitlines():
    if "versionCode" in ln or "versionName" in ln:
        print(ln.strip())
