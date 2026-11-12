# -*- coding: utf-8 -*-
import hashlib, io, re, shutil, subprocess, zipfile, os

ROOT = r"C:\Users\17948\DoubaoWork\chats\2026-10-22\new-chat-1"
APK_SRC = os.path.join(ROOT, r"JZMusicHelperAndroid\app\build\outputs\apk\release\app-release.apk")
APK = os.path.join(ROOT, "_tmp_fb3", "JZ音乐助手-v2.1.82.apk")
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
io.open(os.path.join(OUT, "badging_2181.txt"), "w", encoding="utf-8").write(txt)
m = re.search(r"versionCode='(\d+)' versionName='([^']+)'", txt)
ck("badging package", "package: name='com.jz.musichelper'" in txt)
ck("versionCode=140", bool(m) and m.group(1) == "140", m.group(1) if m else "none")
ck("versionName=2.1.82", bool(m) and m.group(2) == "2.1.82", m.group(2) if m else "none")
ck("RECORD_AUDIO permission", "android.permission.RECORD_AUDIO" in txt)
ck("SYSTEM_ALERT_WINDOW kept", "android.permission.SYSTEM_ALERT_WINDOW" in txt)
ck("FOREGROUND_SERVICE kept", "android.permission.FOREGROUND_SERVICE" in txt)
ck("launchable activity", "launchable-activity: name='com.jz.musichelper.MainActivity'" in txt)
ck("minSdk 26", "sdkVersion:'26'" in txt)

sign = subprocess.run([SIGNER, "verify", "--print-certs", "-v", APK], capture_output=True, env=env)
stxt = sign.stdout.decode("utf-8", "replace") + sign.stderr.decode("utf-8", "replace")
io.open(os.path.join(OUT, "sign_2181.txt"), "w", encoding="utf-8").write(stxt)
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

ck("dex has RecognizeAdapter", b"RecognizeAdapter" in dexblob)
ck("dex has RecognizeEntryBar", b"RecognizeEntryBar" in dexblob)
ck("dex has RecognizeOverlay", b"RecognizeOverlay" in dexblob)
ck("dex has VoiceCapture", b"VoiceCapture" in dexblob)
ck("dex has open/closeRecognize", b"openRecognize" in dexblob and b"closeRecognize" in dexblob)
ck("dex has recPhase/recError", b"recPhase" in dexblob and b"recError" in dexblob)
ck("dex has gateway endpoint", b"gateway.kugou.com/fingerprint.service/v1/music_trackid_mulit" in dexblob)
ck("dex has kg salt", b"LnT6xpN3khm36zse0QzvmgTZ3waWdRSA" in dexblob)
ck("dex has KuGou/11490 UA", b"KuGou/11490 (Android)" in dexblob)
ck("dex about says 2.1.82", "JZ的音乐助手 v2.1.82".encode("utf-8") in dexblob)
ck("dex no old about 2.1.81", "JZ的音乐助手 v2.1.81".encode("utf-8") not in dexblob)
ck("dex has 听歌识曲 label", "听歌识曲".encode("utf-8") in dexblob)
ck("dex has new bar subtitle", "把手机靠近声源，听十秒".encode("utf-8") in dexblob)
ck("dex no old bar subtitle", "听 10 秒，认出正在放的这首歌".encode("utf-8") not in dexblob)
ck("dex has 正在聆听", "正在聆听…".encode("utf-8") in dexblob)
ck("dex has NOPERM state text", "没拿到麦克风权限".encode("utf-8") in dexblob)
ck("dex has 再授一次", "再授一次".encode("utf-8") in dexblob)
ck("dex has 再听一次", "再听一次".encode("utf-8") in dexblob)
ck("dex has 去播放", "去播放".encode("utf-8") in dexblob)
# v2.1.82：采集改原生采样率 + 平均降 8k；判据改实测 AC-RMS
ck("dex has to8k resampler", b"to8k" in dexblob)
ck("dex has Capture result type", b"peakRms" in dexblob and b"sourceRate" in dexblob)
# R8 会把字段名/常量数组折掉，"VOICE_RECOGNITION"、"48000" 这类字符串不一定进 dex 字符串池，
# 因此改断言"旧文案已被新文案取代"——这是能真正证明分支被替换的判据
ck("dex no old silence copy", "几乎没听到声音：把手机靠近声源，或调大外放音量".encode("utf-8") not in dexblob)
ck("dex no old empty-library copy", "曲库里没对上：换个安静点的地方、贴近音箱再试一次".encode("utf-8") not in dexblob)
ck("dex has silence-threshold hint", "几乎没听到声音（峰值".encode("utf-8") in dexblob)
ck("dex has peak-db hint", b"dB" in dexblob)
ck("dex has empty-library hint", "曲库里没对上：贴近音箱".encode("utf-8") in dexblob)
# 旧问题的关键是把异常原文透到界面；Compose 库自带那句英文常量永远在 dex 里，
# 所以不能靠"整包搜字符串"判定，改为断言我们自己的中文兜底文案在（且旧的英文透出路径已删）
ck("dex has human-readable error hint", "识别失败，稍后再试".encode("utf-8") in dexblob)
ck("dex has mic-occupied hint", "麦克风被占用或系统没放开".encode("utf-8") in dexblob)
ck("dex has network hint", "网络不通，检查网络后再试".encode("utf-8") in dexblob)
# 桌面歌词那套仍在（不能因为新增功能打断旧功能）
ck("dex has DesktopLyricsView kept", b"DesktopLyricsView" in dexblob)
ck("dex has krcToLines kept", b"krcToLines" in dexblob)

mp = subprocess.run([AAPT, "dump", "xmltree", APK, "--file", "AndroidManifest.xml"], capture_output=True, env=env)
mtxt = mp.stdout.decode("utf-8", "replace")
io.open(os.path.join(OUT, "manifest_2181.txt"), "w", encoding="utf-8").write(mtxt)
ck("manifest RECORD_AUDIO declared", 'android.permission.RECORD_AUDIO' in mtxt)
ck("manifest PlayerService kept", 'com.jz.musichelper.data.PlayerService' in mtxt)
ck("manifest TrackEndReceiver kept", 'com.jz.musichelper.data.TrackEndReceiver' in mtxt)
ck("manifest foregroundServiceType=mediaPlayback(0x2)", 'foregroundServiceType(0x01010599)=0x00000002' in mtxt)

adb = subprocess.run([ADB, "devices"], capture_output=True, env=env)
atxt = adb.stdout.decode("utf-8", "replace")
io.open(os.path.join(OUT, "adb_2181.txt"), "w", encoding="utf-8").write(atxt)
ck("adb device present", len([l for l in atxt.splitlines()[1:] if l.strip()]) > 0, atxt.strip().replace("\n", " "))

print("\nSIZE_BYTES=%d\nMD5=%s" % (size, md5))
print("\nFAILS: %d" % len(fails))
for f in fails:
    print("  - " + f)
