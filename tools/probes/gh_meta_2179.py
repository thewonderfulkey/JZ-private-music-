# -*- coding: utf-8 -*-
import json, subprocess, urllib.request
GIT = r"D:\Git\cmd\git.exe"
R = "thewonderfulkey/JZ-private-music-"
p = subprocess.run([GIT, "credential", "fill"], input="protocol=https\nhost=github.com\n\n",
                   capture_output=True, text=True)
tok = [l.split("=", 1)[1] for l in p.stdout.splitlines() if l.startswith("password=")][0]
H = {"Authorization": "token " + tok, "Accept": "application/vnd.github+json", "User-Agent": "agent"}
rel = json.loads(urllib.request.urlopen(urllib.request.Request(
    "https://api.github.com/repos/%s/releases/tags/v2.1.79" % R, headers=H), timeout=60).read().decode())
print("html_url:", rel["html_url"])
print("created:", rel["created_at"], "published:", rel["published_at"])
print("body_len:", len(rel["body"]))
print("total releases:", len(json.loads(urllib.request.urlopen(urllib.request.Request(
    "https://api.github.com/repos/%s/releases" % R, headers=H), timeout=60).read().decode())))
