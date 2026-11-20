# -*- coding: utf-8 -*-
import json
import os
import urllib.request

HOOK = os.environ.get("LARK_WEBHOOK", "")
TEXT = (
    "JZ的音乐助手 v2.1.81 已发群。\n"
    "① 修「已授权却一直识别失败/提示未授权」：根因是录音任务挂在识曲浮层里，浮层一移除就被 Compose 取消，"
    "取消异常又被当成业务失败（就是你截图里那句 The coroutine scope left the composition）；"
    "现在整段任务搬到应用级作用域，重试/返回授权/关浮层都不会再打断。另修麦克风占用需重试、8k 采样率不被接受时自动退 16k 采集降采样。\n"
    "② 首页识曲栏按你要求重做：整块不再可点，只留右端一枚圆形麦克风，左侧题字、中间淡墨声纹铺满余下空间。\n"
    "静态验证 43 项通过；真机冒烟仍缺（本机 adb 无设备）。APK 与说明、预览图已发群。"
)

payload = {"msg_type": "text", "content": {"text": TEXT}}
req = urllib.request.Request(
    HOOK,
    data=json.dumps(payload, ensure_ascii=False).encode("utf-8"),
    headers={"Content-Type": "application/json; charset=utf-8"},
)
with urllib.request.urlopen(req, timeout=20) as resp:
    print(resp.read().decode("utf-8"))
