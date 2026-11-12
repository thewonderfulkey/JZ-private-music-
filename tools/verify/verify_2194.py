# -*- coding: utf-8 -*-
"""v2.1.94 静态验证：六个修复的源码断言 + 版本/签名/完整性/资产 + dex 文案"""
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

VC, VN = "152", "2.1.94"
results = []


def check(name, ok, detail=""):
    results.append((name, ok, detail))
    print(("PASS  " if ok else "FAIL  ") + name + ("  | " + detail if detail else ""))


def rd(*parts):
    return open(os.path.join(*parts), encoding="utf-8").read()


# ---------- 版本 / 签名 / 完整性 ----------
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
check("关于页标题 v2.1.94", "JZ的音乐助手 v2.1.94" in settings)
check("关于页保留 v2.1.93", "上一版（v2.1.93）" in settings)
check("关于页无旧主标题 v2.1.93", 'Text("JZ的音乐助手 v2.1.93"' not in settings)

env = dict(os.environ, JAVA_HOME=JDK, PATH=JDK + r"\bin;" + os.environ.get("PATH", ""))
sig = subprocess.run([APKSIGNER, "verify", "--print-certs", APK], capture_output=True, text=True, env=env).stdout
check("签名证书 SHA-256 与既定一致",
      "916ad2328810c691a4022d9716a77709e9ebb08aa262b373c0b05b8c6aed07ac" in sig)
check("apksigner verify 通过", "Signer #1 certificate DN" in sig and "ERROR" not in sig.upper())

size = os.path.getsize(APK)
with zipfile.ZipFile(APK) as z:
    bad = z.testzip()
    names = z.namelist()
    dex = b"".join(z.read(n) for n in names if n.endswith(".dex"))
    man = z.read("AndroidManifest.xml")
    asset_ok = {}
    for rel in ("recognizer.html", "afp_wasm_b64.js", "sandbox.bundle.js"):
        n = "assets/" + rel
        asset_ok[rel] = (n in names and hashlib.sha256(z.read(n)).digest() ==
                         hashlib.sha256(open(os.path.join(SRC, "assets", rel), "rb").read()).digest())
check("zip 完整性", bad is None, f"testzip={bad}")
check("条目数（≥180）", len(names) >= 180, f"{len(names)} 条")
check("体积量级（29.6~30.4MB）", 29_600_000 <= size <= 30_400_000, f"{size:,} B")
for rel, ok in asset_ok.items():
    check(f"assets/{rel} 一致", ok)

# ---------- Bug 6：酷狗接入 ----------
sr = rd(JAVA, "network", "SearchAndResolve.kt")
check("SearchService 注册了酷狗", "KugouSearchAdapter()" in sr)
check("不再是 3 平台", "NeteaseSearchAdapter(),\n            KuwoSearchAdapter()\n        //" not in sr)

sa = rd(JAVA, "network", "SearchAdapters.kt")
check("酷狗搜索换宿主 mobiles.kugou.com", "mobiles.kugou.com/api/v3/search/song" in sa)
check("酷狗旧宿主已移除", "mobilecdn.kugou.com/api/v3/search" not in sa)
check("酷狗取流注册进 SourceRegistry", "KugouPlayInfoAdapter()" in rd(JAVA, "network", "SourceAdapters.kt"))
check("酷狗取流用 playInfo", "getSongInfo.php?cmd=playInfo" in rd(JAVA, "network", "SourceAdapters.kt"))

# ---------- Bug 4：酷我 0 条 ----------
check("splitTopLevel 保留大括号", "depth++\n                    current.append(ch)" in sa)
check("splitTopLevel 引号感知", "inQuote" in sa and "escaped" in sa)
check("酷我 rn=50", "minOf(limit, 50)" in sa)
check("酷我变体兜底", "return if (songs.isNotEmpty()) songs else variants" in sa)
check("酷我歌名兼容 NAME/SONGNAME", 'item["SONGNAME"] ?: item["NAME"]' in sa)

# ---------- Bug 5：封面 ----------
check("网易封面走 song/detail", "api/song/detail?ids=[$ids]" in sa)
check("网易封面回填", "songs[i] = songs[i].copy(picUrl = p)" in sa)
check("酷我封面 MVPIC 仍在", "img1.kuwo.cn/wmvpic/" in sa)
check("酷狗封面 union_cover 仍在", "union_cover" in sa)

# ---------- Bug 1：原唱口径 ----------
ra = rd(JAVA, "network", "RecognizeAdapter.kt")
check("Judge 有 isStudioOriginal", "fun isStudioOriginal(" in ra)
check("原唱要求裸名", "StudioPick.isCleanTitle(name)" in ra)
check("原唱排除现场/综艺专辑", "isVarietyAlbum(album) || StudioPick.isLiveAlbum(album)" in ra)
check("原唱排除同名合集", "isSameAlbumAsTitle(album, name)" in ra)
app = rd(JAVA, "ui", "App.kt")
check("App 改用新口径", "RecognizeAdapter.Judge.isStudioOriginal(" in app)
check("旧口径已移除", "if (!hitVariant) {\n                        tokens.isNotEmpty()" not in app)

# ---------- Bug 3：识曲期间禁止自动起播 ----------
pm = rd(JAVA, "data", "PlayerManager.kt")
check("PlayerManager 有播放闸门", "fun holdPlayback(" in pm and "holdReason" in pm)
check("play() 入口拦截", "play blocked by $it" in pm)
check("识曲挂闸门", 'PlayerManager.holdPlayback("recognize")' in app)
check("识曲解闸门", "PlayerManager.releaseHold()" in app)

# ---------- Bug 2：换人提示 ----------
rs = rd(JAVA, "ui", "RecognizeScreen.kt")
check("结果卡有换人提示", "看下面「同批候选」" in rs)

# ---------- dex ----------
for s in ["JZ的音乐助手 v2.1.94", "上一版（v2.1.93）", "识别依据：酷狗", "看下面「同批候选」"]:
    check(f"dex 含「{s}」", s.encode("utf-8") in dex)
check("dex 含 KugouPlayInfoAdapter", b"KugouPlayInfoAdapter" in dex)
check("dex 含 isStudioOriginal", b"isStudioOriginal" in dex)
for p in ("INTERNET", "RECORD_AUDIO", "SYSTEM_ALERT_WINDOW"):
    check(f"清单含 {p}", p.encode("utf-16-le") in man or p.encode("utf-8") in man)

print()
ok_n = sum(1 for _, ok, _ in results if ok)
print(f"合计 {len(results)} 项：PASS {ok_n} / FAIL {len(results) - ok_n}")
print(f"release APK: {size:,} B  MD5 {hashlib.md5(open(APK,'rb').read()).hexdigest().upper()}")
