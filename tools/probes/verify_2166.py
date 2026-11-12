# -*- coding: utf-8 -*-
import hashlib, os, subprocess, zipfile, io

APK = r"C:\Users\17948\DoubaoWork\chats\2026-10-22\new-chat-1\JZMusicHelperAndroid\app\build\outputs\apk\release\app-release.apk"
BT = r"C:\Users\17948\AppData\Local\Android\Sdk\build-tools"
out = []
apk_size = os.path.getsize(APK)
md5 = hashlib.md5(open(APK, "rb").read()).hexdigest().upper()
out.append("APK: %s" % APK)
out.append("SIZE: %d bytes" % apk_size)
out.append("MD5: %s" % md5)

btver = sorted(os.listdir(BT))[-1]
aapt2 = os.path.join(BT, btver, "aapt2.exe")
apksigner = os.path.join(BT, btver, "apksigner.bat")
out.append("build-tools: %s" % btver)

r = subprocess.run([aapt2, "dump", "badging", APK], capture_output=True)
badging = r.stdout.decode("utf-8", "replace")
for line in badging.splitlines():
    if line.startswith("package:") or "launchable-activity" in line or line.startswith("sdkVersion") or line.startswith("targetSdkVersion") or "uses-permission" in line:
        out.append(line.strip())

r2 = subprocess.run([apksigner, "verify", "--print-certs", APK], capture_output=True)
out.append("apksigner rc=%d" % r2.returncode)
for line in (r2.stdout.decode("utf-8", "replace") + r2.stderr.decode("utf-8", "replace")).splitlines():
    if "SHA-256" in line or "Signer" in line or "certificate" in line.lower():
        out.append(line.strip())

with zipfile.ZipFile(APK) as z:
    names = z.namelist()
    bad = z.testzip()
out.append("zip entries: %d | testzip: %s" % (len(names), "OK" if bad is None else bad))
rel = "app/src/main/java/com/jz/musichelper/ui/SettingsScreen.kt"
src = io.open(os.path.join(r"C:\Users\17948\DoubaoWork\chats\2026-10-22\new-chat-1\JZMusicHelperAndroid", rel), encoding="utf-8").read()
out.append("Settings 声明存在: %s | 旧版本史已清: %s | 底部 60dp: %s" % (
    '"本版更新"' in src and '"声明"' in src,
    "v2.1.64：下载链路两条补齐" not in src,
    "96.dp else 60.dp" in src))
gradle = io.open(r"C:\Users\17948\DoubaoWork\chats\2026-10-22\new-chat-1\JZMusicHelperAndroid\app\build.gradle.kts", encoding="utf-8").read()
out.append("gradle 版本: vc %s / %s" % (
    "124" if "versionCode = 124" in gradle else "??",
    "2.1.66" if 'versionName = "2.1.66"' in gradle else "??"))

txt = "\n".join(out)
print(txt)
io.open(r"C:\Users\17948\DoubaoWork\chats\2026-10-22\new-chat-1\_tmp_build\verify_2166.txt", "w", encoding="utf-8").write(txt)
