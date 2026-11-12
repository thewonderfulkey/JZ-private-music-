# -*- coding: utf-8 -*-
"""v2.1.84 交付前静态验证（apk-verify: badging / 签名 / 完整性 / 组件 / dex 口径）"""
import hashlib
import io
import os
import re
import shutil
import subprocess
import zipfile

ROOT = r"C:\Users\17948\DoubaoWork\chats\2026-10-22\new-chat-1"
APK_SRC = os.path.join(ROOT, r"JZMusicHelperAndroid\app\build\outputs\apk\release\app-release.apk")
APK = os.path.join(ROOT, "_tmp_fb3", "JZ音乐助手-v2.1.84.apk")
shutil.copyfile(APK_SRC, APK)

SDK = r"C:\Users\17948\AppData\Local\Android\Sdk"
AAPT = os.path.join(SDK, "build-tools", "34.0.0", "aapt2.exe")
SIGNER = os.path.join(SDK, "build-tools", "34.0.0", "apksigner.bat")
ADB = os.path.join(SDK, "platform-tools", "adb.exe")
OUT = os.path.join(ROOT, "_tmp_build")

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
io.open(os.path.join(OUT, "badging_2184.txt"), "w", encoding="utf-8").write(txt)
m = re.search(r"versionCode='(\d+)' versionName='([^']+)'", txt)
ck("badging package", "package: name='com.jz.musichelper'" in txt)
ck("versionCode=142", bool(m) and m.group(1) == "142", m.group(1) if m else "none")
ck("versionName=2.1.84", bool(m) and m.group(2) == "2.1.84", m.group(2) if m else "none")
ck("RECORD_AUDIO permission", "android.permission.RECORD_AUDIO" in txt)
ck("SYSTEM_ALERT_WINDOW kept", "android.permission.SYSTEM_ALERT_WINDOW" in txt)
ck("FOREGROUND_SERVICE kept", "android.permission.FOREGROUND_SERVICE" in txt)
ck("launchable activity", "launchable-activity: name='com.jz.musichelper.MainActivity'" in txt)
ck("minSdk 26", "sdkVersion:'26'" in txt)

sign = subprocess.run([SIGNER, "verify", "--print-certs", "-v", APK], capture_output=True, env=env)
stxt = sign.stdout.decode("utf-8", "replace") + sign.stderr.decode("utf-8", "replace")
io.open(os.path.join(OUT, "sign_2184.txt"), "w", encoding="utf-8").write(stxt)
ck("apksigner Verifies", "Verifies" in stxt and sign.returncode == 0)
ck("v2 scheme true", "v2 scheme (APK Signature Scheme v2): true" in stxt)
ck("single signer", "Number of signers: 1" in stxt)

z = zipfile.ZipFile(APK)
broken = z.testzip()
ck("zip integrity", broken is None, "broken=%s entries=%d" % (broken, len(z.namelist())))
ck("entry count sane", 150 < len(z.namelist()) < 300, "%d entries" % len(z.namelist()))

dexblob = b""
for n in z.namelist():
    if n.startswith("classes") and n.endswith(".dex"):
        dexblob += z.read(n)


def zh(s):
    return s.encode("utf-8")


# ---- v2.1.84 本版四条改动 ----
ck("dex has cancel-on-tap hint", zh("再点一下麦克风，就取消这次识别") in dexblob)
ck("dex has think-cancel hint", zh("比对曲库中，稍等；再点一下麦克风就取消") in dexblob)
ck("dex has duration button copy", zh("听多久") in dexblob)
# 四档是 "$s 秒" 模板字符串，dex 里没有 "15 秒" 这种字面量，判据放到源码级（见下方 SOURCE 段）
ck("dex has DurationButton", b"DurationButton" in dexblob)
ck("dex has DurationMenu", b"DurationMenu" in dexblob)
ck("dex has dynamic footer", zh(" 秒采样只用于曲库比对，本机不留存") in dexblob)
ck("dex no hardcoded 十秒 footer", zh("十秒采样只用于曲库比对，本机不留存") not in dexblob)
ck("dex has instant-player placeholder prefix", b"__pending__:" in dexblob)
ck("dex has rec history pref key", b"rec_history" in dexblob)
ck("dex has rec seconds pref key", b"rec_seconds" in dexblob)
ck("dex has recHistoryMax 50", b"REC_HISTORY_MAX" in dexblob)
ck("dex has recent-list tap hint", zh("点一条直接播放") in dexblob)
ck("dex has about says 2.1.84", zh("JZ的音乐助手 v2.1.84") in dexblob)
ck("dex no old about 2.1.83", zh("JZ的音乐助手 v2.1.83") not in dexblob)

