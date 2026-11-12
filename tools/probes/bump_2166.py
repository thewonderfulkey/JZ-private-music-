# -*- coding: utf-8 -*-
import io
p = r"C:\Users\17948\DoubaoWork\chats\2026-10-22\new-chat-1\JZMusicHelperAndroid\app\build.gradle.kts"
s = io.open(p, encoding="utf-8").read()
s = s.replace("versionCode = 123", "versionCode = 124", 1)
s = s.replace('versionName = "2.1.65"', 'versionName = "2.1.66"', 1)
io.open(p, "w", encoding="utf-8").write(s)
for l in s.splitlines():
    if "versionCode" in l or "versionName" in l:
        print(l.strip())
