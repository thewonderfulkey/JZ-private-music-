# -*- coding: utf-8 -*-
import json
import urllib.request

URL = "https://open.feishu.cn/open-apis/bot/v2/hook/20e2cec8-2f03-4147-95bd-2731b9fe66d7"

text = (
    "【新版本已发群】JZ的音乐助手 v2.1.86\n"
    "识曲结果页重做：方角纸签 + 「识 所 得」眉标 + 朱砂小印 + 歌名断句线，歌手与专辑分层；"
    "只留一块墨底「播放这首歌」，其余动作降为文字链；列表改成书页式小标题，原唱行加朱砂细签。"
    "功能与 v2.1.85 一致（严格匹配 / 其他版本 / 悬浮栏让位 / 播放缓存）。\n"
    "静态验证 46 项全过；本机无设备，未做真机冒烟。"
)

payload = {"msg_type": "text", "content": {"text": text}}
req = urllib.request.Request(
    URL, data=json.dumps(payload).encode("utf-8"),
    headers={"Content-Type": "application/json"})
with urllib.request.urlopen(req, timeout=20) as r:
    print(r.read().decode("utf-8"))
