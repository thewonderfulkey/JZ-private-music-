# -*- coding: utf-8 -*-
import json
import urllib.request

HOOK = "https://open.feishu.cn/open-apis/bot/v2/hook/20e2cec8-2f03-4147-95bd-2731b9fe66d7"
TEXT = (
    "JZ的音乐助手 v2.1.83 已发群。两条反馈都落地：\n"
    "① 识别结果点「播放」直接起播：不再把「歌名 歌手」丢进首页搜索框，改为后台按歌名+歌手检索，"
    "按录音室原唱得分挑一条，直接开始播放并进播放页，队列取同曲候选前六条。\n"
    "② 识曲从首页搬到底层栏第 2 格独立成页：六格（首页/识曲/收藏/下载/历史/设置），"
    "整页只有一枚圆形麦克风可点，外围墨圈随响度呼吸，下方是结果纸签与「最近识过」；"
    "首页恢复原样（入口条已撤），进页不自动录音，离开页面自动收掉采集。\n"
    "静态验证 49 项通过，唯一缺口是本机 adb 无设备、无模拟器，真机冒烟仍需装包实测。APK 与页面预览图已发群。"
)

payload = {"msg_type": "text", "content": {"text": TEXT}}
req = urllib.request.Request(
    HOOK,
    data=json.dumps(payload, ensure_ascii=False).encode("utf-8"),
    headers={"Content-Type": "application/json; charset=utf-8"},
)
with urllib.request.urlopen(req, timeout=20) as resp:
    print(resp.read().decode("utf-8"))
