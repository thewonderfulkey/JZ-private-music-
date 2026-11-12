# -*- coding: utf-8 -*-
"""检查远端文档中出现的版本号，确定仓库里除源码归档/根 APK 外还需要改哪些文件。"""
import json, subprocess, base64, urllib.request

GIT = r"D:\Git\cmd\git.exe"
R = "thewonderfulkey/JZ-private-music-"
p = subprocess.run([GIT, "credential", "fill"], input="protocol=https\nhost=github.com\n\n",
                   capture_output=True, text=True)
tok = [l.split("=", 1)[1] for l in p.stdout.splitlines() if l.startswith("password=")][0]
H = {"Authorization": "token " + tok, "Accept": "application/vnd.github+json", "User-Agent": "agent"}

def get(path, raw=False):
    req = urllib.request.Request("https://api.github.com" + path, headers=H)
    data = urllib.request.urlopen(req, timeout=30).read()
    if raw:
        return data
    return json.loads(data.decode("utf-8"))

sha = get("/repos/%s/git/refs/heads/main" % R)["object"]["sha"]
tree = get("/repos/%s/git/trees/%s?recursive=1" % (R, get("/repos/%s/git/commits/%s" % (R, sha))["tree"]["sha"]))

cands = [e for e in tree["tree"] if e["type"] == "blob" and
         (e["path"].lower().endswith((".md", ".txt")) and ("06-" in e["path"] or e["path"].count("/") <= 1))]
print("candidate text files:")
for e in cands:
    print("  ", e["path"], e["size"])

for e in cands:
    b = get("/repos/%s/git/blobs/%s" % (R, e["sha"]))
    txt = base64.b64decode(b["content"]).decode("utf-8", "replace")
    hits = [l.strip() for l in txt.splitlines() if "2.1.7" in l or "2.0.4" in l or "versionName" in l.lower()]
    if hits:
        print("\n== %s" % e["path"])
        for l in hits[:12]:
            print("   ", l[:160])
