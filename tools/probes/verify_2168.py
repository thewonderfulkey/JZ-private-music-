# -*- coding: utf-8 -*-
import hashlib, os, re, subprocess, zipfile, io

APK = r"C:\Users\17948\DoubaoWork\chats\2026-10-22\new-chat-1\JZMusicHelperAndroid\app\build\outputs\apk\release\app-release.apk"
BT = r"C:\Users\17948\AppData\Local\Android\Sdk\build-tools\34.0.0"
SRC = r"C:\Users\17948\DoubaoWork\chats\2026-10-22\new-chat-1\JZMusicHelperAndroid\app\src\main\java\com\jz\musichelper"

print("APK bytes:", os.path.getsize(APK))
print("MD5:", hashlib.md5(open(APK, "rb").read()).hexdigest().upper())

p = subprocess.run([os.path.join(BT, "aapt2.exe"), "dump", "badging", APK], capture_output=True, text=True, encoding="utf-8")
for line in p.stdout.splitlines():
    if line.startswith(("package:", "sdkVersion", "targetSdkVersion", "uses-permission", "launchable-activity")):
        print(line)

env = dict(os.environ)
env["JAVA_HOME"] = r"C:\Users\17948\AppData\Local\Programs\jdk-17"
p2 = subprocess.run([os.path.join(BT, "apksigner.bat"), "verify", "--print-certs", APK], capture_output=True, text=True, encoding="utf-8", env=env)
print("apksigner rc:", p2.returncode)
for line in (p2.stdout + p2.stderr).splitlines():
    if "SHA-256" in line or "Signer #1" in line:
        print(line.strip())

with zipfile.ZipFile(APK) as z:
    print("zip entries:", len(z.namelist()), "testzip:", z.testzip())

def read(rel):
    return io.open(os.path.join(SRC, rel), encoding="utf-8").read()

checks = {
    "PlayLog存在": os.path.exists(os.path.join(SRC, "data", "PlayLog.kt")),
    "NetworkProbe存在": os.path.exists(os.path.join(SRC, "network", "NetworkProbe.kt")),
    "PlayerManager代次": "private var gen = 0" in read(r"data\PlayerManager.kt"),
    "回调代次守卫": "if (myGen != gen)" in read(r"data\PlayerManager.kt"),
    "网络判定": "NetworkProbe.isReachable()" in read(r"ui\App.kt"),
    "等网络不跳歌": "waitingNetwork = true" in read(r"ui\App.kt"),
    "skipJob作废": "skipJob?.cancel()" in read(r"ui\App.kt"),
    "亮屏重试": "fun onScreenOn()" in read(r"ui\App.kt"),
    "屏幕广播注册": "ACTION_SCREEN_ON" in read(r"MainActivity.kt"),
    "设置页息屏连播": "ACTION_REQUEST_IGNORE_BATTERY_OPTIMIZATIONS" in read(r"ui\SettingsScreen.kt"),
    "关于版本": "v2.1.68" in read(r"ui\SettingsScreen.kt"),
}
for k, v in checks.items():
    print("assert", k, v)
