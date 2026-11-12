# -*- coding: utf-8 -*-
"""v2.1.95 静态验证：四个布局/解析修复 + 版本/签名/完整性"""
import hashlib, os, re, subprocess, zipfile

ROOT = r"D:\Projects\Private_music"
APK = os.path.join(ROOT, r"android\app\build\outputs\apk\release\app-release.apk")
SRC = os.path.join(ROOT, r"android\app\src\main")
JAVA = os.path.join(SRC, r"java\com\jz\musichelper")
GRADLE = os.path.join(ROOT, r"android\app\build.gradle.kts")
AAPT = r"C:\Users\17948\AppData\Local\Android\Sdk\build-tools\34.0.0\aapt2.exe"
APKSIGNER = r"C:\Users\17948\AppData\Local\Android\Sdk\build-tools\34.0.0\apksigner.bat"
JDK = os.path.join(ROOT, r".build\toolchain\jdk-17")
if not os.path.isdir(JDK):
    JDK = r"C:\Users\17948\AppData\Local\Programs\jdk-17"

VC, VN = "153", "2.1.95"
results = []


def check(name, ok, detail=""):
    results.append((name, ok, detail))
    print(("PASS  " if ok else "FAIL  ") + name + ("  | " + detail if detail else ""))


def rd(*parts):
    return open(os.path.join(*parts), encoding="utf-8").read()


gradle = rd(GRADLE)
vc = re.search(r"versionCode\s*=\s*(\d+)", gradle).group(1)
vn = re.search(r'versionName\s*=\s*"([^"]+)"', gradle).group(1)
check("build.gradle 版本", vc == VC and vn == VN, f"vc={vc} vn={vn}")

badging = subprocess.run([AAPT, "dump", "badging", APK], capture_output=True, text=True,
                         encoding="utf-8", errors="replace").stdout
m = re.search(r"versionCode='(\d+)' versionName='([^']+)'", badging)
check("APK badging 版本", bool(m) and m.group(1) == VC and m.group(2) == VN,
      f"{m.group(1)}/{m.group(2)}" if m else "解析失败")
check("包名", "package: name='com.jz.musichelper'" in badging)
check("minSdk/targetSdk", "sdkVersion:'26'" in badging and "targetSdkVersion:'34'" in badging)

settings = rd(JAVA, "ui", "SettingsScreen.kt")
check("关于页标题 v2.1.95", "JZ的音乐助手 v2.1.95" in settings)
check("关于页保留 v2.1.94", "上一版（v2.1.94）" in settings)

env = dict(os.environ, JAVA_HOME=JDK, PATH=JDK + r"\bin;" + os.environ.get("PATH", ""))
sig = subprocess.run([APKSIGNER, "verify", "--print-certs", APK], capture_output=True, text=True, env=env).stdout
check("签名证书 SHA-256 一致", "916ad2328810c691a4022d9716a77709e9ebb08aa262b373c0b05b8c6aed07ac" in sig)
check("apksigner 通过", "Signer #1 certificate DN" in sig and "ERROR" not in sig.upper())

size = os.path.getsize(APK)
with zipfile.ZipFile(APK) as z:
    bad = z.testzip()
    names = z.namelist()
    dex = b"".join(z.read(n) for n in names if n.endswith(".dex"))
    asset_ok = {}
    for rel in ("recognizer.html", "afp_wasm_b64.js", "sandbox.bundle.js"):
        n = "assets/" + rel
        asset_ok[rel] = n in names and hashlib.sha256(z.read(n)).digest() == hashlib.sha256(
            open(os.path.join(SRC, "assets", rel), "rb").read()).digest()
check("zip 完整性", bad is None, f"testzip={bad}")
check("条目数（≥180）", len(names) >= 180, f"{len(names)} 条")
check("体积量级", 29_600_000 <= size <= 30_400_000, f"{size:,} B")
for rel, ok in asset_ok.items():
    check(f"assets/{rel} 一致", ok)

# ---- 1) 最近识过贴底 ----
rs = rd(JAVA, "ui", "RecognizeScreen.kt")
check("最近识过用 LazyColumn", "LazyColumn(" in rs)
check("列表贴底（Arrangement.Bottom）", "verticalArrangement = Arrangement.Bottom" in rs)
check("列表必须有 weight(1f)（否则 Bottom 不生效）", "Modifier.fillMaxWidth().weight(1f)" in rs)
check("底部让位 64dp（实测严丝合缝）", "Spacer(Modifier.height(64.dp))" in rs)
check("页脚已移除且底部让位=64dp", "秒采样只用于曲库比对" not in rs and "Spacer(Modifier.height(64.dp))" in rs)

# ---- 2) 去掉"N 平台并发" ----
hs = rd(JAVA, "ui", "HomeScreen.kt")
check("已移除「N 平台并发」文案", 'Text("${searchPlatforms.size} 平台并发"' not in hs)

# ---- 3) 酷我时长 ----
sa = rd(JAVA, "network", "SearchAdapters.kt")
check("时长先按秒数解析", "t.toIntOrNull()?.let { return if (it in 1..36000) it else 0 }" in sa)

# ---- 4) 结果行对齐 ----
check("时长定宽右对齐", "Modifier.width(42.dp)" in hs and "textAlign = TextAlign.End" in hs)
check("平台标签定宽居中", ".width(44.dp)" in hs and "textAlign = TextAlign.Center" in hs)
check("HomeScreen 引入 TextAlign", "import androidx.compose.ui.text.style.TextAlign" in hs)

# ---- dex ----
for s in ["JZ的音乐助手 v2.1.95", "上一版（v2.1.94）"]:
    check(f"dex 含「{s}」", s.encode("utf-8") in dex)
check("dex 不含旧主标题 v2.1.94", "JZ的音乐助手 v2.1.94".encode("utf-8") not in dex)
check("dex 含 v2.1.95 关于区块段落", "四个细节".encode("utf-8") in dex)

print()
ok_n = sum(1 for _, ok, _ in results if ok)
print(f"合计 {len(results)} 项：PASS {ok_n} / FAIL {len(results) - ok_n}")
print(f"release APK: {size:,} B  MD5 {hashlib.md5(open(APK,'rb').read()).hexdigest().upper()}")

