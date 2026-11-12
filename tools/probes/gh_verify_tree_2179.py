# -*- coding: utf-8 -*-
"""补校验：main 最新提交的树里，根 APK 是否已换为 v2.1.79、旧 v2.1.73 是否已移除、源码归档条目是否更新。"""
import json, subprocess, urllib.request

GIT = r"D:\Git\cmd\git.exe"
R = "thewonderfulkey/JZ-private-music-"
p = subprocess.run([GIT, "credential", "fill"], input="protocol=https\nhost=github.com\n\n",
                   capture_output=True, text=True)
tok = [l.split("=", 1)[1] for l in p.stdout.splitlines() if l.startswith("password=")][0]
H = {"Authorization": "token " + tok, "Accept": "application/vnd.github+json", "User-Agent": "agent"}

def get(path):
    return json.loads(urllib.request.urlopen(
        urllib.request.Request("https://api.github.com" + path, headers=H), timeout=60).read().decode("utf-8"))

head = get("/repos/%s/git/refs/heads/main" % R)["object"]["sha"]
cm = get("/repos/%s/git/commits/%s" % (R, head))
print("main", head)
print("msg:", cm["message"].splitlines()[0])
tree = get("/repos/%s/git/trees/%s?recursive=1" % (R, cm["tree"]["sha"]))
paths = {e["path"]: e for e in tree["tree"] if e["type"] == "blob"}
print("file count:", len(paths))
for k in sorted(paths):
    if k.count("/") == 0 and k.lower().endswith(".apk"):
        print("ROOT APK:", k, paths[k]["size"])
print("v2.1.73 apk present:", "JZ Music-v2.1.73.apk" in paths)
z = paths.get("05-源码归档/JZ音乐助手-安卓源码.zip")
print("archive:", z["size"] if z else None, z["sha"] if z else None)
print("archive sha == uploaded blob d9e040a:", z and z["sha"] == "d9e040aebd2cbda01be927c389f6894ca61c0a20")
tag = get("/repos/%s/git/refs/tags/v2.1.79" % R)["object"]["sha"]
print("tag v2.1.79 ->", tag, "== main:", tag == head)
