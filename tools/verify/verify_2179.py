# -*- coding: utf-8 -*-
import hashlib, io, re, shutil, subprocess, zipfile, os

ROOT = r"C:\Users\17948\DoubaoWork\chats\2026-10-22\new-chat-1"
APK_SRC = os.path.join(ROOT, r"JZMusicHelperAndroid\app\build\outputs\apk\release\app-release.apk")
APK = os.path.join(ROOT, "_tmp_fb3", "JZ音乐助手-v2.1.79.apk")
shutil.copyfile(APK_SRC, APK)

SDK = r"C:\Users\17948\AppData\Local\Android\Sdk"
AAPT = os.path.join(SDK, "build-tools", "34.0.0", "aapt2.exe")
SIGNER = os.path.join(SDK, "build-tools", "34.0.0", "apksigner.bat")
ADB = os.path.join(SDK, "platform-tools", "adb.exe")
OUT = os.path.join(ROOT, "_tmp_build")
SRC = os.path.join(ROOT, r"JZMusicHelperAndroid\app\src\main\java\com\jz\musichelper")

env = dict(os.environ)
env["JAVA_HOME"] = r"C:\Users\17948\AppData\Local\Programs\jdk-17"
env["ANDROID_HOME"] = SDK

fails = []
def ck(name, ok, detail=""):
    print(("PASS " if ok else "FAIL ") + name + ("  | " + detail if detail else ""))
    if not ok:
        fails.append(name)

size = os.path.getsize(APK)
md5 = hashlib.md5(open(APK, "rb").read()).hexdigest().upper()
print("SIZE %d bytes  MD5 %s" % (size, md5))

badging = subprocess.run([AAPT, "dump", "badging", APK], capture_output=True, env=env)
txt = badging.stdout.decode("utf-8", "replace")
io.open(os.path.join(OUT, "badging_2179.txt"), "w", encoding="utf-8").write(txt)
m = re.search(r"versionCode='(\d+)' versionName='([^']+)'", txt)
ck("badging package", "package: name='com.jz.musichelper'" in txt)
ck("versionCode=137", bool(m) and m.group(1) == "137", m.group(1) if m else "none")
ck("versionName=2.1.79", bool(m) and m.group(2) == "2.1.79", m.group(2) if m else "none")
ck("SYSTEM_ALERT_WINDOW", "android.permission.SYSTEM_ALERT_WINDOW" in txt)
ck("FOREGROUND_SERVICE", "android.permission.FOREGROUND_SERVICE" in txt)

sign = subprocess.run([SIGNER, "verify", "--print-certs", "-v", APK], capture_output=True, env=env)
stxt = sign.stdout.decode("utf-8", "replace") + sign.stderr.decode("utf-8", "replace")
io.open(os.path.join(OUT, "sign_2179.txt"), "w", encoding="utf-8").write(stxt)
ck("apksigner Verifies", "Verifies" in stxt and sign.returncode == 0)
ck("v2 scheme true", "v2 scheme (APK Signature Scheme v2): true" in stxt)
ck("single signer", "Number of signers: 1" in stxt)

z = zipfile.ZipFile(APK)
broken = z.testzip()
ck("zip integrity", broken is None, "broken=%s entries=%d" % (broken, len(z.namelist())))
ck("entry count sane", 150 < len(z.namelist()) < 260, "%d entries" % len(z.namelist()))

dexblob = b""
for n in z.namelist():
    if n.startswith("classes") and n.endswith(".dex"):
        dexblob += z.read(n)

ck("dex has LyricsBarAction", b"LyricsBarAction" in dexblob)
ck("dex has DesktopLyricsView", b"DesktopLyricsView" in dexblob)
ck("dex has LyricWord", b"LyricWord" in dexblob)
ck("dex has krcToLines", b"krcToLines" in dexblob)
ck("dex has qrcToLines", b"qrcToLines" in dexblob)
ck("dex has cleanLine", b"cleanLine" in dexblob)
ck("dex has setWordTiming", b"setWordTiming" in dexblob)
ck("dex has 2.1.79", "2.1.79".encode("utf-8") in dexblob)
ck("dex no old about 2.1.78", "JZ的音乐助手 v2.1.78".encode("utf-8") not in dexblob)
ck("dex about says 字数均分 no longer", "不再按字数均分".encode("utf-8") in dexblob)
ck("dex about says 去掉底边进度条", "去掉底边进度条".encode("utf-8") in dexblob)
ck("dex about says KRC / QRC", "KRC / QRC".encode("utf-8") in dexblob)
ck("dex has theme 素纸 #FBF7ED", b"#FBF7ED" in dexblob)
ck("dex has theme 夜墨 #24211D", b"#24211D" in dexblob)

