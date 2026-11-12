# -*- coding: utf-8 -*-
"""v2.1.61 静态验证：badging / 签名 / zip 完整性 / dex 版本串 / MD5。全部写入文件并回显。"""
import os, hashlib, zipfile, subprocess, io

APK = r"C:\Users\17948\DoubaoWork\chats\2026-10-22\new-chat-1\JZMusicHelperAndroid\app\build\outputs\apk\release\app-release.apk"
BT = r"C:\Users\17948\AppData\Local\Android\Sdk\build-tools\34.0.0"
OUT = r"C:\Users\17948\DoubaoWork\chats\2026-10-22\new-chat-1\_tmp_build\verify_2161.txt"
PREV = r"C:\Users\17948\DoubaoWork\chats\2026-10-22\new-chat-1\_tmp_fb3\JZ音乐助手-v2.1.60.apk"

env = dict(os.environ)
env["JAVA_HOME"] = r"C:\Users\17948\AppData\Local\Programs\jdk-17"

lines = []
size = os.path.getsize(APK)
lines.append("apk=%s" % APK)
lines.append("size=%d (%.2f MB)" % (size, size / 1048576))
if os.path.exists(PREV):
    p = os.path.getsize(PREV)
    lines.append("prev_v2160=%d delta=%+d" % (p, size - p))

# badging
r1 = subprocess.run([os.path.join(BT, "aapt2.exe"), "dump", "badging", APK],
                    capture_output=True, text=True, encoding="utf-8", errors="replace")
head = (r1.stdout or "").splitlines()
for ln in head[:3]:
    lines.append("badging| " + ln.strip())
for ln in head:
    if ln.startswith("uses-permission"):
        lines.append("perm| " + ln.strip())

# signer
r2 = subprocess.run([os.path.join(BT, "apksigner.bat"), "verify", "--print-certs", APK],
                    capture_output=True, text=True, encoding="utf-8", errors="replace", env=env)
for ln in (r2.stdout or "").splitlines():
    if "SHA-256" in ln or "DN:" in ln:
        lines.append("signer| " + ln.strip())

# zip
with zipfile.ZipFile(APK) as z:
    bad = z.testzip()
    names = z.namelist()
    hits = []
    for n in names:
        if n.endswith(".dex") and b"2.1.61" in z.read(n):
            hits.append(n)
lines.append("zip| testzip=%s entries=%d dex_with_2161=%s" % ("OK" if bad is None else "BAD:" + str(bad), len(names), hits))

# md5
h = hashlib.md5(open(APK, "rb").read()).hexdigest().upper()
lines.append("md5=%s" % h)

io.open(OUT, "w", encoding="utf-8").write("\n".join(lines))
print("\n".join(lines))
