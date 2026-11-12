# -*- coding: utf-8 -*-
import os, zipfile, hashlib, re, sys

ROOT = r"C:\Users\17948\DoubaoWork\chats\2026-10-22\new-chat-1"
SRC = os.path.join(ROOT, r"JZMusicHelperAndroid\app\src\main\java\com\jz\musichelper")
APK = os.path.join(ROOT, r"JZMusicHelperAndroid\app\build\outputs\apk\release\app-release.apk")

def read(p):
    with open(p, "r", encoding="utf-8", errors="strict") as f:
        return f.read()

results = []
def chk(name, cond):
    results.append((name, bool(cond)))

app = read(os.path.join(SRC, r"ui\App.kt"))
pm  = read(os.path.join(SRC, r"data\PlayerManager.kt"))
ma  = read(os.path.join(SRC, r"MainActivity.kt"))
st  = read(os.path.join(SRC, r"ui\SettingsScreen.kt"))
ntc = read(os.path.join(SRC, r"data\NextTrackCache.kt"))
bg  = read(os.path.join(ROOT, r"JZMusicHelperAndroid\app\build.gradle.kts"))

chk("NextTrackCache 有固定缓存名 next.bin", "next.bin" in ntc)
chk("NextTrackCache 有 match/download", "fun match(" in ntc and "suspend fun download(" in ntc)
chk("App 抽出 resolveSourceOnce", "private suspend fun resolveSourceOnce(" in app)
chk("App 有 prefetchNext", "private fun prefetchNext()" in app)
chk("App 有 playFromCache", "private fun playFromCache(" in app)
chk("成功起播清红字", re.search(r"PlayLog\.log\(\"resolve OK", app) is not None and
    "resolveError.value = null   // v2.1.70" in app)
chk("advance 优先本地缓存", "NextTrackCache.match(it.platform.name + it.platformID)" in app)
chk("等待续播不再要求亮屏", "if (online) {" in app and "online && NetworkProbe.isInteractive()" not in app)
chk("q 形参为 QualityLevel", "q: com.jz.musichelper.model.QualityLevel" in app)
chk("PlayerManager 本地路径分支", 'mp.setDataSource(url.removePrefix("file://"))' in pm)
chk("MainActivity 初始化缓存", "NextTrackCache.init(this)" in ma)
chk("关于页 v2.1.70", "JZ的音乐助手 v2.1.70" in st)
chk("build vc128 / 2.1.70", "versionCode = 128" in bg and '"2.1.70"' in bg)

# APK 完整性
with zipfile.ZipFile(APK) as z:
    entries = z.namelist()
    bad = z.testzip()
chk("zip 无损坏条目", bad is None)
chk("条目数与上版同量级(>=170)", len(entries) >= 170)

size = os.path.getsize(APK)
md5 = hashlib.md5(open(APK, "rb").read()).hexdigest().upper()

lines = ["APK: %s" % APK, "SIZE: %d" % size, "MD5: %s" % md5, "ENTRIES: %d" % len(entries)]
for n, ok in results:
    lines.append("%s %s" % ("True " if ok else "FALSE", n))
lines.append("ALL_PASS: %s" % all(ok for _, ok in results))
out = "\n".join(lines)
with open(os.path.join(ROOT, r"_tmp_build\verify_2170.txt"), "w", encoding="utf-8") as f:
    f.write(out + "\n")
print(out)
