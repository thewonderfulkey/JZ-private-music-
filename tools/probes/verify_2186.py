# -*- coding: utf-8 -*-
"""v2.1.86 静态验证：APK 完整性 + dex 文案断言 + 源码级版式断言 + 功能回归断言。"""
import hashlib, os, zipfile

APK = r"C:\Users\17948\DoubaoWork\chats\2026-10-22\new-chat-1\_tmp_fb3\JZ音乐助手-v2.1.86.apk"
SRC = r"C:\Users\17948\DoubaoWork\chats\2026-10-22\new-chat-1\JZMusicHelperAndroid\app\src\main\java\com\jz\musichelper"
GRADLE = r"C:\Users\17948\DoubaoWork\chats\2026-10-22\new-chat-1\JZMusicHelperAndroid\app\build.gradle.kts"
OUT = r"C:\Users\17948\DoubaoWork\chats\2026-10-22\new-chat-1\_tmp_build\verify_2186.txt"

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
FONT_SIZES = {19310488, 5857936}
embedded_font_sizes = {z.getinfo(n).file_size for n in names if n.endswith(".ttf")}
check("内嵌两款字体仍在（资源名已混淆，按字节数核对）", FONT_SIZES <= embedded_font_sizes, "ttf=%s" % sorted(embedded_font_sizes))

dex = b""
for n in names:
    if n.startswith("classes") and n.endswith(".dex"):
        dex += z.read(n)


def has(s):
    return s.encode("utf-8") in dex


# ---- 文案断言：v2.1.86 新版式的可见文字都进了包 ----
check("dex 含版本号 2.1.86", has("2.1.86"))
check("dex 含新眉标「识 所 得」", has("识 所 得"))
check("dex 含主操作文案「播放这首歌」", has("播放这首歌"))
check("dex 含「看看其他版本」", has("看看其他版本"))
check("dex 含「正在找其他版本…」", has("正在找其他版本"))
check("dex 含「其他版本」", has("其他版本"))
check("dex 含「原唱」标记", has("原唱"))
check("dex 含「同批候选」", has("同批候选"))
check("dex 含 PlayCache 类", b"PlayCache" in dex)
check("dex 含缓存切源日志标记", has("cache switch"))

# ---- 源码级断言（模板串在 dex 里不是字面量，只能看源码） ----
def src(rel):
    return open(os.path.join(SRC, rel), encoding="utf-8").read()


app = src(r"ui\App.kt")
rec = src(r"ui\RecognizeScreen.kt")
ps = src(r"ui\PlayerScreen.kt")
pc = src(r"data\PlayCache.kt")
pm = src(r"data\PlayerManager.kt")
ma = src(r"MainActivity.kt")
st = src(r"ui\SettingsScreen.kt")
gradle = open(GRADLE, encoding="utf-8").read()

check("结果签：方角 + 纸色 + 1px 淡墨线（无圆角）", ".background(p.surface)" in rec
      and ".border(1.dp, p.text.copy(alpha = 0.10f))" in rec)
check("结果签内边距 16/16/12/12", "padding(start = 16.dp, end = 16.dp, top = 12.dp, bottom = 12.dp)" in rec)
check("歌名 26sp / 行高 33sp", "fontSize = 26.sp" in rec and "lineHeight = 33.sp" in rec)
check("朱砂小印 SealMark 19dp", 'private fun SealMark(ch: String)' in rec and ".size(19.dp)" in rec)
check("书页式小标题 SectionHead", 'private fun SectionHead(label: String, count: String?)' in rec)
check("次级动作为文字链 TextLink", 'private fun TextLink(text: String, enabled: Boolean, onClick: () -> Unit)' in rec)
check("主操作是唯一墨块 44dp + PlayArrow", ".height(44.dp)" in rec and "Icons.Filled.PlayArrow" in rec)
def region(text, start, end):
    i = text.index(start)
    j = text.index(end, i)
    return text[i:j]
rb = region(rec, "private fun ResultBlock(", "private fun SealMark")
check("结果块内无圆角（RoundedCornerShape 不进入结果区）", "RoundedCornerShape" not in rb and "clip(" not in rb)
check("结果态麦克风缩到 0.72", "val micScale = if (phase == RecPhase.RESULT) 0.72f else 1f" in rec
      and ".height(252.dp * micScale)" in rec and "scale = micScale" in rec)
check("结果态舞台下间距收到 10dp", "if (phase == RecPhase.RESULT) 10.dp else 16.dp" in rec)
vr = region(rec, "private fun VersionRow(", "private fun NoteBlock")
check("版本行：朱砂细签 + 原唱印 + 发丝线", ".width(2.dp)" in vr and ".height(24.dp)" in vr
      and "原唱" in vr and "alpha = 0.07f" in vr and "alpha = 0.75f" in vr)
check("版本行行距 10/9", ".padding(top = 10.dp, bottom = 9.dp)" in rec)
check("结果区可滚 + 84dp 让位", "verticalScroll(rememberScrollState())" in rec and rec.count("84.dp") >= 2)
check("noExact 说明用朱砂细签而非错误框", "Modifier.width(2.dp).height(38.dp)" in rec)

# ---- 功能回归：v2.1.85 三条必须原样保留 ----
check("App.kt 严格歌手匹配（sameBoth 为空不硬播）",
      "val best = if (sameBoth.isNotEmpty()) StudioPick.pickBest(sameBoth) else null" in app)
check("App.kt 已有 loadRecVersions/clearRecVersions", "fun loadRecVersions(" in app and "fun clearRecVersions(" in app)
check("App.kt 原唱优先排序", "compareByDescending<Song> { isOriginal(it) }" in app)
check("App.kt 缓存挂接 attach", "PlayCache.attach(key, src.url)" in app)
check("App.kt 缓存切源（从当前位置续播）", "startAtMs = pos" in app and "switchToCachedWhenReady(key)" in app)
check("App.kt 播完释放缓存", "advanceAfterTrackEnd" in app and "PlayCache.clear()" in app)
check("PlayerScreen 进度条渲染缓存段", "cachedFrac" in ps and "drawRoundRect" in ps)
check("PlayCache 单槽落盘 + 清理", "play_cache" in pc and "fun clear()" in pc and "listFiles()?.forEach" in pc)
check("PlayCache 不落内存（只存路径）", "localPath: String?" in pc and "ByteArray(64 * 1024)" in pc)
check("PlayerManager play 支持 startAtMs", "startAtMs: Long = 0L" in pm and "seekTo(startAtMs" in pm)
check("MainActivity 初始化 PlayCache", "PlayCache.init(this)" in ma)

# ---- 版本一致性 ----
check("build.gradle versionCode 144", "versionCode = 144" in gradle)
check("build.gradle versionName 2.1.86", 'versionName = "2.1.86"' in gradle)
check("设置-关于 版本 2.1.86", "JZ的音乐助手 v2.1.86" in st)
check("设置-关于 本版更新写的是版式重做", "方角纸签" in st.split("本版更新")[1][:400])
check("设置-关于 保留上一版 v2.1.85 段落", "上一版（v2.1.85）" in st)
check("未残留 v2.1.85 关于页主标题", "JZ的音乐助手 v2.1.85" not in st)
check("build.gradle 未残留 2.1.85", "2.1.85" not in gradle)

lines.append("")
lines.append("SUMMARY  PASS=%d  FAIL=%d  (adb 真机冒烟缺口：本机 adb devices 恒空、无 AVD)" % (P, F))
open(OUT, "w", encoding="utf-8").write("\n".join(lines) + "\n")
print("\n".join(lines))
print("size=%d md5=%s" % (size, md5))
