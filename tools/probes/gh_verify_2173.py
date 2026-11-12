# -*- coding: utf-8 -*-
"""回读校验：Release 资产字节 + 仓库根目录文件清单（确认 v2.1.73 已替换、v2.1.72 已移除）。"""
import hashlib
import subprocess

import requests

OWNER_REPO = "thewonderfulkey/JZ-private-music-"
API = "https://api.github.com"
p = subprocess.run([r"D:\Git\cmd\git.exe", "credential", "fill"],
                   input="protocol=https\nhost=github.com\n\n", capture_output=True, text=True)
tok = [l.split("=", 1)[1] for l in p.stdout.splitlines() if l.startswith("password=")][0]
H = {"Authorization": "token " + tok, "Accept": "application/vnd.github+json", "User-Agent": "agent"}

rel = requests.get(f"{API}/repos/{OWNER_REPO}/releases/tags/v2.1.73", headers=H, timeout=60).json()
print("release:", rel["id"], rel["name"], rel["tag_name"], "published_at", rel["published_at"])
for a in rel["assets"]:
    url = a["url"]
    r = requests.get(url, headers={**H, "Accept": "application/octet-stream"}, timeout=600)
    data = r.content
    print("asset", a["name"], len(data), "md5", hashlib.md5(data).hexdigest().upper(), "http", r.status_code)

root = requests.get(f"{API}/repos/{OWNER_REPO}/git/trees/main", headers=H, timeout=60).json()
print("root entries:")
for e in root["tree"]:
    print("  ", e["type"], e["path"])
