# -*- coding: utf-8 -*-
"""2026-11-28 取证（第六组）：妖狐酷我的搜索词拼法。

`NameMatch.yaohuSearchKey` = `coreName(歌名) + primarySinger(歌手)`，**不加空格**。
唯一能出直链的那条腿（妖狐有这首歌的真 FLAC），如果被这个拼法拆掉，整首就无源。
这里把「无空格 / 有空格 / 只歌名 / 英文歌手」四种拼法都打一遍，看它认哪个。
"""
import json
import time
import urllib.parse

import requests

UA = {"User-Agent": "Mozilla/5.0 (iPhone; CPU iPhone OS 17_0 like Mac OS X)",
      "X-Client-Software": "lx"}
KEY = "nvgKtvzw7CFSNFrDhA6"

CASES = [
    ("App 实际拼法（无空格）", "BABY ANGEL林娜琏"),
    ("有空格", "BABY ANGEL 林娜琏"),
    ("只歌名", "BABY ANGEL"),
    ("英文歌手", "BABY ANGEL NAYEON"),
]

for label, kw in CASES:
    url = ("https://api.yaohud.cn/api/music/kuwo?key=%s&action=search&msg=%s&n=1"
           % (KEY, urllib.parse.quote(kw)))
    try:
        r = requests.get(url, headers=UA, timeout=15)
        j = r.json()
    except Exception as e:  # noqa: BLE001
        print("[%s] %r → 异常 %s" % (label, kw, type(e).__name__))
        time.sleep(1.5)
        continue
    code = j.get("code")
    d = j.get("data") or {}
    print("[%s] %r  code=%s msg=%s" % (label, kw, code, str(j.get("msg"))[:30]))
    if isinstance(d, dict) and d:
        vm = d.get("vipmusic") or {}
        print("     name=%r songname=%r songtitle=%r" %
              (d.get("name"), d.get("songname"), d.get("songtitle")))
        print("     vipmusic level=%s bitrate=%s url=%s" %
              (vm.get("level"), vm.get("bitrate"), "有" if vm.get("url") else "空"))
    else:
        print("     data 为空")
    time.sleep(1.6)
