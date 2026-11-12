# -*- coding: utf-8 -*-
"""取 KuGouMusicApi 的 util（默认 baseURL / android 签名算法）以复刻请求。"""
import json, urllib.parse, urllib.request

REPO, BR = "MakcRe/KuGouMusicApi", "main"


def raw(path):
    u = "https://raw.githubusercontent.com/%s/%s/%s" % (REPO, BR, urllib.parse.quote(path))
    return urllib.request.urlopen(urllib.request.Request(u, headers={"User-Agent": "agent"}),
                                 timeout=40).read().decode("utf-8", "replace")


txt = raw("util/index.js")
print("===== util/index.js (%d bytes)" % len(txt))
print(txt[:6000])
