# -*- coding: utf-8 -*-
"""v2.1.62 静态验证：badging / 签名 / zip 完整性 / dex 版本串 / MD5。"""
import os, hashlib, zipfile, subprocess, io

APK = r"C:\Users\17948\DoubaoWork\chats\2026-10-22\new-chat-1\JZMusicHelperAndroid\app\build\outputs\apk\release\app-release.apk"
BT = r"C:\Users\17948\AppData\Local\Android\Sdk\build-tools\34.0.0"
OUT = r"C:\Users\17948\DoubaoWork\chats\2026-10-22\new-chat-1\_tmp_build\verify_2162.txt"
PREV = r"C:\Users\17948\DoubaoWork\chats\2026-10-22\new-chat-1\_tmp_fb3\JZ音乐助手-v2.1.61.apk"

env = dict(os.environ)
env["JAVA_HOME"] = r"C:\Users\17948\AppData\Local\Programs\jdk-17"

lines = []
size = os.path.getsize(APK)
apk_m = os.path.getmtime(APK)
lines.append("apk mtime = %s" % __import__("time").strftime("%H:%M:%S", __import__("time").localtime(apk_m)))
lines.append("size=%d (%.2f MB)" % (size, size / 1048576))
if os.path.exists(PREV):
    lines.append("prev_v2161=%d delta=%+d" % (os.path.getsize(PREV), size - os.path.getsize(PREV)))

r1 = subprocess.run([os.path.join(BT, "aapt2.exe"), "dump", "badging", APK],
                    capture_output=True, text=True, encoding="utf-8", errors="replace")
lines.append("badging| " + (r1.stdout or "").splitlines()[0].strip())

r2 = subprocess.run([os.path.join(BT, "apksigner.bat"), "verify", "--print-certs", APK],
                    capture_output=True, text=True, encoding="utf-8", errors="replace", env=env)
for ln in (r2.stdout or "").splitlines():
    if "SHA-256 digest" in ln and "certificate" in ln:
        lines.append("signer| " + ln.strip())

with zipfile.ZipFile(APK) as z:
    bad = z.testzip()
    names = z.namelist()
    hits = [n for n in names if n.endswith(".dex") and b"2.1.62" in z.read(n)]
lines.append("zip| testzip=%s entries=%d dex_with_2162=%s" % ("OK" if bad is None else "BAD:" + str(bad), len(names), hits))
lines.append("md5=%s" % hashlib.md5(open(APK, "rb").read()).hexdigest().upper())

io.open(OUT, "w", encoding="utf-8").write("\n".join(lines))
print("\n".join(lines))
