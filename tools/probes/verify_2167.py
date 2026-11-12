# -*- coding: utf-8 -*-
import hashlib, io, os, subprocess, zipfile

ROOT = r"C:\Users\17948\DoubaoWork\chats\2026-10-22\new-chat-1"
APK = os.path.join(ROOT, r"JZMusicHelperAndroid\app\build\outputs\apk\release\app-release.apk")
BT = r"C:\Users\17948\AppData\Local\Android\Sdk\build-tools"
SRC = os.path.join(ROOT, r"JZMusicHelperAndroid\app\src\main\java\com\jz\musichelper")

out = []
out.append("SIZE: %d bytes" % os.path.getsize(APK))
out.append("MD5: %s" % hashlib.md5(open(APK, "rb").read()).hexdigest().upper())

aapt2 = os.path.join(BT, "34.0.0", "aapt2.exe")
r = subprocess.run([aapt2, "dump", "badging", APK], capture_output=True)
for line in r.stdout.decode("utf-8", "replace").splitlines():
    if line.startswith("package:") or "launchable-activity" in line or line.startswith("sdkVersion") or line.startswith("targetSdkVersion") or "WAKE_LOCK" in line:
        out.append(line.strip())
# 权限清单里必须有 WAKE_LOCK
perms = [l for l in r.stdout.decode("utf-8", "replace").splitlines() if "uses-permission" in l]
out.append("WAKE_LOCK 在清单: %s" % any("WAKE_LOCK" in p for p in perms))
out.append("权限数: %d" % len(perms))

with zipfile.ZipFile(APK) as z:
    n = z.namelist()
    bad = z.testzip()
out.append("zip entries: %d | testzip: %s" % (len(n), "OK" if bad is None else bad))

app = io.open(os.path.join(SRC, "ui", "App.kt"), encoding="utf-8").read()
svc = io.open(os.path.join(SRC, "data", "PlayerService.kt"), encoding="utf-8").read()
man = io.open(os.path.join(ROOT, r"JZMusicHelperAndroid\app\src\main\AndroidManifest.xml"), encoding="utf-8").read()
act = io.open(os.path.join(SRC, "MainActivity.kt"), encoding="utf-8").read()
ss = io.open(os.path.join(SRC, "ui", "SettingsScreen.kt"), encoding="utf-8").read()

out.append("AppState.startAutoContinue 定义: %s" % ("fun startAutoContinue()" in app))
out.append("组合内已无 completed 收集: %s" % ("PlayerManager.completed.collect" in app and app.count("PlayerManager.completed.collect") == 1))
out.append("MainActivity 启动监听: %s" % ("startAutoContinue()" in act))
out.append("服务持有 PARTIAL_WAKE_LOCK: %s" % ("PARTIAL_WAKE_LOCK" in svc and "acquire()" in svc))
out.append("清单声明 WAKE_LOCK: %s" % ("android.permission.WAKE_LOCK" in man))
out.append("关于页版本: %s | 精简声明仍在: %s" % ("v2.1.67" in ss, '"声明"' in ss))

txt = "\n".join(out)
print(txt)
io.open(os.path.join(ROOT, r"_tmp_build\verify_2167.txt"), "w", encoding="utf-8").write(txt)
