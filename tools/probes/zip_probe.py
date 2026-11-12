# -*- coding: utf-8 -*-
import io, zipfile

p = r"D:\Projects\Private_music\05-源码归档\JZ音乐助手-安卓源码.zip"
with zipfile.ZipFile(p) as z:
    n = z.namelist()
print("entries:", len(n))
print("top-level:", sorted(set(x.split("/")[0] for x in n))[:20])
ex = [x for x in n if "/build/" in x or x.startswith("build/") or ".gradle" in x or "local.properties" in x]
print("excluded-suspect count:", len(ex), ex[:5])
print("sample:", n[:8])
