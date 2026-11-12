# -*- coding: utf-8 -*-
import os, zipfile, hashlib

ROOT = r"C:\Users\17948\DoubaoWork\chats\2026-10-22\new-chat-1"
SRC = os.path.join(ROOT, r"JZMusicHelperAndroid\app\src\main\java\com\jz\musichelper")
APK = os.path.join(ROOT, r"JZMusicHelperAndroid\app\build\outputs\apk\release\app-release.apk")

def read(p):
    with open(p, "r", encoding="utf-8") as f:
        return f.read()

app = read(os.path.join(SRC, r"ui\App.kt"))
ntc = read(os.path.join(SRC, r"data\NextTrackCache.kt"))
ma  = read(os.path.join(SRC, r"MainActivity.kt"))
st  = read(os.path.join(SRC, r"ui\SettingsScreen.kt"))
bg  = read(os.path.join(ROOT, r"JZMusicHelperAndroid\app\build.gradle.kts"))

res = []
def chk(n, c): res.append((n, bool(c)))

chk("缓存多槽保留", "MAX_SLOTS" in ntc and "prune()" in ntc)
chk("窗口预取 3 首保留", "(1..3).map" in app)
chk("首次启动自动申请保留", "ensureBatteryWhitelist" in ma)
chk("设置页白名单卡片常驻", "if (!ignoringBattery) {" not in st)
chk("白名单卡片有标题", "电池优化白名单" in st)
chk("未放行时显示去允许", '"去允许"' in st)
chk("已放行时显示查看设置", "查看系统电池设置" in st)
chk("状态会随返回刷新", "LaunchedEffect(Unit)" in st and "delay(1500)" in st)
chk("设置页仍无播放日志", "播放日志" not in st and "PlayLog.tail" not in st)
chk("关于页 v2.1.72", "JZ的音乐助手 v2.1.72" in st)
chk("build vc130 / 2.1.72", "versionCode = 130" in bg and '"2.1.72"' in bg)

with zipfile.ZipFile(APK) as z:
    entries = z.namelist()
    bad = z.testzip()
    dex = b"".join(z.read(n) for n in entries if n.endswith(".dex"))
chk("zip 无损坏", bad is None)
chk("条目数正常", len(entries) >= 170)
chk("DEX 含白名单 action", b"android.settings.REQUEST_IGNORE_BATTERY_OPTIMIZATIONS" in dex)

size = os.path.getsize(APK)
md5 = hashlib.md5(open(APK, "rb").read()).hexdigest().upper()
lines = ["APK: %s" % APK, "SIZE: %d" % size, "MD5: %s" % md5, "ENTRIES: %d" % len(entries)]
for n, ok in res:
    lines.append("%s %s" % ("True " if ok else "FALSE", n))
lines.append("ALL_PASS: %s" % all(ok for _, ok in res))
with open(os.path.join(ROOT, r"_tmp_build\verify_2172.txt"), "w", encoding="utf-8") as f:
    f.write("\n".join(lines) + "\n")
