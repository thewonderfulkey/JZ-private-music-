# -*- coding: utf-8 -*-
"""用 token 校验 Release 资产与仓库文件（私有仓库匿名下载会 404，必须走带 token 的 API）。"""
import hashlib, os, subprocess

import requests

REPO = "thewonderfulkey/JZ-private-music-"
REPO_DIR = r"D:\Projects\Private_music"
OUT = r"C:\Users\17948\DoubaoWork\chats\2026-10-22\new-chat-1\_tmp_build"

p = subprocess.run(["git", "credential", "fill"], cwd=REPO_DIR,
                   input="protocol=https\nhost=github.com\n\n", capture_output=True, text=True)
tok = [l.split("=", 1)[1] for l in p.stdout.splitlines() if l.startswith("password=")][0]
H = {"Authorization": "token " + tok, "Accept": "application/vnd.github+json", "User-Agent": "agent"}

rel = requests.get("https://api.github.com/repos/%s/releases/tags/v2.1.72" % REPO, headers=H, timeout=30).json()
print("release:", rel["name"], "| tag:", rel["tag_name"], "| published:", rel["published_at"], "| updated:", rel["updated_at"])
for a in rel["assets"]:
    print("asset:", a["name"], a["size"], a["state"], a["id"])

# 下载 APK 资产并核对 MD5
asset = [a for a in rel["assets"] if a["name"].endswith(".apk")][0]
h2 = {"Authorization": "token " + tok, "Accept": "application/octet-stream", "User-Agent": "agent"}
r = requests.get("https://api.github.com/repos/%s/releases/assets/%d" % (REPO, asset["id"]), headers=h2, timeout=600)
data = r.content
print("download:", r.status_code, len(data), hashlib.md5(data).hexdigest().upper())

# 仓库内文件核对
for path in ["JZ Music-v2.1.72.apk", "05-源码归档/JZ音乐助手-安卓源码.zip"]:
    meta = requests.get("https://api.github.com/repos/%s/contents/%s" % (REPO, requests.utils.quote(path)),
                        headers=H, timeout=30).json()
    print("repo file:", path, meta.get("size"), meta.get("sha"))

# 最新 Release 标记
latest = requests.get("https://api.github.com/repos/%s/releases/latest" % REPO, headers=H, timeout=30).json()
print("latest:", latest["tag_name"], latest["name"])

# 远端 tag/commit 核对
out = subprocess.run(["git", "ls-remote", "origin", "refs/heads/main", "refs/tags/v2.1.72"],
                     cwd=REPO_DIR, capture_output=True, text=True).stdout
print(out.strip())
