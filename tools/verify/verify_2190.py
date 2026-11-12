# -*- coding: utf-8 -*-
"""v2.1.90 交付前静态断言：版本三方一致、签名、完整性、本次改动文案是否真进了 dex"""
import os, re, zipfile, subprocess, hashlib

APK = r"C:\Users\17948\DoubaoWork\chats\2026-10-22\new-chat-1\JZMusicHelperAndroid\app\build\outputs\apk\release\app-release.apk"
AAPT2 = r"C:\Users\17948\AppData\Local\Android\Sdk\build-tools\34.0.0\aapt2.exe"
APKSIGNER = r"C:\Users\17948\AppData\Local\Android\Sdk\build-tools\34.0.0\apksigner.bat"
GRADLE = r"C:\Users\17948\DoubaoWork\chats\2026-10-22\new-chat-1\JZMusicHelperAndroid\app\build.gradle.kts"
SETTINGS = r"C:\Users\17948\DoubaoWork\chats\2026-10-22\new-chat-1\JZMusicHelperAndroid\app\src\main\java\com\jz\musichelper\ui\SettingsScreen.kt"
SRC = r"C:\Users\17948\DoubaoWork\chats\2026-10-22\new-chat-1\JZMusicHelperAndroid\app\src\main\java\com\jz\musichelper"

results = []
def check(name, ok, detail=""):
    results.append((ok, name, detail))

size = os.path.getsize(APK)
md5 = hashlib.md5(open(APK, "rb").read()).hexdigest().upper()
check("APK 存在且量级合理", 25_000_000 < size < 35_000_000, f"{size} B, MD5 {md5}")

badging = subprocess.run([AAPT2, "dump", "badging", APK], capture_output=True).stdout.decode("utf-8", "replace")
check("包名", "name='com.jz.musichelper'" in badging)
check("versionCode=148", "versionCode='148'" in badging)
check("versionName=2.1.90", "versionName='2.1.90'" in badging)
check("minSdk 26 / target 34", "sdkVersion:'26'" in badging and "targetSdkVersion:'34'" in badging)

g = open(GRADLE, encoding="utf-8").read()
check("gradle 同步 148/2.1.90", "versionCode = 148" in g and '"2.1.90"' in g)
s = open(SETTINGS, encoding="utf-8").read()
check("关于页标题 v2.1.90", "JZ的音乐助手 v2.1.90" in s)

sign = subprocess.run([APKSIGNER, "verify", "--print-certs", APK], capture_output=True)
sign_txt = (sign.stdout + sign.stderr).decode("utf-8", "replace")
digest = re.search(r"certificate SHA-256 digest: (\w+)", sign_txt)
check("签名可验证", sign.returncode == 0 and digest is not None,
      "exit %d, SHA-256 %s" % (sign.returncode, (digest.group(1)[:16] + "...") if digest else "?"))
check("签名证书与历史一致", digest is not None and digest.group(1).lower().startswith("916ad2328810c691"),
      digest.group(1)[:16] if digest else "?")

with zipfile.ZipFile(APK) as z:
    bad = z.testzip()
    check("zip 完整性", bad is None, f"损坏条目 {bad}")
    dex = b"".join(z.read(n) for n in z.namelist() if n.endswith(".dex"))
    n = z.namelist()
check("含 classes.dex", any(x.endswith(".dex") for x in n))

def has(t):
    return t.encode("utf-8") in dex

check("dex 含 v2.1.90 标题", has("JZ的音乐助手 v2.1.90"))
check("dex 含「原唱」小印文案", has("原唱"))
check("dex 含 D 口径说明关键句", has("同一版录音被反复收录才算原唱"))
check("dex 含 上一版 v2.1.89 条目", has("上一版（v2.1.89）"))
# 「录音室版」作为小印应已被移除；源码里也应只剩关于页历史叙述
rec = open(os.path.join(SRC, "ui", "RecognizeScreen.kt"), encoding="utf-8").read()
check("RecognizeScreen 不再写「录音室版」小印", '"录音室版"' not in rec)
check("RecognizeScreen 小印来自 originals 集合", 'in originals' in rec)
app = open(os.path.join(SRC, "ui", "App.kt"), encoding="utf-8").read()
check("App 写入 recOriginals", "recOriginals.value = ordered.filter" in app)
check("App 按歌手+专辑+时长去重", '"|" + it.durationSec' in app)
judge = open(os.path.join(SRC, "network", "RecognizeAdapter.kt"), encoding="utf-8").read()
check("Judge 含 canonicalSingers", "fun canonicalSingers" in judge)
check("Judge 含 isVarietyAlbum", "fun isVarietyAlbum" in judge)
check("A 分支用 ±3s 聚簇", "s.durationSec - last.last().durationSec <= 3" in judge)

p = sum(1 for ok, _, _ in results if ok)
out = []
for ok, name, detail in results:
    out.append(("PASS " if ok else "FAIL ") + name + (("  — " + detail) if detail else ""))
out.append("")
out.append(f"{p} PASS / {len(results)-p} FAIL  |  {size} B  |  MD5 {md5}")
open(r"C:\Users\17948\DoubaoWork\chats\2026-10-22\new-chat-1\_tmp_build\verify_2190.txt", "w", encoding="utf-8").write("\n".join(out))
print("\n".join(out))
