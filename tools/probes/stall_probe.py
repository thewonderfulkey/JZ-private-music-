# -*- coding: utf-8 -*-
"""查看关键文件的最后写入时间，定位卡顿发生在哪一步。"""
import os, time

files = [
    r"C:\Users\17948\DoubaoWork\chats\2026-10-22\new-chat-1\JZMusicHelperAndroid\app\src\main\java\com\jz\musichelper\ui\HomeScreen.kt",
    r"C:\Users\17948\DoubaoWork\chats\2026-10-22\new-chat-1\JZMusicHelperAndroid\app\src\main\java\com\jz\musichelper\ui\SettingsScreen.kt",
    r"C:\Users\17948\DoubaoWork\chats\2026-10-22\new-chat-1\JZMusicHelperAndroid\app\build.gradle.kts",
    r"C:\Users\17948\DoubaoWork\chats\2026-10-22\new-chat-1\JZMusicHelperAndroid\app\build\outputs\apk\release\app-release.apk",
    r"C:\Users\17948\DoubaoWork\chats\2026-10-22\new-chat-1\_tmp_build\build_v2160.log",
    r"C:\Users\17948\DoubaoWork\chats\2026-10-22\new-chat-1\_tmp_fb3\send_out_2160.txt",
]
out = r"C:\Users\17948\DoubaoWork\chats\2026-10-22\new-chat-1\_tmp_build\stall_probe.txt"
lines = []
for f in files:
    if os.path.exists(f):
        lines.append("%s  %s" % (time.strftime("%H:%M:%S", time.localtime(os.path.getmtime(f))), f))
    else:
        lines.append("MISSING %s" % f)
lines.append("now       %s" % time.strftime("%H:%M:%S"))
open(out, "w", encoding="utf-8").write("\n".join(lines))
print("\n".join(lines))
