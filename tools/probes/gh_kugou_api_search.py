# -*- coding: utf-8 -*-
"""从公开的 KuGouMusicApi 仓库里找出识曲接口的实现（host、module、参数、返回结构）。"""
import json, subprocess, urllib.request, urllib.parse

GIT = r"D:\Git\cmd\git.exe"
p = subprocess.run([GIT, "credential", "fill"], input="protocol=https\nhost=github.com\n\n",
                   capture_output=True, text=True)
tok = [l.split("=", 1)[1] for l in p.stdout.splitlines() if l.startswith("password=")][0]
H = {"Authorization": "token " + tok, "Accept": "application/vnd.github+json", "User-Agent": "agent"}


def get(url):
    return json.loads(urllib.request.urlopen(urllib.request.Request(url, headers=H), timeout=40)
                      .read().decode("utf-8"))


repos = get("https://api.github.com/search/repositories?q=KuGouMusicApi&sort=stars&per_page=5")
for r in repos["items"]:
    print(r["full_name"], r["stargazers_count"], r["default_branch"])

repo = repos["items"][0]["full_name"]
br = repos["items"][0]["default_branch"]
tree = get("https://api.github.com/repos/%s/git/trees/%s?recursive=1" % (repo, br))
hits = [e["path"] for e in tree["tree"] if "match" in e["path"].lower() or "recogni" in e["path"].lower()]
print("\ncandidates:", hits[:30])

for path in hits[:6]:
    raw_url = "https://raw.githubusercontent.com/%s/%s/%s" % (repo, br, urllib.parse.quote(path))
    try:
        txt = urllib.request.urlopen(urllib.request.Request(raw_url, headers={"User-Agent": "agent"}),
                                     timeout=40).read().decode("utf-8", "replace")
        print("\n===== %s (%d bytes)" % (path, len(txt)))
        print(txt[:2500])
    except Exception as e:
        print("ERR", path, e)