# ---- v2.1.83 能力不回退 ----
ck("dex has RecognizePage", b"RecognizePage" in dexblob)
ck("dex has playRecognizedHit", b"playRecognizedHit" in dexblob)
ck("dex has recPlayBusy/recRecent", b"recPlayBusy" in dexblob and b"recRecent" in dexblob)
ck("dex has 识曲 tab label", zh("识曲") in dexblob)
ck("dex has idle hint", zh("点一下麦克风，开始听") in dexblob)
ck("dex has 最近识过", zh("最近识过") in dexblob)
ck("dex has busy button", zh("正在起播…") in dexblob)
ck("dex has 其他版本", zh("其他版本") in dexblob)
ck("dex has 第一次用 hint", zh("第一次用？") in dexblob)
ck("dex has 三件小事 tips", zh("三件小事") in dexblob)
ck("dex has replay hint", zh("再点一下麦克风，可以重听") in dexblob)
ck("dex no old overlay class", b"RecognizeOverlay" not in dexblob)
ck("dex no old entry bar class", b"RecognizeEntryBar" not in dexblob)
ck("dex no old search-jump toast", zh("已按平台搜索") not in dexblob)
ck("dex no old bar subtitle", zh("把手机靠近声源，听十秒") not in dexblob)
# ---- 既有能力不回退 ----
ck("dex has RecognizeAdapter", b"RecognizeAdapter" in dexblob)
ck("dex has VoiceCapture", b"VoiceCapture" in dexblob)
ck("dex has to8k resampler", b"to8k" in dexblob)
ck("dex has gateway endpoint", b"gateway.kugou.com/fingerprint.service/v1/music_trackid_mulit" in dexblob)
ck("dex has kg salt", b"LnT6xpN3khm36zse0QzvmgTZ3waWdRSA" in dexblob)
ck("dex has KuGou/11490 UA", b"KuGou/11490 (Android)" in dexblob)
ck("dex has DB hint", b"dB" in dexblob)
ck("dex has silence-threshold hint", zh("几乎没听到声音（峰值") in dexblob)
ck("dex has kugou-miss copy", zh("曲库里没对上") in dexblob)
ck("dex has no-candidate copy", zh("但这几平台都没给出可播的条目") in dexblob)
ck("dex has 正在聆听", zh("正在聆听…") in dexblob)
ck("dex has NOPERM copy", zh("没拿到麦克风权限") in dexblob)
ck("dex has DesktopLyricsView kept", b"DesktopLyricsView" in dexblob)
ck("dex has krcToLines kept", b"krcToLines" in dexblob)

mp = subprocess.run([AAPT, "dump", "xmltree", APK, "--file", "AndroidManifest.xml"], capture_output=True, env=env)
mtxt = mp.stdout.decode("utf-8", "replace")
io.open(os.path.join(OUT, "manifest_2184.txt"), "w", encoding="utf-8").write(mtxt)
ck("manifest RECORD_AUDIO declared", "android.permission.RECORD_AUDIO" in mtxt)
ck("manifest PlayerService kept", "com.jz.musichelper.data.PlayerService" in mtxt)
ck("manifest TrackEndReceiver kept", "com.jz.musichelper.data.TrackEndReceiver" in mtxt)
ck("manifest foregroundServiceType=mediaPlayback(0x2)", "foregroundServiceType(0x01010599)=0x00000002" in mtxt)

adb = subprocess.run([ADB, "devices"], capture_output=True, env=env)
atxt = adb.stdout.decode("utf-8", "replace")
io.open(os.path.join(OUT, "adb_2184.txt"), "w", encoding="utf-8").write(atxt)
ck("adb device present", len([l for l in atxt.splitlines()[1:] if l.strip()]) > 0,
   atxt.strip().replace("\n", " "))

# ---- 源码级断言（字节码里看不到模板字符串与具体字面量时，改在这里判）----
SRC = os.path.join(ROOT, r"JZMusicHelperAndroid\app\src\main\java\com\jz\musichelper")
rs = io.open(os.path.join(SRC, r"ui\RecognizeScreen.kt"), encoding="utf-8").read()
vc = io.open(os.path.join(SRC, r"data\VoiceCapture.kt"), encoding="utf-8").read()
hs = io.open(os.path.join(SRC, r"data\HistoryStore.kt"), encoding="utf-8").read()
ck("src duration options 5/10/15/20", "listOf(5, 10, 15, 20)" in rs)
ck("src no old top-right 听十秒 Text", 'Text("听十秒"' not in rs)
ck("src mic tap cancels while listening", "if (listening) AppState.cancelRecognize() else start()" in rs)
ap = io.open(os.path.join(SRC, r"ui\App.kt"), encoding="utf-8").read()
ck("src startRecognize uses recSeconds", "seconds = recSeconds.value" in ap)
ck("src playRecognizedHit shows placeholder first", "currentSong.value = placeholder" in ap and
   ap.index("currentSong.value = placeholder") < ap.index("SearchService.searchAll(kw, 30)"))
ck("src rememberHit persists", "HistoryStore.saveRecHistory" in ap)
ck("src recRecent loads from store", "HistoryStore.loadRecHistory()" in ap)
ck("src VoiceCapture has NO leftover finishEarly", "finishEarly" not in vc and "finishFlag" not in vc)
ck("src VoiceCapture min/max seconds", "const val MIN_SECONDS = 5" in vc and "const val MAX_SECONDS = 20" in vc)
ck("src HistoryStore rec max 50", "const val REC_HISTORY_MAX = 50" in hs)

print("\nSIZE_BYTES=%d\nMD5=%s" % (size, md5))
print("\nFAILS: %d" % len(fails))
for f in fails:
    print("  - " + f)
