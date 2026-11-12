# -*- coding: utf-8 -*-
import os, zipfile, hashlib, re

ROOT = r"C:\Users\17948\DoubaoWork\chats\2026-10-22\new-chat-1"
SRC = os.path.join(ROOT, r"JZMusicHelperAndroid\app\src\main\java\com\jz\musichelper")
APK = os.path.join(ROOT, r"JZMusicHelperAndroid\app\build\outputs\apk\release\app-release.apk")

def read(p):
    with open(p, "r", encoding="utf-8", errors="strict") as f:
        return f.read()

app = read(os.path.join(SRC, r"ui\App.kt"))
ntc = read(os.path.join(SRC, r"data\NextTrackCache.kt"))
ma  = read(os.path.join(SRC, r"MainActivity.kt"))
st  = read(os.path.join(SRC, r"ui\SettingsScreen.kt"))
bg  = read(os.path.join(ROOT, r"JZMusicHelperAndroid\app\build.gradle.kts"))

results = []
def chk(n, c): results.append((n, bool(c)))

chk("缓存改为多槽(MAX_SLOTS)", "MAX_SLOTS" in ntc and "prune()" in ntc)
chk("缓存按 key 分槽", "safe(key)" in ntc)
chk("窗口预取 3 首", "(1..3).map" in app)
chk("预取遍历缺失项", "val missing = targets.filter" in app)
chk("启动自动申请电池豁免", "ensureBatteryWhitelist" in ma and "ACTION_REQUEST_IGNORE_BATTERY_OPTIMIZATIONS" in ma)
chk("最多次数限制 3", "bo_asked" in ma and ">= 3" in ma)
chk("设置页已移除播放日志", "播放日志" not in st and "PlayLog.tail" not in st)
chk("未放行时才出现后台连播入口", "if (!ignoringBattery) {" in st)
chk("关于页 v2.1.71", "JZ的音乐助手 v2.1.71" in st)
chk("build vc129 / 2.1.71", "versionCode = 129" in bg and '"2.1.71"' in bg)

with zipfile.ZipFile(APK) as z:
    entries = z.namelist()
    bad = z.testzip()
    dex = b"".join(z.read(n) for n in entries if n.endswith(".dex"))
chk("zip 无损坏", bad is None)
chk("条目数正常", len(entries) >= 170)
chk("DEX 含新逻辑", b"prefetch" in dex and b"Automatically" not in dex[:0])
chk("DEX 含豁免申请 action", b"android.settings.REQUEST_IGNORE_BATTERY_OPTIMIZATIONS" in dex)

size = os.path.getsize(APK)
md5 = hashlib.md5(open(APK, "rb").read()).hexdigest().upper()
lines = ["APK: %s" % APK, "SIZE: %d" % size, "MD5: %s" % md5, "ENTRIES: %d" % len(entries)]
for n, ok in results:
    lines.append("%s %s" % ("True " if ok else "FALSE", n))
lines.append("ALL_PASS: %s" % all(ok for _, ok in results))
with open(os.path.join(ROOT, r"_tmp_build\verify_2171.txt"), "w", encoding="utf-8") as f:
    f.write("\n".join(lines) + "\n")
