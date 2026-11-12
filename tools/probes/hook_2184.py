# -*- coding: utf-8 -*-
import json
import urllib.request

HOOK = "https://open.feishu.cn/open-apis/bot/v2/hook/20e2cec8-2f03-4147-95bd-2731b9fe66d7"
TEXT = (
    "JZ的音乐助手 v2.1.84 已发群。四条反馈全部落地：\n"
    "① 聆听/辨认中再点一次麦克风＝取消这次识别（上一版这个分支写成了 if(!listening)，点了直接被吞、没反应）；\n"
    "② 点结果「播放」或点历史条目，先用占位曲目把播放页顶出来，再后台检索取流，不再等好几秒才滑上来；\n"
    "③ 识曲历史持久保存，退出 App 再进来还在，条数与底层栏「历史」一致（50 条），列表可滚；\n"
    "④ 右上角「听十秒」在原位置变成墨线小按钮，点开可选 5/10/15/20 秒（四档都已实测接口可识别），选择落盘。\n"
    "顺手修掉底栏选中项标签白字写白纸（你那截屏里「识曲」两个字看不见）。\n"
    "静态验证 66 项通过，唯一缺口是本机 adb 无设备、无模拟器，真机冒烟仍需装包实测。APK 与页面预览图已发群。"
)

payload = {"msg_type": "text", "content": {"text": TEXT}}
req = urllib.request.Request(
    HOOK,
    data=json.dumps(payload, ensure_ascii=False).encode("utf-8"),
    headers={"Content-Type": "application/json; charset=utf-8"},
)
with urllib.request.urlopen(req, timeout=20) as resp:
    print(resp.read().decode("utf-8"))
