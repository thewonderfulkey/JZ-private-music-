# -*- coding: utf-8 -*-
"""v2.1.73：用 GitHub REST（api.github.com 可达，git 的 TLS 此刻握手失败）更新仓库内容 + 打 tag +
把「第四版」Release 改指向 v2.1.73 并换资产。资产名一律 ASCII。"""
import base64
import io
import json
import subprocess
import sys
import time

import requests

OWNER_REPO = "thewonderfulkey/JZ-private-music-"
API = "https://api.github.com"
APK = r"C:\Users\17948\DoubaoWork\chats\2026-10-22\new-chat-1\_tmp_fb3\JZ音乐助手-v2.1.73.apk"
ZIP = r"C:\Users\17948\DoubaoWork\chats\2026-10-22\new-chat-1\_tmp_build\JZ音乐助手-安卓源码.zip"
LOG = r"C:\Users\17948\DoubaoWork\chats\2026-10-22\new-chat-1\_tmp_build\gh_rel_2173.txt"

lines = []


def log(*a):
    s = " ".join(str(x) for x in a)
    print(s)
    lines.append(s)


p = subprocess.run([r"D:\Git\cmd\git.exe", "credential", "fill"],
                   input="protocol=https\nhost=github.com\n\n",
                   capture_output=True, text=True)
tok = [l.split("=", 1)[1] for l in p.stdout.splitlines() if l.startswith("password=")][0]
H = {"Authorization": "token " + tok, "Accept": "application/vnd.github+json",
     "User-Agent": "agent"}


def api(method, path, **kw):
    r = requests.request(method, API + path, headers=H, timeout=180, **kw)
    if r.status_code >= 400:
        log(f"[HTTP {r.status_code}] {method} {path} -> {r.text[:400]}")
        raise SystemExit(1)
    return r.json() if r.text else {}


# ---------- 1. 仓库内容：blob -> tree -> commit -> ref ----------
ref = api("GET", f"/repos/{OWNER_REPO}/git/refs/heads/main")
base_sha = ref["object"]["sha"]
base_commit = api("GET", f"/repos/{OWNER_REPO}/git/commits/{base_sha}")
base_tree = base_commit["tree"]["sha"]
log("base main:", base_sha[:7], "tree:", base_tree[:7])

apk_bytes = io.open(APK, "rb").read()
zip_bytes = io.open(ZIP, "rb").read()

def blob(data):
    r = api("POST", f"/repos/{OWNER_REPO}/git/blobs",
            json={"content": base64.b64encode(data).decode("ascii"), "encoding": "base64"})
    return r["sha"]

apk_blob = blob(apk_bytes)
log("apk blob:", apk_blob[:7], len(apk_bytes))
zip_blob = blob(zip_bytes)
log("zip blob:", zip_blob[:7], len(zip_bytes))

tree = api("POST", f"/repos/{OWNER_REPO}/git/trees", json={
    "base_tree": base_tree,
    "tree": [
        {"path": "JZ Music-v2.1.73.apk", "mode": "100644", "type": "blob", "sha": apk_blob},
        {"path": "JZ Music-v2.1.72.apk", "mode": "100644", "type": "blob", "sha": None},
        {"path": "05-源码归档/JZ音乐助手-安卓源码.zip", "mode": "100644", "type": "blob", "sha": zip_blob},
    ],
})
log("new tree:", tree["sha"][:7])

MSG = ("第四版 v2.1.73：全部代码更新（源码归档换为 v2.1.73 完整工程，平板/横屏自适应："
       "开屏按屏高等比 + 墨图左对齐、播放页三套版式（手机竖屏基准 / 平板画心随屏放大 / 横屏左右式））"
       "+ 根目录 APK 换为 v2.1.73（vc131）")
commit = api("POST", f"/repos/{OWNER_REPO}/git/commits",
             json={"message": MSG, "tree": tree["sha"], "parents": [base_sha]})
log("new commit:", commit["sha"][:7])

r = api("PATCH", f"/repos/{OWNER_REPO}/git/refs/heads/main",
        json={"sha": commit["sha"], "force": False})
log("main ->", r["object"]["sha"][:7])

# tag
try:
    api("POST", f"/repos/{OWNER_REPO}/git/refs",
        json={"ref": "refs/tags/v2.1.73", "sha": commit["sha"]})
    log("tag v2.1.73 已创建 ->", commit["sha"][:7])
except SystemExit:
    log("tag 已存在，改为强制更新")
    api("PATCH", f"/repos/{OWNER_REPO}/git/refs/tags/v2.1.73",
        json={"sha": commit["sha"], "force": True})

