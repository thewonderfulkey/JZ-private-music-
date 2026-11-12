# -*- coding: utf-8 -*-
import hashlib, io, re, shutil, subprocess, zipfile, os

ROOT = r"C:\Users\17948\DoubaoWork\chats\2026-10-22\new-chat-1"
APK_SRC = os.path.join(ROOT, r"JZMusicHelperAndroid\app\build\outputs\apk\release\app-release.apk")
APK = os.path.join(ROOT, "_tmp_fb3", "JZ音乐助手-v2.1.77.apk")
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
io.open(os.path.join(OUT, "badging_2177.txt"), "w", encoding="utf-8").write(txt)
m = re.search(r"versionCode='(\d+)' versionName='([^']+)'", txt)
ck("badging package", "package: name='com.jz.musichelper'" in txt)
ck("versionCode=135", bool(m) and m.group(1) == "135", m.group(1) if m else "none")
ck("versionName=2.1.77", bool(m) and m.group(2) == "2.1.77", m.group(2) if m else "none")
ck("SYSTEM_ALERT_WINDOW", "android.permission.SYSTEM_ALERT_WINDOW" in txt)
ck("FOREGROUND_SERVICE", "android.permission.FOREGROUND_SERVICE" in txt)

sign = subprocess.run([SIGNER, "verify", "--print-certs", "-v", APK], capture_output=True, env=env)
stxt = sign.stdout.decode("utf-8", "replace") + sign.stderr.decode("utf-8", "replace")
io.open(os.path.join(OUT, "sign_2177.txt"), "w", encoding="utf-8").write(stxt)
ck("apksigner Verifies", "Verifies" in stxt and sign.returncode == 0)
ck("v2 scheme true", "v2 scheme (APK Signature Scheme v2): true" in stxt)
ck("single signer", "Number of signers: 1" in stxt)

z = zipfile.ZipFile(APK)
broken = z.testzip()
ck("zip integrity", broken is None, "broken=%s entries=%d" % (broken, len(z.namelist())))
ck("entry count sane", 150 < len(z.namelist()) < 260, "%d entries" % len(z.namelist()))

sizes = {n: z.getinfo(n).file_size for n in z.namelist() if n.startswith("classes") and n.endswith(".dex")}
print("dex sizes:", sizes)

dexblob = b""
for n in z.namelist():
    if n.startswith("classes") and n.endswith(".dex"):
        dexblob += z.read(n)

# 新版才有：工具条动作枚举 / 三套纸色 / 新设置键 / 新关于文案
ck("dex has LyricsBarAction", b"LyricsBarAction" in dexblob)
ck("dex has DesktopLyricsView", b"DesktopLyricsView" in dexblob)
ck("dex has 2.1.77", "2.1.77".encode("utf-8") in dexblob)
ck("dex has theme 素纸 #FBF7ED", b"#FBF7ED" in dexblob)
ck("dex has theme 旧黄 #F2E5C4", b"#F2E5C4" in dexblob)
ck("dex has theme 夜墨 #24211D", b"#24211D" in dexblob)
ck("dex has prefs key dl_theme", b"dl_theme" in dexblob)
ck("dex has prefs key dl_lock", b"dl_lock" in dexblob)
ck("dex has about copy 逐字", "逐字压深".encode("utf-8") in dexblob)
ck("dex no 2.1.76 about string", "JZ的音乐助手 v2.1.76".encode("utf-8") not in dexblob)
ck("dex dropped old paper #FFFBF7ED", b"#FFFBF7ED" not in dexblob)
ck("dex has 308dp width const", b"dl_frac_x" in dexblob)

mtxt = subprocess.run([AAPT, "dump", "xmltree", "--file", "AndroidManifest.xml", APK],
                      capture_output=True, env=env).stdout.decode("utf-8", "replace")
io.open(os.path.join(OUT, "manifest_2177.txt"), "w", encoding="utf-8").write(mtxt)
ck("MainActivity declared", "com.jz.musichelper.MainActivity" in mtxt)
ck("PlayerService declared", "PlayerService" in mtxt)
ck("TrackEndReceiver declared", "TrackEndReceiver" in mtxt)
ck("PlayerService mediaPlayback type",
   re.search(r"foregroundServiceType\(0x01010599\)=0x00000002", mtxt) is not None)

adb = subprocess.run([ADB, "devices"], capture_output=True, env=env).stdout.decode("utf-8", "replace")
io.open(os.path.join(OUT, "adb_2177.txt"), "w", encoding="utf-8").write(adb)
devs = [l for l in adb.splitlines()[1:] if l.strip()]
ck("adb device present", len(devs) > 0, "devices=%d (gap if 0)" % len(devs))

print("\nRESULT: %s" % ("ALL STATIC CHECKS PASS" if not fails else "FAILED: " + ", ".join(fails)))
