# -*- coding: utf-8 -*-
"""v2.1.79：更新 GitHub 仓库（源码归档 + 根目录 APK）+ 发布第五版 Release。
走 Git Data API（本机 git push 的 TLS 握手失败，见 experience）。
"""
import base64, hashlib, json, subprocess, time, urllib.request, urllib.parse

GIT = r"D:\Git\cmd\git.exe"
R = "thewonderfulkey/JZ-private-music-"
ROOT = r"C:\Users\17948\DoubaoWork\chats\2026-10-22\new-chat-1"
ZIP = ROOT + r"\_tmp_build\JZ音乐助手-安卓源码-v2.1.79.zip"
APK = ROOT + r"\_tmp_fb3\JZ音乐助手-v2.1.79.apk"
TAG = "v2.1.79"
NAME = "第五版 v2.1.79"

p = subprocess.run([GIT, "credential", "fill"], input="protocol=https\nhost=github.com\n\n",
                   capture_output=True, text=True)
tok = [l.split("=", 1)[1] for l in p.stdout.splitlines() if l.startswith("password=")][0]
H = {"Authorization": "token " + tok, "Accept": "application/vnd.github+json", "User-Agent": "agent"}


def req(method, path, body=None, raw=False, timeout=180, url=None):
    data = None
    if body is not None:
        data = json.dumps(body).encode("utf-8")
        H2 = dict(H); H2["Content-Type"] = "application/json"
    else:
        H2 = dict(H)
    u = url or ("https://api.github.com" + path)
    r = urllib.request.Request(u, data=data, headers=H2, method=method)
    resp = urllib.request.urlopen(r, timeout=timeout)
    b = resp.read()
    return b if raw else json.loads(b.decode("utf-8"))


def md5f(path):
    h = hashlib.md5()
    with open(path, "rb") as f:
        for chunk in iter(lambda: f.read(1 << 20), b""):
            h.update(chunk)
    return h.hexdigest().upper()


print("zip md5", md5f(ZIP), "size", len(open(ZIP, "rb").read()))
print("apk md5", md5f(APK), "size", len(open(APK, "rb").read()))

base = req("GET", "/repos/%s/git/refs/heads/main" % R)["object"]["sha"]
tree_sha = req("GET", "/repos/%s/git/commits/%s" % (R, base))["tree"]["sha"]
print("base", base, "tree", tree_sha)

def blob(path, label):
    raw = open(path, "rb").read()
    print("uploading blob", label, len(raw), "bytes ...")
    t0 = time.time()
    r = req("POST", "/repos/%s/git/blobs" % R,
            {"content": base64.b64encode(raw).decode("ascii"), "encoding": "base64"}, timeout=600)
    print("  blob", r["sha"], "%.1fs" % (time.time() - t0))
    return r["sha"]

zsha = blob(ZIP, "source zip")
asha = blob(APK, "apk")

entries = [
    {"path": "05-源码归档/JZ音乐助手-安卓源码.zip", "mode": "100644", "type": "blob", "sha": zsha},
    {"path": "JZ Music-v2.1.79.apk", "mode": "100644", "type": "blob", "sha": asha},
    {"path": "JZ Music-v2.1.73.apk", "mode": "100644", "type": "blob", "sha": None},
]
nt = req("POST", "/repos/%s/git/trees" % R, {"base_tree": tree_sha, "tree": entries})
print("new tree", nt["sha"])

msg = ("第五版 v2.1.79：全部代码更新（源码归档换为 v2.1.79 完整工程：桌面歌词去掉底边进度条、"
       "逐字染色改按 KRC/QRC 逐字毫秒时间推进，纯 LRC 曲回退行内插值）+ 根目录 APK 换为 v2.1.79（vc137）")
c = req("POST", "/repos/%s/git/commits" % R, {"message": msg, "tree": nt["sha"], "parents": [base]})
print("new commit", c["sha"])
req("PATCH", "/repos/%s/git/refs/heads/main" % R, {"sha": c["sha"], "force": False})
print("main moved")

try:
    req("POST", "/repos/%s/git/refs" % R, {"ref": "refs/tags/" + TAG, "sha": c["sha"]})
    print("tag created", TAG)
