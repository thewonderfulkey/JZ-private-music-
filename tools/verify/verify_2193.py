# -*- coding: utf-8 -*-
"""v2.1.93 出包静态验证：
版本三方一致 / 签名 / 完整性 / 双通道打分代码断言 / 识曲注入钩子只在 smoke 包 /
dex 文案 / 清单组件 / 冒烟包 assets 样本
"""
import hashlib, os, re, subprocess, zipfile

ROOT = r"D:\Projects\Private_music"
APK = os.path.join(ROOT, r"android\app\build\outputs\apk\release\app-release.apk")
SMOKE_APK = os.path.join(ROOT, r"android\app\build\outputs\apk\smoke\app-smoke.apk")
SRC = os.path.join(ROOT, r"android\app\src\main")
JAVA = os.path.join(SRC, r"java\com\jz\musichelper")
GRADLE = os.path.join(ROOT, r"android\app\build.gradle.kts")
AAPT = r"C:\Users\17948\AppData\Local\Android\Sdk\build-tools\34.0.0\aapt2.exe"
APKSIGNER = r"C:\Users\17948\AppData\Local\Android\Sdk\build-tools\34.0.0\apksigner.bat"
JDK = os.path.join(ROOT, r".build\toolchain\jdk-17")
if not os.path.isdir(JDK):
    JDK = r"C:\Users\17948\AppData\Local\Programs\jdk-17"

VC, VN = "151", "2.1.93"
results = []


def check(name, ok, detail=""):
    results.append((name, ok, detail))
    print(("PASS  " if ok else "FAIL  ") + name + ("  | " + detail if detail else ""))


def rd(*parts):
    return open(os.path.join(*parts), encoding="utf-8").read()


# ---------- 1. 版本三方一致 ----------
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
check("关于页标题 v2.1.93", "JZ的音乐助手 v2.1.93" in settings)
check("关于页保留 v2.1.92 段落", "上一版（v2.1.92）" in settings)
check("关于页无 v2.1.92 主标题残留", 'Text("JZ的音乐助手 v2.1.92"' not in settings)

# ---------- 2. 签名 ----------
env = dict(os.environ, JAVA_HOME=JDK, PATH=JDK + r"\bin;" + os.environ.get("PATH", ""))
sig = subprocess.run([APKSIGNER, "verify", "--print-certs", APK], capture_output=True, text=True, env=env).stdout
check("签名证书 SHA-256 与既定一致",
      "916ad2328810c691a4022d9716a77709e9ebb08aa262b373c0b05b8c6aed07ac" in sig)
check("apksigner verify 通过", "Signer #1 certificate DN" in sig and "ERROR" not in sig.upper())

# ---------- 3. 完整性 ----------
size = os.path.getsize(APK)
with zipfile.ZipFile(APK) as z:
    bad = z.testzip()
    names = z.namelist()
    dex = b"".join(z.read(n) for n in names if n.endswith(".dex"))
    man = z.read("AndroidManifest.xml")
check("zip 完整性", bad is None, f"testzip={bad}")
check("条目数（应 ≥ 180）", len(names) >= 180, f"{len(names)} 条")
check("体积量级（29.6~30.4MB）", 29_600_000 <= size <= 30_400_000, f"{size:,} B")

# ---------- 4. 网易引擎资产 ----------
with zipfile.ZipFile(APK) as z:
    for rel in ("recognizer.html", "afp_wasm_b64.js", "sandbox.bundle.js"):
        n = "assets/" + rel
        if n in names:
            same = hashlib.sha256(z.read(n)).digest() == hashlib.sha256(
                open(os.path.join(SRC, "assets", rel), "rb").read()).digest()
            check(f"assets/{rel} 与源码一致", same, f"{z.getinfo(n).file_size:,} B")
        else:
            check(f"assets/{rel} 打入", False)

# ---------- 5. 识曲注入钩子：只在 smoke ----------
check("release 关闭钩子（RECOG_TEST_HOOK=false）",
      re.search(r'RECOG_TEST_HOOK", "false"', gradle) is not None)
check("smoke 变体开启钩子（RECOG_TEST_HOOK=true）",
      re.search(r'create\("smoke"\)[\s\S]{0,300}RECOG_TEST_HOOK", "true"', gradle) is not None)
check("buildConfig 已启用", "buildFeatures" in gradle and "buildConfig = true" in gradle)

main_kt = rd(JAVA, "MainActivity.kt")
check("MainActivity 有注入入口", "BuildConfig.RECOG_TEST_HOOK" in main_kt and "jz_test_pcm" in main_kt)
app_kt = rd(JAVA, "ui", "App.kt")
check("App 有 startRecognizeWithFixture", "fun startRecognizeWithFixture(" in app_kt)
check("注入路径走同一套打分", "fuseRecognize(kugou, netease)" in app_kt)
check("注入结果打 JZ_TEST 日志", '"JZ_TEST"' in app_kt)

