# -*- coding: utf-8 -*-
"""v2.1.63 交付前静态验证（apk-verify 口径）：badging / 签名 / zip 完整性 / 字体资源 / dex 版本串 / MD5。"""
import subprocess, zipfile, hashlib, os, io, glob

SDK = r"C:\Users\17948\AppData\Local\Android\Sdk"
BT = os.path.join(SDK, "build-tools", "34.0.0")
APK = r"C:\Users\17948\DoubaoWork\chats\2026-10-22\new-chat-1\JZMusicHelperAndroid\app\build\outputs\apk\release\app-release.apk"
OUT = r"C:\Users\17948\DoubaoWork\chats\2026-10-22\new-chat-1\_tmp_build\verify_2163.txt"
ENV = dict(os.environ, JAVA_HOME=r"C:\Users\17948\AppData\Local\Programs\jdk-17")

lines = ["apk=%s size=%d mtime=%s" % (APK, os.path.getsize(APK), __import__("time").strftime("%Y-%m-%d %H:%M:%S", __import__("time").localtime(os.path.getmtime(APK)))),
         "md5=%s" % hashlib.md5(open(APK, "rb").read()).hexdigest().upper()]

p = subprocess.run([os.path.join(BT, "aapt2.exe"), "dump", "badging", APK], capture_output=True, text=True, encoding="utf-8", errors="replace")
for ln in p.stdout.splitlines():
    if ln.startswith(("package:", "sdkVersion", "targetSdkVersion", "application-label", "uses-permission: name='android.permission.INTERNET'", "uses-permission: name='android.permission.FOREGROUND_SERVICE'")):
        lines.append("badging| " + ln.strip())

p = subprocess.run([os.path.join(BT, "apksigner.bat"), "verify", "--print-certs", APK], capture_output=True, text=True, encoding="utf-8", errors="replace", env=ENV)
for ln in p.stdout.splitlines():
    if "SHA-256" in ln or "Signer #1 certificate DN" in ln:
        lines.append("signer| " + ln.strip())
lines.append("apksigner rc=%d" % p.returncode)

z = zipfile.ZipFile(APK)
bad = z.testzip()
fonts = [(n, z.getinfo(n).file_size) for n in z.namelist() if "/font/" in n or n.lower().endswith(".ttf")]
dex_hit = [n for n in z.namelist() if n.endswith(".dex") and b"2.1.63" in z.read(n)]
lines.append("zip entries=%d testzip=%s" % (len(z.namelist()), bad))
lines.append("fonts=%s" % fonts)
lines.append("dex 命中 2.1.63：%s" % dex_hit)
z.close()

# 与上一版对比体积
prev = r"C:\Users\17948\DoubaoWork\chats\2026-10-22\new-chat-1\_tmp_fb3\JZ音乐助手-v2.1.62.apk"
if os.path.exists(prev):
    lines.append("delta vs v2.1.62: %+d B (%.1f MB -> %.1f MB)" % (
        os.path.getsize(APK) - os.path.getsize(prev), os.path.getsize(prev) / 1048576, os.path.getsize(APK) / 1048576))

io.open(OUT, "w", encoding="utf-8").write("\n".join(lines))
print("\n".join(lines))