except urllib.error.HTTPError as e:
    print("tag create failed", e.code, e.read()[:200])
    req("PATCH", "/repos/%s/git/refs/tags/%s" % (R, TAG), {"sha": c["sha"], "force": True})
    print("tag forced", TAG)

body = """## 桌面歌词：去掉底边进度条，逐字染色改按真实演唱时间

**逐字时间一直都在歌词源里**。实测酷狗 KRC 明文每个字都带毫秒级起点与时长（《暗号》那行 12 个字：153ms～545ms，**相差 3.6 倍**）。以前 `krcToLrc()` 把词条拼成整行、只留行级时间戳，逐字时间就是在这步被丢掉的——不是数据源只能给整行。

两个症状的三条根因：
1. 进度分母取到"下一行时间"，把句尾休止与间奏也算进本句 → 唱完还没染满；
2. 行内线性均分 → 拖长音时超前、快唱时滞后；
3. 数据侧逐字时间被压平丢弃。

### 本版改动
- **底边进度条整段删除**（函数、调用、`LinearGradient`/`Shader` 全部清除），栏高收紧 6dp；
- 新增 `LyricWord(text, startMs, durMs)`，`LyricLine` 带 `words`；新增 `krcToLines()`（行内相对毫秒 → 整首绝对毫秒）、`qrcToLines()`（带自适应基准），旧 `krcToLrc`/`qrcToLrc` 保留兜底；
- 视图层 `setWordTiming` / `setPosition` / `charFill`：每个字按 `(pos-起唱)/时长` 连续压深，**末字唱完立刻整句全亮，间奏期间保持全亮**；
- 采样 100ms；换句先推逐字时间再换文本，不再慢半拍；
- 映射不全时整行退回行内插值（宁可粗，不可错亮）。

### 验证
- 真实 KRC 回归 22 项全 PASS：49 行全带逐字时间、字符映射 0 未铺、17000ms 时"我/想/要"全亮＋"的"62%、19900ms（间奏中）12 字全亮；同刻"均分"只到 2.71 字；
- 静态验证 62 项 61 PASS，唯一缺口 `adb devices=0`（本机无设备，真机冒烟未做）；
- 降级边界：纯 LRC 曲只能回退行内插值；歌词与音频版本不一致时需"歌词延迟"调节，本版未做。

### 资产
- `JZ-Music-v2.1.79.apk` — vc137 / 2.1.79 纯净版
- `JZ-music-helper-android-source-v2.1.79.zip` — 完整源码归档（80 项，含字体资源）
"""

rel = req("POST", "/repos/%s/releases" % R,
          {"tag_name": TAG, "target_commitish": "main", "name": NAME, "body": body, "draft": False})
print("release id", rel["id"])
up = rel["upload_url"].split("{")[0]

assets = [(APK, "JZ-Music-v2.1.79.apk", "application/vnd.android.package-archive"),
          (ZIP, "JZ-music-helper-android-source-v2.1.79.zip", "application/zip")]
for path, nm, ct in assets:
    raw = open(path, "rb").read()
    print("uploading asset", nm, len(raw), "...")
    hh = {"Authorization": "token " + tok, "Content-Type": ct, "User-Agent": "agent"}
    u = up + "?" + urllib.parse.urlencode({"name": nm})
    r = urllib.request.Request(u, data=raw, headers=hh, method="POST")
    resp = urllib.request.urlopen(r, timeout=900)
    j = json.loads(resp.read().decode("utf-8"))
    print("  asset", j["name"], j["size"], j["state"], j["id"])

print("\nVERIFY")
rv = req("GET", "/repos/%s/releases/tags/%s" % (R, TAG))
print("tag:", rv["tag_name"], "name:", rv["name"], "draft:", rv["draft"])
for a in rv["assets"]:
    print("  ", a["name"], a["size"], a["state"], a["browser_download_url"])
tagref = req("GET", "/repos/%s/git/refs/tags/%s" % (R, TAG))
print("tag commit:", tagref["object"]["sha"], "expect", c["sha"])
print("main now:", req("GET", "/repos/%s/commits/main" % R)["sha"])
