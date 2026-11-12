# -*- coding: utf-8 -*-
"""v2.1.87 交付前验证：APK 完整性 + 签名/badging + dex 断言 + 源码级改动断言 + 回归断言。"""
import hashlib
import os
import re
import zipfile

APK = r"C:\Users\17948\DoubaoWork\chats\2026-10-22\new-chat-1\_tmp_fb4\JZ音乐助手-v2.1.87.apk"
SRC = r"C:\Users\17948\DoubaoWork\chats\2026-10-22\new-chat-1\JZMusicHelperAndroid\app\src\main\java\com\jz\musichelper"
GRADLE = r"C:\Users\17948\DoubaoWork\chats\2026-10-22\new-chat-1\JZMusicHelperAndroid\app\build.gradle.kts"
BADGING = r"C:\Users\17948\DoubaoWork\chats\2026-10-22\new-chat-1\_tmp_build\badging_2187.txt"
SIGN = r"C:\Users\17948\DoubaoWork\chats\2026-10-22\new-chat-1\_tmp_build\sign_2187.txt"
OUT = r"C:\Users\17948\DoubaoWork\chats\2026-10-22\new-chat-1\_tmp_build\verify_2187.txt"

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
check("含 classes*.dex", any(n.startswith("classes") and n.endswith(".dex") for n in names), "entries=%d" % len(names))
FONT_SIZES = {19310488, 5857936}
embedded_font_sizes = {z.getinfo(n).file_size for n in names if n.endswith(".ttf")}
check("内嵌两款字体仍在（按字节数核对）", FONT_SIZES <= embedded_font_sizes, "ttf=%s" % sorted(embedded_font_sizes))

dex = b""
for n in names:
    if n.startswith("classes") and n.endswith(".dex"):
        dex += z.read(n)


def has(s):
    return s.encode("utf-8") in dex


# ---- badging / 签名 ----
badging = open(BADGING, encoding="utf-8", errors="ignore").read()
check("badging 包名 com.jz.musichelper", "name='com.jz.musichelper'" in badging)
check("badging versionCode 145", "versionCode='145'" in badging)
check("badging versionName 2.1.87", "versionName='2.1.87'" in badging)
sign = open(SIGN, encoding="utf-8", errors="ignore").read()
check("签名有效且为既有 debug 证书",
      "Signer #1 certificate SHA-256 digest: 916ad2328810c691a4022d9716a77709e9ebb08aa262b373c0b05b8c6aed07ac" in sign,
      sign.strip().splitlines()[-1] if sign.strip() else "empty")

# ---- dex 断言：本次改动的新字面量与版本号都进了包 ----
check("dex 含版本号 2.1.87", has("2.1.87"))
check("dex 含酷我封面 base wmvpic", has("wmvpic"))
check("dex 含 img1.kuwo.cn", has("img1.kuwo.cn"))
check("dex 含酷我歌词端点", has("openapi/v1/www/lyric/getlyric"))
check("dex 含 httpsStatus 参数", has("httpsStatus"))
check("dex 含 MVPIC 字段名", has("MVPIC"))
check("dex 含 KwLyrics 类", b"KwLyrics" in dex)
check("dex 含来源标签「酷我」", has("酷我"))


def src(rel):
    return open(os.path.join(SRC, rel), encoding="utf-8").read()


sa = src(r"network\SearchAdapters.kt")
ls = src(r"network\LyricsService.kt")
kw = src(r"network\KwLyrics.kt")
st = src(r"ui\SettingsScreen.kt")
gradle = open(GRADLE, encoding="utf-8").read()

# ---- 酷我封面落码 ----
check("酷我搜索读取 MVPIC 字段", 'val mvpic = item["MVPIC"]' in sa)
check("MVPIC 拼 img1 的 wmvpic 直链", '"https://img1.kuwo.cn/wmvpic/$mvpic"' in sa)
check("酷我 Song 不再写死 null 封面", "songs.add(Song(MusicPlatform.KUWO, rawRid, name, artist, album, dur, pic))" in sa)
check("MVPIC 空值仍为 null（保留 QQ 兜底）", "if (mvpic.isNotEmpty())" in sa)

# ---- 酷我歌词落码 ----
check("KwLyrics 只接受纯数字 rid", "platformID.filter { it.isDigit() }" in kw)
check("KwLyrics 校验 code==200", 'json.optInt("code", -1) != 200' in kw)
check("KwLyrics 判空防 data:{}（不是报错）",
      'optJSONArray("lrclist") ?: return null' in kw and "if (out.isEmpty()) return null" in kw)
check("KwLyrics 复用统一清洗 cleanLine", "LyricsService.cleanLine(item.optString(\"lineLyric\", \"\"))" in kw)
check("KwLyrics 时间秒→毫秒", "(d * 1000).toLong()" in kw)
check("KwLyrics 按时间重排", "out.sortedBy { it.timeMs }" in kw)
check("LyricsService 酷我优先分派", "if (song.platform == MusicPlatform.KUWO)" in ls
      and "KwLyrics.fetch(song.platformID)" in ls)
check("LyricsService 酷我空词回退 LDDC", "val lines = runCatching { LddcLyrics.fetch(song) }.getOrNull()" in ls)
check("LyricsService 来源标签区分", 'LyricsResult(kw, "酷我")' in ls and 'LyricsResult(lines, "LDDC")' in ls)
check("歌词缓存 key 未变（不破坏原有缓存）", 'val key = song.platform.name + "|" + song.platformID' in ls)

# ---- 版本一致性 / 关于页 ----
check("build.gradle versionCode 145", "versionCode = 145" in gradle)
check("build.gradle versionName 2.1.87", 'versionName = "2.1.87"' in gradle)
check("build.gradle 未残留 2.1.86", "2.1.86" not in gradle)
check("设置-关于 主标题 v2.1.87", "JZ的音乐助手 v2.1.87" in st)
about_new = st.split("本版更新")[1][:400]
check("关于本版更新写的是封面+歌词", ("MVPIC" in about_new or "曲图" in about_new) and "官方歌词接口" in about_new)
check("关于保留上一版 v2.1.86 段落", "上一版（v2.1.86）" in st)
check("未残留 v2.1.86 主标题", "JZ的音乐助手 v2.1.86" not in st)
check("未残留 v2.1.85 段落", "v2.1.85" not in st)

# ---- 回归：不得破坏既有链路 ----
check("LDDC 双源仍在（非酷我歌曲走原路径）", "LddcLyrics.fetch(song)" in ls)
check("CoverResolver 兜底仍然存在", "imgessl" in src(r"network\CoverResolver.kt"))
check("酷我搜索仍带 vipver 老客户端参数", "vipver=MUSIC_8.7.8.0_WX" in sa)
check("酷我变体过滤未动", "isKuwoVariant(name)" in sa)
check("酷我取流适配器未动", "YaohuKuwoAdapter" in src(r"network\SourceAdapters.kt"))

lines.append("")
lines.append("SUMMARY  PASS=%d  FAIL=%d  (adb 真机冒烟缺口：本机 adb devices 恒空、无 AVD；"
             "酷我封面/歌词为真实接口，需真机联网复验)" % (P, F))
open(OUT, "w", encoding="utf-8").write("\n".join(lines) + "\n")
print("\n".join(lines))
print("size=%d md5=%s" % (size, md5))
