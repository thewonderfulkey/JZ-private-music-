# -*- coding: utf-8 -*-
"""取 request.js 里的默认 host 与 android 公共参数拼装。"""
import re, urllib.parse, urllib.request

REPO, BR = "MakcRe/KuGouMusicApi", "main"


def raw(path):
    u = "https://raw.githubusercontent.com/%s/%s/%s" % (REPO, BR, urllib.parse.quote(path))
    return urllib.request.urlopen(urllib.request.Request(u, headers={"User-Agent": "agent"}),
                                  timeout=40).read().decode("utf-8", "replace")


t = raw("util/request.js")
print("len", len(t))
for kw in ["gateway", "baseURL", "signature", "appid", "clientver", "dfid", "platform"]:
    print("\n--- hits for", kw)
    for m in re.finditer(kw, t):
        s = max(0, m.start() - 120)
        print(t[s:m.start() + 160].replace("\n", " | ")[-260:])
        print("  ---")
