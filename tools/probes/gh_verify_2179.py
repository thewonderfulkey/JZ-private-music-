# -*- coding: utf-8 -*-
"""发布后回读校验：下载两个资产核对 MD5 + 检查 main 树里的文件名替换是否生效。"""
import base64, hashlib, json, subprocess, urllib.request

GIT = r"D:\Git\cmd\git.exe"
R = "thewonderfulkey/JZ-private-music-"
p = subprocess.run([GIT, "credential", "fill"], input="protocol=https\nhost=github.com\n\n",
                   capture_output=True, text=True)
tok = [l.split("=", 1)[1] for l in p.stdout.splitlines() if l.startswith("password=")][0]
H = {"Authorization": "token " + tok, "Accept": "application/vnd.github+json", "User-Agent": "agent"}

def get(path):
    return json.loads(urllib.request.urlopen(
        urllib.request.Request("https://api.github.com" + path, headers=H), timeout=60).read().decode("utf-8"))

def dl(url):
    hh = {"Authorization": "token " + tok, "Accept": "application/octet-stream", "User-Agent": "agent"}
    return urllib.request.urlopen(urllib.request.Request(url, headers=hh), timeout=900).read()

rel = get("/repos/%s/releases/tags/v2.1.79" % R)
print("release", rel["id"], rel["tag_name"], rel["name"], "assets", len(rel["assets"]))
for a in rel["assets"]:
    raw = dl(a["url"])
    md5 = hashlib.md5(raw).hexdigest().upper()
    print("  %s  size=%d (api %d)  md5=%s  state=%s" % (a["name"], len(raw), a["size"], md5, a["state"]))

tree = get("/repos/%s/git/trees/%s?recursive=1" % (R, get("/repos/%s/git/commits/main" % R)["tree"]["sha"]))
paths = {e["path"]: e for e in tree["tree"] if e["type"] == "blob"}
print("\nroot APK entries:")
for k in paths:
    if k.count("/") == 0 and k.lower().endswith(".apk"):
        print("   ", k, paths[k]["size"])
print("archive:", "05-源码归档/JZ音乐助手-安卓源码.zip" in paths, paths.get("05-源码归档/JZ音乐助手-安卓源码.zip", {}).get("size"))
print("old apk still present:", "JZ Music-v2.1.73.apk" in paths)
print("file count:", len(paths))
print("tags:", [t["name"] for t in get("/repos/%s/tags?per_page=10" % R)])
print("releases:", [(r["tag_name"], r["name"]) for r in get("/repos/%s/releases?per_page=5" % R)])
