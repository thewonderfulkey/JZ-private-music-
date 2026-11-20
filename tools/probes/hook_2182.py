# -*- coding: utf-8 -*-
import json
import os
import urllib.request

HOOK = os.environ.get("LARK_WEBHOOK", "")
TEXT = (
    "JZ的音乐助手 v2.1.82 已发群。\n"
    "修「另一台手机外放很大声，却一直提示没听到声音」。两处都是采集层：\n"
    "① 判据用的是给波形显示的放大值，等于要求录到满量程 1.25% 以上才算有声音，门槛过严；\n"
    "② 固定按 8k 采集 + 普通麦克风音源，部分机型这条路只回近乎空白的音频、或降噪把音乐削没。\n"
    "现在改成从设备原生采样率采（48k/32k/16k 依次探测）再平均降到 8k 送识别，音源改用识别专用档，"
    "判据换成实测 RMS，-48dB 以下才算真静音；失败提示会带本次实测分贝，便于区分“真没录到”还是“曲库没对上”。\n"
    "离线实测三种采样口径打接口均识别为晴天/周杰伦；静态验证 47 项通过，真机冒烟仍缺（adb 无设备）。APK 已发群。"
)

payload = {"msg_type": "text", "content": {"text": TEXT}}
req = urllib.request.Request(
    HOOK,
    data=json.dumps(payload, ensure_ascii=False).encode("utf-8"),
    headers={"Content-Type": "application/json; charset=utf-8"},
)
with urllib.request.urlopen(req, timeout=20) as resp:
    print(resp.read().decode("utf-8"))
