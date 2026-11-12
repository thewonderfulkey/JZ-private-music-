# -*- coding: utf-8 -*-
"""取 helper.js（android 签名）与 config.json（appid/clientver）与 request.js 的默认 baseURL。"""
import urllib.parse, urllib.request

REPO, BR = "MakcRe/KuGouMusicApi", "main"


def raw(path):
    u = "https://raw.githubusercontent.com/%s/%s/%s" % (REPO, BR, urllib.parse.quote(path))
    return urllib.request.urlopen(urllib.request.Request(u, headers={"User-Agent": "agent"}),
                                  timeout=40).read().decode("utf-8", "replace")


for p in ["util/config.json", "util/helper.js"]:
    t = raw(p)
    print("\n===== %s (%d bytes)" % (p, len(t)))
    if p.endswith(".json"):
        print(t[:800])
    else:
        # 只打印签名相关片段
        import re
        for m in re.finditer(r"(signatureAndroidParams|function|=>)[\s\S]{0,80}", t):
            pass
        print(t[:5000])
