# -*- coding: utf-8 -*-
"""v2.1.85 静态验证：APK 完整性 + dex 字符串/类断言 + 构建产物核算。"""
import hashlib, os, re, zipfile, sys

APK = r"C:\Users\17948\DoubaoWork\chats\2026-10-22\new-chat-1\_tmp_fb3\JZ音乐助手-v2.1.85.apk"
SRC = r"C:\Users\17948\DoubaoWork\chats\2026-10-22\new-chat-1\JZMusicHelperAndroid\app\src\main\java\com\jz\musichelper"
OUT = r"C:\Users\17948\DoubaoWork\chats\2026-10-22\new-chat-1\_tmp_build\verify_2185.txt"

lines = []
P = F = 0
def check(name, ok, detail=""):
    global P, F
    if ok:
        P += 1
        lines.append("PASS  %s  %s" % (name, detail))
    else:
        F += 1
        lines.append("FAIL  %s  %s" % (name, detail))

size = os.path.getsize(APK)
md5 = hashlib.md5(open(APK, "rb").read()).hexdigest().upper()
check("APK 存在且大小合理", 25_000_000 < size < 40_000_000, "%d B / MD5 %s" % (size, md5))

z = zipfile.ZipFile(APK)
bad = z.testzip()
check("zip 完整性（无损坏条目）", bad is None, "first_bad=%s" % bad)
names = z.namelist()
check("含 classes.dex", any(n.startswith("classes") and n.endswith(".dex") for n in names), "entries=%d" % len(names))

dex = b""
for n in names:
    if n.startswith("classes") and n.endswith(".dex"):
        dex += z.read(n)

def has(s):
    return s.encode("utf-8") in dex

# ---- 功能断言：v2.1.85 三条改动的关键字符串 / 类是否进包 ----
check("dex 含版本号 2.1.85", has("2.1.85"))
check("dex 含「其他版本」按钮文案", has("其他版本"))
check("dex 含「原唱」标记", has("原唱"))
check("dex 含缓存切源文案「本地缓存」", has("本地缓存"))
check("dex 含同名不同人提示前缀", has("但曲库里没有这一位歌手的可播条目"))
check("dex 含 PlayCache 类", b"PlayCache" in dex)
check("dex 含缓存切换日志标记", has("cache switch"))
check("dex 含「同批候选」", has("同批候选"))
check("dex 含「正在找…」占位", has("正在找"))

# ---- 源码级断言（dex 里是模板串，不能直接断言） ----
def src(rel):
    return open(os.path.join(SRC, rel), encoding="utf-8").read()

app = src(r"ui\App.kt")
rec = src(r"ui\RecognizeScreen.kt")
ps = src(r"ui\PlayerScreen.kt")
pc = src(r"data\PlayCache.kt")
pm = src(r"data\PlayerManager.kt")
ma = src(r"MainActivity.kt")
st = src(r"ui\SettingsScreen.kt")

check("App.kt 严格歌手匹配（sameBoth 为空不硬播）", "val best = if (sameBoth.isNotEmpty()) StudioPick.pickBest(sameBoth) else null" in app)
check("App.kt 已有 loadRecVersions/clearRecVersions", "fun loadRecVersions(" in app and "fun clearRecVersions(" in app)
check("App.kt 原唱优先排序", "compareByDescending<Song> { isOriginal(it) }" in app)
check("App.kt 缓存挂接 attach", "PlayCache.attach(key, src.url)" in app)
check("App.kt 缓存切源（从当前位置续播）", "startAtMs = pos" in app and "switchToCachedWhenReady(key)" in app)
check("App.kt 播完释放缓存", "private fun advanceAfterTrackEnd(tag: String) {\n        // v2.1.85：这首放完就释放播放缓存" in app.replace("\r\n","\n") and "advanceAfterTrackEnd" in app)
check("RecognizeScreen 其他版本按钮", "其他版本（${versions.size}）" in rec)
check("RecognizeScreen 结果区可滚 + 84dp 让位", "verticalScroll(rememberScrollState())" in rec and "84.dp" in rec)
check("RecognizeScreen 最近识过 84dp 让位", rec.count("84.dp") >= 2)
check("PlayerScreen 进度条渲染缓存段", "cachedFrac" in ps and "drawRoundRect" in ps)
check("PlayCache 单槽落盘 + 清理", "play_cache" in pc and "fun clear()" in pc and "listFiles()?.forEach" in pc)
check("PlayCache 不落内存（只存路径）", "localPath: String?" in pc and "ByteArray(64 * 1024)" in pc)
check("PlayerManager play 支持 startAtMs", "startAtMs: Long = 0L" in pm and "seekTo(startAtMs" in pm)
check("MainActivity 初始化 PlayCache", "PlayCache.init(this)" in ma)
check("设置-关于 版本 2.1.85", "JZ的音乐助手 v2.1.85" in st)
check("设置-关于 本版更新写的是本轮三条", "其他版本" in st.split("本版更新")[1][:400])

# ---- 不该出现的残留 ----
check("未残留 v2.1.84 关于页文案", "JZ的音乐助手 v2.1.84" not in st)
check("未把 2.1.84 留在 build.gradle", "2.1.84" not in open(r"C:\Users\17948\DoubaoWork\chats\2026-10-22\new-chat-1\JZMusicHelperAndroid\app\build.gradle.kts", encoding="utf-8").read())

lines.append("")
lines.append("SUMMARY  PASS=%d  FAIL=%d  (adb 真机冒烟缺口：本机 adb devices 恒空、无 AVD)" % (P, F))
open(OUT, "w", encoding="utf-8").write("\n".join(lines) + "\n")
print("\n".join(lines))
print("size=%d md5=%s" % (size, md5))
