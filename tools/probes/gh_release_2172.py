# -*- coding: utf-8 -*-
"""把「第四版」Release 改版为 v2.1.72：换 tag、换名、换正文、换资产（ASCII 资产名）。"""
import json, os, subprocess

import requests

REPO = "thewonderfulkey/JZ-private-music-"
ROOT = r"C:\Users\17948\DoubaoWork\chats\2026-10-22\new-chat-1"
REPO_DIR = r"D:\Projects\Private_music"
APK = os.path.join(ROOT, r"_tmp_fb3\JZ音乐助手-v2.1.72.apk")
ZIP = os.path.join(ROOT, r"_tmp_build\JZ音乐助手-安卓源码.zip")

p = subprocess.run(["git", "credential", "fill"], cwd=REPO_DIR,
                   input="protocol=https\nhost=github.com\n\n", capture_output=True, text=True)
tok = [l.split("=", 1)[1] for l in p.stdout.splitlines() if l.startswith("password=")][0]
H = {"Authorization": "token " + tok, "Accept": "application/vnd.github+json", "User-Agent": "agent"}

BODY = """## JZ音乐助手 v2.1.72（vc130）· 第四版 · 最终版

### 本版改动（唯一一份说明）

**修复「后台 / 息屏播完不自动切歌」**

实机复测确认根因：Android 的 Doze（低电耗模式）在熄屏一段时间后会**暂停应用的后台网络访问**——WiFi 图标仍显示已连接，但应用发出的取流请求直接超时，播完一首取不到下一首就停住；回到前台限制解除，表现为「打开 App 才切歌」。本版对应三处改动：

1. **首次打开自动申请「不受电池优化限制」**：装好第一次启动会自动弹出系统授权框，点一次「允许」即永久生效，不需要自己去设置里翻菜单。
2. **多首预取兜底**：前台有网时把队列里后面 **3 首**整首缓存到本地（`cacheDir/prefetch/`，最多 4 槽滚动淘汰），后台即便被断网也能按缓存继续往下唱。
3. **设置页「后台连播 · 电池优化白名单」常驻**：随时可自查是否已放行；未放行时点「去允许」直接弹系统授权框，状态每 1.5 秒自动刷新。

**修复「已成功播放仍挂红字『暂无可用的播放源，正在换源重试…』」**

重试轮里成功起播的那条路径此前没有清空错误状态，导致歌在唱、红字还挂着；现在任何一次成功起播都会清掉提示。

**其他**

等网络恢复的续播不再要求屏幕亮着（上一版这个条件会让息屏状态永久等待）；设置页的播放日志已移除。

### 安装

下载下方 APK 直接安装（覆盖安装即可，保留原有收藏与下载记录）。首次启动若弹出「允许应用不受电池优化限制」，请点「允许」。

### 内容

- `JZ-Music-v2.1.72.apk`：安卓安装包（versionCode 130 / versionName 2.1.72，29,601,583 字节，MD5 `1457598DAB378EA0EBAC6FE1D10CB09D`）
- `JZ-music-helper-android-source-v2.1.72.zip`：完整安卓工程源码归档（78 个条目，含全部 Kotlin 源码与资源）

### 声明

音乐源为第三方接口的聚合结果，仅供个人学习与测试，请支持正版音乐。"""

# 1) 找「第四版」现有 Release
rels = requests.get("https://api.github.com/repos/%s/releases" % REPO, headers=H, timeout=30).json()
target = None
for r in rels:
    if "第四版" in (r.get("name") or ""):
        target = r
        break
print("releases:", [(r["id"], r["tag_name"], r["name"]) for r in rels])

if target is None:
    raise SystemExit("no 第四版 release found")

rel_id = target["id"]
print("target id:", rel_id, "old tag:", target["tag_name"], "old assets:", [a["name"] for a in target["assets"]])

# 2) 改 tag / 名 / 正文
r = requests.patch("https://api.github.com/repos/%s/releases/%d" % (REPO, rel_id), headers=H,
                   json={"tag_name": "v2.1.72", "target_commitish": "main",
                         "name": "第四版 v2.1.72（最终版）", "body": BODY, "draft": False}, timeout=60)
print("PATCH", r.status_code)
r.raise_for_status()

# 3) 删旧资产
for a in target["assets"]:
    d = requests.delete("https://api.github.com/repos/%s/releases/assets/%d" % (REPO, a["id"]), headers=H, timeout=60)
    print("DELETE asset", a["name"], d.status_code)

# 4) 上传新资产（ASCII 名）
up = r.json()["upload_url"].split("{")[0]
for path, name, ctype in [(ZIP, "JZ-music-helper-android-source-v2.1.72.zip", "application/zip"),
                          (APK, "JZ-Music-v2.1.72.apk", "application/vnd.android.package-archive")]:
    with open(path, "rb") as f:
        u = requests.post(up, headers={"Authorization": "token " + tok, "Content-Type": ctype,
                                       "User-Agent": "agent"},
                          params={"name": name}, data=f, timeout=600)
    print("UPLOAD", name, u.status_code, u.json().get("state"), u.json().get("size"))

# 5) 回读
v = requests.get("https://api.github.com/repos/%s/releases/tags/v2.1.72" % REPO, headers=H, timeout=30).json()
print("VERIFY tag:", v["tag_name"], "| name:", v["name"], "| draft:", v["draft"])
for a in v["assets"]:
    print("ASSET", a["name"], a["size"], a["state"], a["browser_download_url"])
latest = requests.get("https://api.github.com/repos/%s/releases/latest" % REPO, headers=H, timeout=30).json()
print("LATEST:", latest["tag_name"], latest["name"], "id", latest["id"])
