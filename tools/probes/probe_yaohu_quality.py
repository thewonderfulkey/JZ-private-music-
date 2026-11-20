# -*- coding: utf-8 -*-
"""验妖狐酷我通道能不能按档位取 320k（酷我歌的播放链只有它一个后端）。

背景：`YaohuKuwoAdapter` 现在**忽略** quality 参数，`vipmusic.url` 常常是 FLAC（26MB/1082kbps）。
A 方案要求"播放链 ≤320k、FLAC 不进播放链"，如果这条通道拿不到 320k，酷我歌就会全部变成"无源"。
这里试几种可能的档位参数，看服务端认哪个。
"""
import json
import urllib.parse
import urllib.request

UA = ("Mozilla/5.0 (iPhone; CPU iPhone OS 16_6 like Mac OS X) AppleWebKit/605.1.15 "
      "(KHTML, like Gecko) Version/16.6 Mobile/15E148 Safari/604.1")
KEY = "nvgKtvzw7CFSNFrDhA6"


def get(url, timeout=20):
    req = urllib.request.Request(url, headers={"User-Agent": UA, "X-Client-Software": "lx"})
    with urllib.request.urlopen(req, timeout=timeout) as r:
        return json.loads(r.read().decode("utf-8", "replace"))


def probe(msg, extra=""):
    url = ("https://api.yaohud.cn/api/music/kuwo?key=%s&action=search&msg=%s&n=1%s"
           % (KEY, urllib.parse.quote(msg), extra))
    try:
        j = get(url)
    except Exception as e:  # noqa: BLE001
        return {"extra": extra or "(无)", "err": repr(e)[:60]}
    vm = j.get("vipmusic") or {}
    data = j.get("data") or {}
    u = vm.get("url") or ""
    return {
        "extra": extra or "(无)",
        "code": j.get("code"),
        "title": data.get("songtitle") or data.get("name"),
        "singer": data.get("songname"),
        "level": vm.get("level"),
        "size": vm.get("size") or vm.get("filesize"),
        "url_tail": u[-42:] if u else "",
        "url_len": len(u),
    }


for msg in ("晴天周杰伦", "夜曲周杰伦"):
    print("=== %s ===" % msg)
    for extra in ("", "&level=320", "&level=exhigh", "&br=320", "&quality=320", "&level=standard"):
        print(probe(msg, extra))
