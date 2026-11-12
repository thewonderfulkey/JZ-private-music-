import hashlib, io, re, subprocess, sys, zipfile, os

APK = r"C:\Users\17948\DoubaoWork\chats\2026-10-22\new-chat-1\_tmp_fb3\JZ音乐助手-v2.1.76.apk"
SDK = r"C:\Users\17948\AppData\Local\Android\Sdk"
AAPT = os.path.join(SDK, "build-tools", "34.0.0", "aapt2.exe")
SIGNER = os.path.join(SDK, "build-tools", "34.0.0", "apksigner.bat")
ADB = os.path.join(SDK, "platform-tools", "adb.exe")
OUT = r"C:\Users\17948\DoubaoWork\chats\2026-10-22\new-chat-1\_tmp_build"

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

# 1 badging
badging = subprocess.run([AAPT, "dump", "badging", APK], capture_output=True, env=env)
txt = badging.stdout.decode("utf-8", "replace")
io.open(os.path.join(OUT, "badging_2176.txt"), "w", encoding="utf-8").write(txt)
m = re.search(r"versionCode='(\d+)' versionName='([^']+)'", txt)
ck("badging package", "package: name='com.jz.musichelper'" in txt)
ck("versionCode=134", bool(m) and m.group(1) == "134", m.group(1) if m else "none")
ck("versionName=2.1.76", bool(m) and m.group(2) == "2.1.76", m.group(2) if m else "none")
ck("SYSTEM_ALERT_WINDOW", "android.permission.SYSTEM_ALERT_WINDOW" in txt)
ck("FOREGROUND_SERVICE", "android.permission.FOREGROUND_SERVICE" in txt)

# 2 signature
sign = subprocess.run([SIGNER, "verify", "--print-certs", "-v", APK], capture_output=True, env=env)
stxt = sign.stdout.decode("utf-8", "replace") + sign.stderr.decode("utf-8", "replace")
io.open(os.path.join(OUT, "sign_2176.txt"), "w", encoding="utf-8").write(stxt)
ck("apksigner Verifies", "Verifies" in stxt and sign.returncode == 0)
ck("v2 scheme true", "v2 scheme (APK Signature Scheme v2): true" in stxt)
ck("single signer", "Number of signers: 1" in stxt)

# 3 zip integrity
z = zipfile.ZipFile(APK)
broken = z.testzip()
ck("zip integrity", broken is None, "broken=%s entries=%d" % (broken, len(z.namelist())))
ck("entry count sane", 150 < len(z.namelist()) < 260, "%d entries" % len(z.namelist()))

sizes = {n: z.getinfo(n).file_size for n in z.namelist() if n.startswith("classes") and n.endswith(".dex")}
print("dex sizes:", sizes)

# 4 dex strings: 必须证明这是新版视图代码，不是旧产物
dexblob = b""
for n in z.namelist():
    if n.startswith("classes") and n.endswith(".dex"):
        dexblob += z.read(n)
ck("dex has DesktopLyrics", b"DesktopLyrics" in dexblob)
ck("dex has DesktopLyricsView", b"DesktopLyricsView" in dexblob)
ck("dex has 2.1.76", "2.1.76".encode("utf-8") in dexblob)
ck("dex has new paper color #FFFBF7ED", b"#FFFBF7ED" in dexblob)
ck("dex has new ink stroke #2E2E2A24", b"#2E2E2A24" in dexblob)
ck("dex dropped old bg #F2FAF8F3", b"#F2FAF8F3" not in dexblob)
ck("dex has new about copy 墨边纸签", "墨边纸签".encode("utf-8") in dexblob)
ck("dex no 2.1.75 about string", "JZ的音乐助手 v2.1.75".encode("utf-8") not in dexblob)
ck("dex 2 grew vs 2175", sizes.get("classes2.dex", 0) != 10472644, str(sizes.get("classes2.dex")))

# 5 manifest components
mtxt = subprocess.run([AAPT, "dump", "xmltree", "--file", "AndroidManifest.xml", APK], capture_output=True, env=env).stdout.decode("utf-8", "replace")
io.open(os.path.join(OUT, "manifest_2176.txt"), "w", encoding="utf-8").write(mtxt)
ck("MainActivity declared", "com.jz.musichelper.MainActivity" in mtxt)
ck("PlayerService declared", "PlayerService" in mtxt)
ck("TrackEndReceiver declared", "TrackEndReceiver" in mtxt)
ck("PlayerService mediaPlayback type", re.search(r"foregroundServiceType\(0x01010599\)=0x00000002", mtxt) is not None)

# 6 device gap
adb = subprocess.run([ADB, "devices"], capture_output=True, env=env).stdout.decode("utf-8", "replace")
io.open(os.path.join(OUT, "adb_2176.txt"), "w", encoding="utf-8").write(adb)
devs = [l for l in adb.splitlines()[1:] if l.strip()]
ck("adb device present", len(devs) > 0, "devices=%d (gap if 0)" % len(devs))

print("\nRESULT: %s" % ("ALL STATIC CHECKS PASS" if not fails else "FAILED: " + ", ".join(fails)))
