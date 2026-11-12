# -*- coding: utf-8 -*-
import hashlib, io, os, subprocess, zipfile

APK = r"C:\Users\17948\DoubaoWork\chats\2026-10-22\new-chat-1\JZMusicHelperAndroid\app\build\outputs\apk\release\app-release.apk"
BT = r"C:\Users\17948\AppData\Local\Android\Sdk\build-tools\34.0.0"
SRC = r"C:\Users\17948\DoubaoWork\chats\2026-10-22\new-chat-1\JZMusicHelperAndroid\app\src\main\java\com\jz\musichelper"
MAN = r"C:\Users\17948\DoubaoWork\chats\2026-10-22\new-chat-1\JZMusicHelperAndroid\app\src\main\AndroidManifest.xml"

print("APK bytes:", os.path.getsize(APK))
print("MD5:", hashlib.md5(open(APK, "rb").read()).hexdigest().upper())

p = subprocess.run([os.path.join(BT, "aapt2.exe"), "dump", "badging", APK], capture_output=True, text=True, encoding="utf-8")
for line in p.stdout.splitlines():
    if line.startswith(("package:", "uses-permission", "launchable-activity")):
        print(line)

env = dict(os.environ); env["JAVA_HOME"] = r"C:\Users\17948\AppData\Local\Programs\jdk-17"
p2 = subprocess.run([os.path.join(BT, "apksigner.bat"), "verify", "--print-certs", APK], capture_output=True, text=True, encoding="utf-8", env=env)
print("apksigner rc:", p2.returncode)
for line in (p2.stdout + p2.stderr).splitlines():
    if "SHA-256" in line:
        print(line.strip())

with zipfile.ZipFile(APK) as z:
    print("zip entries:", len(z.namelist()), "testzip:", z.testzip())

def read(rel): return io.open(os.path.join(SRC, rel), encoding="utf-8").read()

checks = {
    "TrackEndAlarm存在": os.path.exists(os.path.join(SRC, "data", "TrackEndAlarm.kt")),
    "闹铃已排": "TrackEndAlarm.schedule(appContext" in read(r"data\PlayerManager.kt"),
    "闹铃已取消": "TrackEndAlarm.cancel" in read(r"data\PlayerManager.kt"),
    "接收器已声明": "TrackEndReceiver" in io.open(MAN, encoding="utf-8").read(),
    "精确闹铃权限": "SCHEDULE_EXACT_ALARM" in io.open(MAN, encoding="utf-8").read(),
    "探测走IO": "withContext(Dispatchers.IO)" in read(r"network\NetworkProbe.kt"),
    "探测不再阻塞主线程调用": "NetworkProbe.isReachable()" in read(r"ui\App.kt"),
    "息屏按等网络处理": "val screenOff = !NetworkProbe.isInteractive()" in read(r"ui\App.kt"),
    "看门狗": "GAP key=" in read(r"ui\App.kt"),
    "播完统一入口": "fun advanceAfterTrackEnd" in read(r"ui\App.kt"),
    "闹铃处理": "fun onTrackEndAlarm" in read(r"ui\App.kt"),
    "亮屏卡末尾兜底": "SCREEN_ON stuck-at-end" in read(r"ui\App.kt"),
    "关于版本": "v2.1.69" in read(r"ui\SettingsScreen.kt"),
    "诊断状态行": "Doze " in read(r"ui\SettingsScreen.kt"),
}
for k, v in checks.items():
    print("assert", k, v)
