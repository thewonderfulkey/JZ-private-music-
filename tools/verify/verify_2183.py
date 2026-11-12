# -*- coding: utf-8 -*-
"""v2.1.83 交付前静态验证（apk-verify: badging / 签名 / 完整性 / 组件 / dex 口径）"""
import hashlib
import io
import os
import re
import shutil
import subprocess
import zipfile

ROOT = r"C:\Users\17948\DoubaoWork\chats\2026-10-22\new-chat-1"
APK_SRC = os.path.join(ROOT, r"JZMusicHelperAndroid\app\build\outputs\apk\release\app-release.apk")
APK = os.path.join(ROOT, "_tmp_fb3", "JZ音乐助手-v2.1.83.apk")
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
io.open(os.path.join(OUT, "badging_2183.txt"), "w", encoding="utf-8").write(txt)
m = re.search(r"versionCode='(\d+)' versionName='([^']+)'", txt)
ck("badging package", "package: name='com.jz.musichelper'" in txt)
ck("versionCode=141", bool(m) and m.group(1) == "141", m.group(1) if m else "none")
ck("versionName=2.1.83", bool(m) and m.group(2) == "2.1.83", m.group(2) if m else "none")
ck("RECORD_AUDIO permission", "android.permission.RECORD_AUDIO" in txt)
ck("SYSTEM_ALERT_WINDOW kept", "android.permission.SYSTEM_ALERT_WINDOW" in txt)
ck("FOREGROUND_SERVICE kept", "android.permission.FOREGROUND_SERVICE" in txt)
ck("launchable activity", "launchable-activity: name='com.jz.musichelper.MainActivity'" in txt)
ck("minSdk 26", "sdkVersion:'26'" in txt)

sign = subprocess.run([SIGNER, "verify", "--print-certs", "-v", APK], capture_output=True, env=env)
stxt = sign.stdout.decode("utf-8", "replace") + sign.stderr.decode("utf-8", "replace")
io.open(os.path.join(OUT, "sign_2183.txt"), "w", encoding="utf-8").write(stxt)
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


# ---- v2.1.83 本版改动：识曲独立页 + 结果直连起播 ----
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
ck("dex has privacy footer", zh("十秒采样只用于曲库比对，本机不留存") in dexblob)
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
ck("dex about says 2.1.83", zh("JZ的音乐助手 v2.1.83") in dexblob)
ck("dex no old about 2.1.82", zh("JZ的音乐助手 v2.1.82") not in dexblob)
ck("dex has 正在聆听", zh("正在聆听…") in dexblob)
ck("dex has NOPERM copy", zh("没拿到麦克风权限") in dexblob)
ck("dex has DesktopLyricsView kept", b"DesktopLyricsView" in dexblob)
ck("dex has krcToLines kept", b"krcToLines" in dexblob)

mp = subprocess.run([AAPT, "dump", "xmltree", APK, "--file", "AndroidManifest.xml"], capture_output=True, env=env)
mtxt = mp.stdout.decode("utf-8", "replace")
io.open(os.path.join(OUT, "manifest_2183.txt"), "w", encoding="utf-8").write(mtxt)
ck("manifest RECORD_AUDIO declared", "android.permission.RECORD_AUDIO" in mtxt)
ck("manifest PlayerService kept", "com.jz.musichelper.data.PlayerService" in mtxt)
ck("manifest TrackEndReceiver kept", "com.jz.musichelper.data.TrackEndReceiver" in mtxt)
ck("manifest foregroundServiceType=mediaPlayback(0x2)", "foregroundServiceType(0x01010599)=0x00000002" in mtxt)

adb = subprocess.run([ADB, "devices"], capture_output=True, env=env)
atxt = adb.stdout.decode("utf-8", "replace")
io.open(os.path.join(OUT, "adb_2183.txt"), "w", encoding="utf-8").write(atxt)
ck("adb device present", len([l for l in atxt.splitlines()[1:] if l.strip()]) > 0,
   atxt.strip().replace("\n", " "))

print("\nSIZE_BYTES=%d\nMD5=%s" % (size, md5))
print("\nFAILS: %d" % len(fails))
for f in fails:
    print("  - " + f)
