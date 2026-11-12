# -*- coding: utf-8 -*-
"""v2.1.89 交付前静态验证：版本/包名/签名/完整性/本次改动是否进包。"""
import os
import subprocess
import zipfile

APK = r"C:\Users\17948\DoubaoWork\chats\2026-10-22\new-chat-1\_tmp_fb4\JZ音乐助手-v2.1.89.apk"
BT = r"C:\Users\17948\AppData\Local\Android\Sdk\build-tools\34.0.0"
JAVA = r"C:\Users\17948\AppData\Local\Programs\jdk-17"
OUT = r"C:\Users\17948\DoubaoWork\chats\2026-10-22\new-chat-1\_tmp_build\verify_2189.txt"

res = []


def chk(name, ok, detail=""):
    res.append(("PASS" if ok else "FAIL", name, detail))


# 1 zip 完整性
bad = []
with zipfile.ZipFile(APK) as z:
    bad = z.testzip()
    names = z.namelist()
chk("zip 完整性", bad is None, "testzip=%s" % bad)

# 2 dex 数量
dex = [n for n in names if n.startswith("classes") and n.endswith(".dex")]
chk("dex 数量 >= 2", len(dex) >= 2, "dex=%s" % dex)

# 3 体积量级
size = os.path.getsize(APK)
chk("体积量级 ~29.7MB", 27_000_000 < size < 33_000_000, "%d bytes" % size)

# 4 badging
aapt = os.path.join(BT, "aapt2.exe")
bg = subprocess.run([aapt, "dump", "badging", APK], capture_output=True, text=True, encoding="utf-8", errors="ignore").stdout
chk("package 名", "package: name='com.jz.musichelper'" in bg, "")
chk("versionCode 147", "versionCode='147'" in bg, "")
chk("versionName 2.1.89", "versionName='2.1.89'" in bg, "")
chk("minSdk 26", "sdkVersion:'26'" in bg, "")
chk("targetSdk 34", "targetSdkVersion:'34'" in bg, "")

# 5 签名
env = dict(os.environ, JAVA_HOME=JAVA, PATH=JAVA + r"\bin;" + os.environ.get("PATH", ""))
sig = subprocess.run([os.path.join(BT, "apksigner.bat"), "verify", "--print-certs", APK],
                     capture_output=True, text=True, encoding="utf-8", errors="ignore", env=env)
chk("签名校验 rc=0", sig.returncode == 0, "rc=%d" % sig.returncode)
chk("证书 SHA-256 一致",
    "916ad2328810c691a4022d9716a77709e9ebb08aa262b373c0b05b8c6aed07ac" in (sig.stdout + sig.stderr), "")

# 6 本次改动是否进 dex（中文字面量在 dex 里是 UTF-8，可直接搜字节）
blob = b""
with zipfile.ZipFile(APK) as z:
    for n in dex:
        blob += z.read(n)
for s in ("录音室版", "同歌手", "2.1.89", "异口同声", "第一位歌手"):
    chk("dex 含文案：%s" % s, s.encode("utf-8") in blob, "")

lines = ["%s  %s  %s" % r for r in res]
npass = sum(1 for r in res if r[0] == "PASS")
lines.append("")
lines.append("TOTAL: %d PASS / %d FAIL" % (npass, len(res) - npass))
open(OUT, "w", encoding="utf-8").write("\n".join(lines) + "\n")
print("\n".join(lines))