# 源码级：进度条整段删除
view = io.open(os.path.join(SRC, r"ui\DesktopLyricsView.kt"), encoding="utf-8").read()
ck("src no drawProgress fn", "private fun drawProgress(" not in view)
ck("src no drawProgress call", "drawProgress(canvas" not in view)
ck("src no LinearGradient import", "LinearGradient" not in view)
ck("src no Shader import", "import android.graphics.Shader" not in view)
ck("src no progress shader", "linePaint.shader" not in view)
ck("src barHeight no 16dp reserved", "dp(12f) + dp(16f)" not in view)

# 源码级：逐字时间驱动染色
ck("src has LyricWord import", "import com.jz.musichelper.network.LyricWord" in view)
ck("src has buildCharTimes", "private fun buildCharTimes()" in view)
ck("src has charFill", "private fun charFill(index: Int)" in view)
ck("src has setWordTiming", "fun setWordTiming(words: List<LyricWord>)" in view)
ck("src has setPosition", "fun setPosition(ms: Long)" in view)
ck("src uses timed fill", "wSung += cw * charFill(idx)" in view)
ck("src timed guard", "val useTimed = timed && cur === curText" in view)
ck("src keeps ratio fallback", "} else if (ratio > 0f) {" in view)
ck("src char step splits word dur", "w.durMs / k" in view)

dl = io.open(os.path.join(SRC, r"data\DesktopLyrics.kt"), encoding="utf-8").read()
tick = dl.split("private fun tickOnce()")[1].split("private fun ")[0] if "private fun tickOnce()" in dl else ""
ck("src tick 100ms", "TICK_MS = 100L" in dl)
ck("src tickOnce pushes words", tick != "" and "setWordTiming(line.words)" in tick)
ck("src tickOnce pushes position", tick != "" and "setPosition(pos)" in tick)
ck("src tickOnce ratio only as fallback", tick != "" and "if (line.words.isEmpty())" in tick)

svc = io.open(os.path.join(SRC, r"network\LyricsService.kt"), encoding="utf-8").read()
ck("src LyricWord data class", "data class LyricWord(" in svc)
ck("src LyricLine has words default", "val words: List<LyricWord> = emptyList()" in svc)
ck("src cleanLine public", "fun cleanLine(raw: String): String" in svc)
ck("src parseLrc uses cleanLine", "val clean = cleanLine(text)" in svc)

cry = io.open(os.path.join(SRC, r"network\LddcCrypto.kt"), encoding="utf-8").read()
ck("src krcToLines", "fun krcToLines(plainKrc: String)" in cry)
ck("src qrcToLines", "fun qrcToLines(plainQrc: String)" in cry)
ck("src krc abs time = lineStart + s", "LyricWord(text, start + s, d)" in cry)
ck("src qrc adaptive base", "if (rawWords.first().second < start) start else 0L" in cry)

net = io.open(os.path.join(SRC, r"network\LddcLyrics.kt"), encoding="utf-8").read()
ck("src fetchKgLines", "private suspend fun fetchKgLines" in net)
ck("src fetchQqLines", "private suspend fun fetchQqLines" in net)
ck("src kg uses krcToLines", "LddcCrypto.krcToLines(plain)" in net)
ck("src qq uses qrcToLines", "LddcCrypto.qrcToLines(plain)" in net)
ck("src fetchOne returns word lines", "private suspend fun fetchOne(cand: LyricsCandidate): List<LyricLine>?" in net)

st = io.open(os.path.join(SRC, r"ui\SettingsScreen.kt"), encoding="utf-8").read()
ck("src about 2.1.79", "JZ的音乐助手 v2.1.79" in st)

mtxt = subprocess.run([AAPT, "dump", "xmltree", "--file", "AndroidManifest.xml", APK],
                      capture_output=True, env=env).stdout.decode("utf-8", "replace")
io.open(os.path.join(OUT, "manifest_2179.txt"), "w", encoding="utf-8").write(mtxt)
ck("MainActivity declared", "com.jz.musichelper.MainActivity" in mtxt)
ck("PlayerService declared", "PlayerService" in mtxt)
ck("TrackEndReceiver declared", "TrackEndReceiver" in mtxt)
ck("PlayerService mediaPlayback type",
   re.search(r"foregroundServiceType\(0x01010599\)=0x00000002", mtxt) is not None)

adb = subprocess.run([ADB, "devices"], capture_output=True, env=env).stdout.decode("utf-8", "replace")
io.open(os.path.join(OUT, "adb_2179.txt"), "w", encoding="utf-8").write(adb)
devs = [l for l in adb.splitlines()[1:] if l.strip()]
ck("adb device present", len(devs) > 0, "devices=%d (gap if 0)" % len(devs))

print("\nRESULT: %s" % ("ALL STATIC CHECKS PASS" if not fails else "FAILED: " + ", ".join(fails)))