# release 包里不能出现注入用的字符串（编译期常量折叠）
check("release dex 不含 jz_test_pcm", b"jz_test_pcm" not in dex)
check("release 包不含 fixtures 资产", not any(n.startswith("assets/fixtures/") for n in names))

# smoke 包必须带样本
if os.path.exists(SMOKE_APK):
    with zipfile.ZipFile(SMOKE_APK) as z:
        snames = z.namelist()
        sdex = b"".join(z.read(n) for n in snames if n.endswith(".dex"))
        sizes = {n: z.getinfo(n).file_size for n in snames if n.startswith("assets/fixtures/")}
    check("smoke 包带两个 PCM 样本",
          set(sizes) == {"assets/fixtures/qingtian_8k.pcm", "assets/fixtures/womendouyiyang_8k.pcm"},
          str(sizes))
    check("样本长度 = 12s@8k@16bit（192000 B）", all(v == 192000 for v in sizes.values()))
    check("smoke dex 含 jz_test_pcm", b"jz_test_pcm" in sdex)
else:
    check("smoke 变体已构建", False, SMOKE_APK)

# ---------- 6. 双通道打分：源码断言 ----------
score_kt = rd(JAVA, "network", "RecognizeScore.kt")
for key, desc in [
    ("fun fuse(", "fuse 入口"),
    ("memberScore", "单条打分"),
    ("scoreIdentity", "身份级加成"),
    ("channels.size >= 2", "跨通道互证 +50"),
    ("formalAlbums.size >= 2 && durationConfirmed", "多正式专辑+时长互证 +22"),
    ("1 -> 45", "原唱标记 +45"),
    ("2 -> -30", "翻唱标记 -30"),
    ("4 -> -8", "现场收录（is_original=4）-8"),
]:
    check(f"RecognizeScore：{desc}", key in score_kt)

check("App：网易等待上限 7s", "NETEASE_WAIT_MS = 7_000L" in app_kt)
check("App：网易只取前 12 秒", "trimToSeconds(cap.raw, cap.sourceRate, NeteaseFingerprint.WINDOW_SECONDS)" in app_kt)
check("App：已去掉 6 秒命中即返回", "earlyHits.isNotEmpty()" not in app_kt and "earlySignal" not in app_kt)

hit_kt = rd(JAVA, "network", "RecognizeAdapter.kt")
for f in ("val durationSec: Int = 0", 'val source: String = ""', "val score: Int = 0",
          "val isOriginal: Int = -1", "val rank: Int = 0"):
    check(f"Hit 字段 {f.split(':')[0].strip()}", f in hit_kt)
check("酷狗解析带 is_original", 'o.optInt("is_original", 0)' in hit_kt)
check("网易解析带 duration", 'song.optLong("duration", 0L)' in rd(JAVA, "network", "NeteaseRecognizer.kt"))

# ---------- 7. dex 文案 ----------
for s in ["JZ的音乐助手 v2.1.93", "上一版（v2.1.92）", "识别依据：酷狗", "双通道互证",
          "两条通道都没对上", "点一下麦克风，开始听"]:
    check(f"dex 含「{s}」", s.encode("utf-8") in dex)
check("dex 已无旧主标题 v2.1.92", "JZ的音乐助手 v2.1.92".encode("utf-8") not in dex)
check("dex 含 RecognizeScore 类", b"RecognizeScore" in dex)

# ---------- 8. 清单 ----------
for p in ("INTERNET", "RECORD_AUDIO", "SYSTEM_ALERT_WINDOW"):
    check(f"清单含 {p}", p.encode("utf-16-le") in man or p.encode("utf-8") in man)

# ---------- 9. 硬规则 ----------
start = settings.find("识曲的两处判定修正")
end = settings.find("上一版（v2.1.92）")
block = settings[start:end]
lits = re.findall(r'"([^"]*)"', block)
n_quote = block.count('"')
check("本版更新正文无 ASCII 双引号", start > 0 and end > start and n_quote == 2 * len(lits) and '\\"' not in block,
      f"{len(lits)} 段字面量 / {n_quote} 个引号")

print()
ok_n = sum(1 for _, ok, _ in results if ok)
print(f"合计 {len(results)} 项：PASS {ok_n} / FAIL {len(results) - ok_n}")
print(f"release APK: {size:,} B  MD5 {hashlib.md5(open(APK,'rb').read()).hexdigest().upper()}")
if os.path.exists(SMOKE_APK):
    print(f"smoke   APK: {os.path.getsize(SMOKE_APK):,} B")
