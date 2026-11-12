# -*- coding: utf-8 -*-
"""读取 KuGouMusicApi 的 public/audio_match.html 前端示例，确认采样率/位深/时长/请求方式。"""
import re, urllib.parse, urllib.request

REPO, BR = "MakcRe/KuGouMusicApi", "main"
u = "https://raw.githubusercontent.com/%s/%s/public/audio_match.html" % (REPO, BR)
t = urllib.request.urlopen(urllib.request.Request(u, headers={"User-Agent": "agent"}),
                           timeout=40).read().decode("utf-8", "replace")
# 只打印 <script> 段
for m in re.finditer(r"<script[^>]*>([\s\S]*?)</script>", t):
    s = m.group(1)
    print("\n===== script block (%d bytes)" % len(s))
    print(s[:5000])
