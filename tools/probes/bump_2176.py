# -*- coding: utf-8 -*-
import io

G = r"C:\Users\17948\DoubaoWork\chats\2026-10-22\new-chat-1\JZMusicHelperAndroid\app\build.gradle.kts"
S = r"C:\Users\17948\DoubaoWork\chats\2026-10-22\new-chat-1\JZMusicHelperAndroid\app\src\main\java\com\jz\musichelper\ui\SettingsScreen.kt"

g = io.open(G, encoding="utf-8").read()
g = g.replace("versionCode = 133", "versionCode = 134").replace('versionName = "2.1.75"', 'versionName = "2.1.76"')
io.open(G, "w", encoding="utf-8", newline="\n").write(g)
print("gradle:", [l.strip() for l in g.split("\n") if "versionCode" in l or "versionName" in l])

s = io.open(S, encoding="utf-8").read()
old_ver = 'Text("JZ的音乐助手 v2.1.75", fontSize = 14.sp, color = p.text)'
new_ver = 'Text("JZ的音乐助手 v2.1.76", fontSize = 14.sp, color = p.text)'
assert old_ver in s, "version line not found"
s = s.replace(old_ver, new_ver)

old_note = (
    '                "修复桌面歌词打开后不显示：原来挂窗条件要等「当前歌曲」就位，而歌曲信息又只由窗口挂上后的循环去读，" +\n'
    '                    "两头互相等，退到桌面时窗口始终没挂出来。现在退到桌面即挂窗、随即取当前曲目歌词；" +\n'
    '                    "两行滚动、暂停变灰带「‖」、拖动吸边、转屏比例复位不变。仍需要系统「显示在其他应用上层」权限。" +\n'
    '                    "上版改动：新增桌面歌词（设置页 + 播放页三点菜单两个入口）。",'
)
new_note = (
    '                "桌面歌词改版「墨边纸签」：歌词改为相对悬浮栏居中（原来左对齐、右边空一大片），" +\n'
    '                    "栏体收窄到 274dp、高度 88→66dp、圆角 18→9dp，纸色实底加一道极淡墨线，" +\n'
    '                    "当前行 17sp 墨色、下一行 11sp 灰字，主次拉开；暂停时「‖」跟在当前行右侧并与文字整体居中。" +\n'
    '                    "两行滚动、拖动吸边、转屏比例复位不变，仍需要系统「显示在其他应用上层」权限。" +\n'
    '                    "上版改动：修复桌面歌词打开后不显示（挂窗与取词的死锁）。",'
)
assert old_note in s, "update note not found"
s = s.replace(old_note, new_note)
io.open(S, "w", encoding="utf-8", newline="\n").write(s)
print("settings patched")
