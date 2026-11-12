# -*- coding: utf-8 -*-
"""v2.1.64：版本号 vc122 / 2.1.64 + 设置-关于标题与更新说明同步（下载链路两条补齐）。"""
import io, os

ROOT = r"C:\Users\17948\DoubaoWork\chats\2026-10-22\new-chat-1\JZMusicHelperAndroid"
GRADLE = os.path.join(ROOT, r"app\build.gradle.kts")
SETTINGS = os.path.join(ROOT, r"app\src\main\java\com\jz\musichelper\ui\SettingsScreen.kt")
OUT = r"C:\Users\17948\DoubaoWork\chats\2026-10-22\new-chat-1\_tmp_build\bump_out_2164.txt"

log = []

g = io.open(GRADLE, encoding="utf-8").read()
g2 = g.replace('versionCode = 121', 'versionCode = 122').replace('versionName = "2.1.63"', 'versionName = "2.1.64"')
assert g2 != g, "gradle version lines not found"
io.open(GRADLE, "w", encoding="utf-8").write(g2)
for ln in g2.splitlines():
    if "versionCode" in ln or "versionName" in ln:
        log.append("gradle| " + ln.strip())

s = io.open(SETTINGS, encoding="utf-8").read()
s2 = s.replace('Text("JZ的音乐助手 v2.1.63"', 'Text("JZ的音乐助手 v2.1.64"')
assert s2 != s, "settings title not found"
old_head = '"v2.1.63：除首页品牌栏的毛笔题字'
new_head = ('"v2.1.64：下载链路两条补齐——① 高品 320k / 标准 128k 也走自动换源：本平台后端 → 同曲跨源换源 → 通用搜索式后端兜底，'
            '直到拿到所选档为止；② 每条音源下完都按文件体积换算码率复核（无损看 flac/wav 容器，320k 认 256–600kbps，128k 认 48–255kbps），'
            '不符的文件直接丢弃并继续换源，全都不符才如实降级保存，下载列表里写清「所选 vs 实得」。'
            'v2.1.63：除首页品牌栏的毛笔题字')
assert old_head in s2, "settings changelog head not found"
s3 = s2.replace(old_head, new_head, 1)
io.open(SETTINGS, "w", encoding="utf-8").write(s3)
log.append("settings title/changelog updated")

io.open(OUT, "w", encoding="utf-8").write("\n".join(log))
print("\n".join(log))