# ---------- 2. 第四版 Release 改指向 v2.1.73 ----------
rel = api("GET", f"/repos/{OWNER_REPO}/releases/tags/v2.1.72")
rel_id = rel["id"]
log("旧 Release:", rel_id, rel["name"], rel["tag_name"], "assets:", [a["name"] for a in rel["assets"]])

BODY = """## 第四版 v2.1.73（vc131）· 平板与横屏自适应

以手机竖屏（540×1172 实机）为基准，按开发群两段实机录屏（手机完美 / iPad 有缺陷）逐帧比对后改的三件事：

**1. 开屏：从"横纵各拉一次"改成"按屏高等比"**
- 旧实现按 390×844 设计稿直接铺满画布，iPad 800×1280 上横向比纵向多拉约 35%，山体压成横向扁带、上下各留一条纸白，题字与朱印相对屏幕极小。
- 现改为 `k = 屏高 / 844` 等比缩放，墨图按 633 设计位左对齐（窄屏裁右缘、宽屏居中）；山水、题字、跳过按钮、音符收尾洞口共用同一套映射。
- 手机观感零变化；超宽/横屏开屏不再被压扁。

**2. 平板播放页：画心不再被常量 dp 锁死**
- 旧版画心取 `min(档位常量 258/392dp, 白框宽, 可用高)`，平板上前两项是常量，屏幕再高也不放大，余量堆到屏底 → 底部 22–30% 空白。
- 现分三套版式：手机竖屏（基准，未改动）/ 平板竖屏（画心上限取消，列宽 720dp 内随屏放大，段落按权重纵向铺满）/ 横屏左右式。
- iPad 竖屏：画心 392 → 644dp，白框占屏宽 84%。

**3. 横屏统一成左右式（手机 + iPad 同一套）**
- 左：白框封面，双击出歌词（再双击回封面）；右：题名/歌手、墨线进度、五件控件（循环·上一·朱砂暂停·下一·下载）、状态行、音源行。
- 手机横屏原来封面整块消失（矮屏回退手机档、画心被可用高压到接近 0），该路径已移除。

**安装**：`JZ-Music-v2.1.73.apk`（29,617,967 B，vc131，包名 com.jz.musichelper），覆盖安装即可，数据不丢。

**验证**：静态验证 34 项全通过（版本/包名/签名 v2/zip 完整性 183 项/前台服务与曲终唤醒组件/7 项权限/关于页版本三方一致）。缺口：构建机 `adb devices` 为空，未做真机冒烟，版式靠数值核算与代码审查。

**历史**：本 Release 前身为「第四版 v2.1.72」，已被本版取代；v2.1.72 的 APK 与源码仍在仓库历史提交 `ee2ec70` 中。"""

patch = api("PATCH", f"/repos/{OWNER_REPO}/releases/{rel_id}",
            json={"tag_name": "v2.1.73", "target_commitish": "main",
                  "name": "第四版 v2.1.73", "body": BODY})
log("Release 已改版:", patch["id"], patch["name"], patch["tag_name"], patch["html_url"])

for a in patch["assets"]:
    api("DELETE", f"/repos/{OWNER_REPO}/releases/assets/{a['id']}")
    log("删除旧资产:", a["name"], a["id"])

up = patch["upload_url"].split("{")[0]
for path, name, ctype in [
    (APK, "JZ-Music-v2.1.73.apk", "application/vnd.android.package-archive"),
    (ZIP, "JZ-music-helper-android-source-v2.1.73.zip", "application/zip"),
]:
    data = io.open(path, "rb").read()
    resp = requests.post(up, headers={"Authorization": "token " + tok,
                                      "Content-Type": ctype,
                                      "User-Agent": "agent"},
                         params={"name": name}, data=data, timeout=600)
    log("上传", name, resp.status_code, len(data), "B")

time.sleep(3)
back = api("GET", f"/repos/{OWNER_REPO}/releases/tags/v2.1.73")
log("回读 tag:", back["tag_name"], "|", back["name"], "| assets:")
for a in back["assets"]:
    log("   ", a["name"], a["size"], a["state"], a["id"])
log("latest:", api("GET", f"/repos/{OWNER_REPO}/releases/latest")["tag_name"])
log("commit 回读:", api("GET", f"/repos/{OWNER_REPO}/commits/main")["sha"][:7])

io.open(LOG, "w", encoding="utf-8", newline="").write("\n".join(lines) + "\n")
