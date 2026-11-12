# -*- coding: utf-8 -*-
"""向「音乐软件开发」群 webhook 推送本次逆向结论。"""
import json
import urllib.request

URL = "https://open.feishu.cn/open-apis/bot/v2/hook/20e2cec8-2f03-4147-95bd-2731b9fe66d7"
text = (
    "【笒音 2.0.1 逆向对照已出】\n"
    "1) 群里那个 base.apk 无加固壳，纯 Flutter（libapp.so 为 Dart AOT），砸壳不适用。\n"
    "2) 它在线音乐只用酷我单源：搜索 search.kuwo.cn/r.s + 移动聚合 mobi.kuwo.cn/mobi.s + web openapi。\n"
    "3) 我们缺的：酷我官方签名取流、酷我歌词 getlyric、酷我封面三形态、推荐流/歌单/专辑/榜单/评论/联想词/MV、mflac 本地解密。\n"
    "4) 已实测可用：searchKey 联想词、discover/v0 推荐流、getlyric 行级歌词、getRcmPlayList 歌单、三种封面 URL 形态。\n"
    "5) 未解：mobi.s 的 q 加密构造（需动态抓包或 Dart 反编译）。\n"
    "明细见工作区《笒音2.0.1-API逆向对照.md》。"
)
payload = {"msg_type": "text", "content": {"text": text}}
req = urllib.request.Request(URL, data=json.dumps(payload).encode("utf-8"),
                             headers={"Content-Type": "application/json"})
with urllib.request.urlopen(req, timeout=10) as r:
    print(r.read().decode("utf-8"))
