# -*- coding: utf-8 -*-
import json, subprocess, urllib.request

REPO = "thewonderfulkey/JZ-private-music-"
p = subprocess.run(["git", "credential", "fill"], input="protocol=https\nhost=github.com\n\n",
                   capture_output=True, text=True, cwd=r"D:\Projects\Private_music")
tok = [l.split("=", 1)[1] for l in p.stdout.splitlines() if l.startswith("password=")][0]
H = {"Authorization": "token " + tok, "Accept": "application/vnd.github+json", "User-Agent": "agent"}


def get(url):
    req = urllib.request.Request(url, headers=H)
    return json.loads(urllib.request.urlopen(req, timeout=30).read().decode("utf-8"))


rels = get("https://api.github.com/repos/%s/releases?per_page=50" % REPO)
print("releases: %d" % len(rels))
for r in rels:
    print("- id=%s tag=%s name=%s draft=%s prerelease=%s published=%s assets=%s" % (
        r["id"], r["tag_name"], r["name"], r["draft"], r["prerelease"], r["published_at"],
        [a["name"] for a in r["assets"]]))
print("latest:", get("https://api.github.com/repos/%s/releases/latest" % REPO)["name"])
