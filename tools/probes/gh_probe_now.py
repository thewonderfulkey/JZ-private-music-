# -*- coding: utf-8 -*-
"""GitHub 现状探查：release 列表 / tag / main 最新提交与文件树概况"""
import json, subprocess, sys, base64

GIT = r"D:\Git\cmd\git.exe"
OWNER_REPO = "thewonderfulkey/JZ-private-music-"

p = subprocess.run([GIT, "credential", "fill"],
                   input="protocol=https\nhost=github.com\n\n",
                   capture_output=True, text=True)
tok = [l.split("=", 1)[1] for l in p.stdout.splitlines() if l.startswith("password=")][0]
H = {"Authorization": "token " + tok, "Accept": "application/vnd.github+json",
     "User-Agent": "agent"}
import urllib.request

def get(path):
    req = urllib.request.Request("https://api.github.com" + path, headers=H)
    return json.loads(urllib.request.urlopen(req, timeout=30).read().decode("utf-8"))

rels = get("/repos/%s/releases?per_page=20" % OWNER_REPO)
print("RELEASES:", len(rels))
for r in rels:
    print("  id=%s tag=%s name=%s draft=%s published=%s assets=%s" % (
        r["id"], r["tag_name"], r["name"], r["draft"], r["published_at"],
        [(a["name"], a["size"], a["state"]) for a in r["assets"]]))

tags = get("/repos/%s/tags?per_page=20" % OWNER_REPO)
print("TAGS:", [t["name"] for t in tags])

ref = get("/repos/%s/git/refs/heads/main" % OWNER_REPO)
sha = ref["object"]["sha"]
print("MAIN SHA:", sha)
cm = get("/repos/%s/git/commits/%s" % (OWNER_REPO, sha))
print("COMMIT MSG:", cm["message"].splitlines()[0], "date:", cm["committer"]["date"])
tree = get("/repos/%s/git/trees/%s?recursive=1" % (OWNER_REPO, cm["tree"]["sha"]))
blobs = [e for e in tree["tree"] if e["type"] == "blob"]
print("FILES:", len(blobs), "truncated:", tree.get("truncated"))
for e in blobs[:15]:
    print("   ", e["path"], e["size"])
print("...")
for e in blobs[-10:]:
    print("   ", e["path"], e["size"])
