# -*- coding: utf-8 -*-
"""apk-verify（静态层）：v2.1.88 产物核对——版本三方一致 / 签名 / zip 完整性 / 本次改动在 dex 里确有落地。"""
import io
import os
import re
import subprocess
import sys
import zipfile

APK = r"C:\Users\17948\DoubaoWork\chats\2026-10-22\new-chat-1\JZMusicHelperAndroid\app\build\outputs\apk\release\app-release.apk"
OUT = r"C:\Users\17948\DoubaoWork\chats\2026-10-22\new-chat-1\_tmp_build\verify_2188.txt"
lines = []
ok = 0
fail = 0


def chk(name, cond, detail=""):
    global ok, fail
    if cond:
        ok += 1
        lines.append("PASS  %s %s" % (name, detail))
    else:
        fail += 1
        lines.append("FAIL  %s %s" % (name, detail))


# 1. zip 完整性
try:
    with zipfile.ZipFile(APK) as z:
        bad = z.testzip()
        names = z.namelist()
        dex = [n for n in names if re.match(r"classes\d*\.dex$", n)]
        data = b"".join(z.read(n) for n in dex)
    chk("zip 完整性", bad is None, "(破损条目=%s)" % bad)
    chk("dex 数量", len(dex) >= 1, "(%d 个：%s)" % (len(dex), ",".join(dex)))
except Exception as e:
    lines.append("FAIL  zip 打开失败 %s" % e)
    fail += 1
    data = b""

size = os.path.getsize(APK)
chk("产物体积量级", 25_000_000 < size < 35_000_000, "(%d B)" % size)

# 2. 版本 / 包名（aapt2 badging 实际读产物）
aapt = r"C:\Users\17948\AppData\Local\Android\Sdk\build-tools\34.0.0\aapt2.exe"
badging = subprocess.run([aapt, "dump", "badging", APK], capture_output=True, text=True, encoding="utf-8", errors="ignore").stdout
m = re.search(r"package: name='([^']+)' versionCode='(\d+)' versionName='([^']+)'", badging)
chk("包名/版本", bool(m) and m.group(1) == "com.jz.musichelper" and m.group(2) == "146" and m.group(3) == "2.1.88",
    "(%s)" % (str(m.groups()) if m else "未解析"))
chk("minSdk/targetSdk", "sdkVersion:'26'" in badging and "targetSdkVersion:'34'" in badging)

# 3. 签名
aps = r"C:\Users\17948\AppData\Local\Android\Sdk\build-tools\34.0.0\apksigner.bat"
env = dict(os.environ, JAVA_HOME=r"C:\Users\17948\AppData\Local\Programs\jdk-17",
           PATH=r"C:\Users\17948\AppData\Local\Programs\jdk-17\bin;" + os.environ.get("PATH", ""))
ap = subprocess.run([aps, "verify", "--print-certs", APK], capture_output=True, text=True, encoding="utf-8", errors="ignore", env=env)
chk("签名校验", ap.returncode == 0, "(rc=%d)" % ap.returncode)
chk("证书指纹一致", "916ad2328810c691a4022d9716a77709e9ebb08aa262b373c0b05b8c6aed07ac" in ap.stdout)

# 4. dex 里核对本次改动（字符串常量）
def has(s):
    return s.encode("utf-8") in data

chk("关于页版本号已同步", has("JZ的音乐助手 v2.1.88"))
chk("本版更新文案已落地", has("识曲命中即可播"))
chk("旧的硬编码『3 平台并发』已移除", not has("3 平台并发"))
chk("平台并发模板串存在", has("平台并发"))
chk("酷我变体/大小写改动类名存在", has("com.jz.musichelper.network.KuwoSearchAdapter"))
chk("Ranker 类存在", has("SearchRanker"))
chk("识曲链路类存在", has("StudioPick") and has("RecognizeAdapter"))

lines.insert(0, "== v2.1.88 静态验证：%d PASS / %d FAIL ==" % (ok, fail))
io.open(OUT, "w", encoding="utf-8").write("\n".join(lines) + "\n")
print("\n".join(lines))
sys.exit(1 if fail else 0)
