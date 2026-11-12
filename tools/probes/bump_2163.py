# -*- coding: utf-8 -*-
"""v2.1.63：版本号 vc121 / 2.1.63 + 设置-关于标题与更新说明同步；并加一条正楷字体说明。"""
import io, os

ROOT = r"C:\Users\17948\DoubaoWork\chats\2026-10-22\new-chat-1\JZMusicHelperAndroid"
GRADLE = os.path.join(ROOT, r"app\build.gradle.kts")
SETTINGS = os.path.join(ROOT, r"app\src\main\java\com\jz\musichelper\ui\SettingsScreen.kt")
OUT = r"C:\Users\17948\DoubaoWork\chats\2026-10-22\new-chat-1\_tmp_build\bump_out_2163.txt"

log = []

g = io.open(GRADLE, encoding="utf-8").read()
g2 = g.replace('versionCode = 120', 'versionCode = 121').replace('versionName = "2.1.62"', 'versionName = "2.1.63"')
assert g2 != g, "gradle version lines not found"
io.open(GRADLE, "w", encoding="utf-8").write(g2)
for ln in g2.splitlines():
    if "versionCode" in ln or "versionName" in ln:
        log.append("gradle| " + ln.strip())

s = io.open(SETTINGS, encoding="utf-8").read()
s2 = s.replace('Text("JZ的音乐助手 v2.1.62"', 'Text("JZ的音乐助手 v2.1.63"')
assert s2 != s, "settings title not found"
old_head = '"v2.1.62：首页板块顺序调整'
new_head = ('"v2.1.63：除首页品牌栏的毛笔题字「发现音乐」外，全 App 字体换回正楷（霞鹜文楷，与 v2.1.2–v2.1.10 同一版）——'
            '歌名、分区标题、按钮、底栏、正文、开屏题字全部跟随；字重仍靠字号与墨色层级区分。'
            'v2.1.62：首页板块顺序调整')
assert old_head in s2, "settings changelog head not found"
s3 = s2.replace(old_head, new_head, 1)
io.open(SETTINGS, "w", encoding="utf-8").write(s3)
log.append("settings title/changelog updated")

io.open(OUT, "w", encoding="utf-8").write("\n".join(log))
print("\n".join(log))
