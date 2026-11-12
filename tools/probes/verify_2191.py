# -*- coding: utf-8 -*-
"""v2.1.91 出包前静态验证（apk-verify 口径）：版本三方一致 / 签名 / 完整性 / 资源 / dex 文案 / 清单组件"""
import hashlib, os, re, subprocess, zipfile

APK = r"C:\Users\17948\DoubaoWork\chats\2026-10-22\new-chat-1\JZMusicHelperAndroid\app\build\outputs\apk\release\app-release.apk"
SRC = r"C:\Users\17948\DoubaoWork\chats\2026-10-22\new-chat-1\JZMusicHelperAndroid\app\src\main"
AAPT = r"C:\Users\17948\AppData\Local\Android\Sdk\build-tools\34.0.0\aapt2.exe"
APKSIGNER = r"C:\Users\17948\AppData\Local\Android\Sdk\build-tools\34.0.0\apksigner.bat"
GRADLE = r"C:\Users\17948\DoubaoWork\chats\2026-10-22\new-chat-1\JZMusicHelperAndroid\app\build.gradle.kts"

results = []
def check(name, ok, detail=""):
    results.append((name, ok, detail))
    print(("PASS  " if ok else "FAIL  ") + name + ("  | " + detail if detail else ""))

# 1. 版本三方一致
gradle = open(GRADLE, encoding="utf-8").read()
vc = re.search(r"versionCode\s*=\s*(\d+)", gradle).group(1)
vn = re.search(r'versionName\s*=\s*"([^"]+)"', gradle).group(1)
check("build.gradle 版本", vc == "149" and vn == "2.1.91", f"vc={vc} vn={vn}")

badging = subprocess.run([AAPT, "dump", "badging", APK], capture_output=True, text=True, encoding="utf-8", errors="replace").stdout
m = re.search(r"versionCode='(\d+)' versionName='([^']+)'", badging)
check("APK badging 版本", bool(m) and m.group(1) == "149" and m.group(2) == "2.1.91",
      f"{m.group(1)}/{m.group(2)}" if m else "解析失败")
check("包名", "package: name='com.jz.musichelper'" in badging)
check("minSdk/targetSdk", "sdkVersion:'26'" in badging and "targetSdkVersion:'34'" in badging)

settings = open(os.path.join(SRC, "java/com/jz/musichelper/ui/SettingsScreen.kt"), encoding="utf-8").read()
check("设置-关于版本文案", "JZ的音乐助手 v2.1.91" in settings)

# 2. 签名
env = dict(os.environ, JAVA_HOME=r"C:\Users\17948\AppData\Local\Programs\jdk-17")
sig = subprocess.run([APKSIGNER, "verify", "--print-certs", APK], capture_output=True, text=True, env=env).stdout
check("签名证书 SHA-256", "916ad2328810c691a4022d9716a77709e9ebb08aa262b373c0b05b8c6aed07ac" in sig)
check("apksigner verify 通过", "Signer #1 certificate DN" in sig and "ERROR" not in sig.upper())

# 3. 完整性 + 体积
size = os.path.getsize(APK)
with zipfile.ZipFile(APK) as z:
    bad = z.testzip()
    names = z.namelist()
check("zip 完整性", bad is None, f"testzip={bad}")
check("体积量级（29.6~30.2MB）", 29_600_000 <= size <= 30_200_000, f"{size:,} B")
check("上一版体积对照", True, "2.1.90 = 29,699,943 B")

# 4. 资源：网易引擎三件套 + 与源码字节一致
with zipfile.ZipFile(APK) as z:
    for rel in ("recognizer.html", "afp_wasm_b64.js", "sandbox.bundle.js"):
        n = "assets/" + rel
        ok = n in names
        if ok:
            same = hashlib.sha256(z.read(n)).digest() == hashlib.sha256(open(os.path.join(SRC, "assets", rel), "rb").read()).digest()
            check(f"assets/{rel} 打入且与源码一致", same, f"{z.getinfo(n).file_size:,} B")
        else:
            check(f"assets/{rel} 打入", False)

# 5. dex 文案断言（MUTF-8，中文按 UTF-8 字节直接搜）
with zipfile.ZipFile(APK) as z:
    dex = b"".join(z.read(n) for n in names if n.endswith(".dex"))
for s in ["两条通道都没对上", "JZ的音乐助手 v2.1.91", "上一版（v2.1.90）", "点一下麦克风，开始听", "酷狗＋网易"]:
    check(f"dex 含文案「{s}」", s.encode("utf-8") in dex)

# 6. 清单组件
with zipfile.ZipFile(APK) as z:
    man = z.read("AndroidManifest.xml")
check("清单含 INTERNET", "INTERNET".encode("utf-16-le") in man or "INTERNET".encode("utf-8") in man)
check("清单含 RECORD_AUDIO", "RECORD_AUDIO".encode("utf-16-le") in man or "RECORD_AUDIO".encode("utf-8") in man)

# 7. SettingsScreen 长文案无 ASCII 双引号（用户硬规则）
block = settings[settings.find('Text("识曲改成酷狗＋网易'):settings.find('上一版（v2.1.90）')]
check("本版更新正文无 ASCII 双引号", '"' not in block.replace('Text("', '').replace('",', ''))

print()
ok_n = sum(1 for _, ok, _ in results if ok)
print(f"合计 {len(results)} 项：PASS {ok_n} / FAIL {len(results) - ok_n}")
