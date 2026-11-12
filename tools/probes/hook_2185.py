# -*- coding: utf-8 -*-
import json
import urllib.request

HOOK = "https://open.feishu.cn/open-apis/bot/v2/hook/20e2cec8-2f03-4147-95bd-2731b9fe66d7"
TEXT = (
    "JZ的音乐助手 v2.1.85 已发群。三条反馈全部落地：\n"
    "① 识别对但播放的不是同一首：录屏第 4 秒就是铁证（认出 IVORY TOWER / 澤野弘之，起播的却是 Blackmore 的同名曲）。"
    "根因是上一版把匹配放宽到「歌名对就行」。现在收窄成「歌名 + 歌手任一位命中」才起播；曲库里没有这位歌手的可播条目时不再硬播，"
    "结果卡直接写明并列出可选的版本；\n"
    "② 结果卡新增「其他版本」按钮：按歌名跨平台重搜同名版本，同一位歌手只留一条（最多 12 条），"
    "原唱（＝识别到的这位歌手）置顶并盖一枚朱砂「原唱」印，点任意一条即播、队列就是这份列表；\n"
    "③ 播放悬浮栏压住「最近识过」最后一条：内容区底部补了 84dp 让位（播放条高 ≈72dp），滚到底最后一条整条都在播放条上方，结果卡同样让位并可滚；\n"
    "④ 播放缓存：取流器拿到歌就整首缓存到本地，缓存进度直接画在播放进度条上（进度线底下的淡墨带）；"
    "整首落盘后自动切到本地文件并从当前位置续播，拖动进度条不再重新搜歌取流；只缓存当前一首，切歌/播完即删，启动时清残留，不占内存。\n"
    "静态验证 30 项全通过（vc143 / 2.1.85 / 包名 / debug 签名 / zip 完整性 / 新文案与类已进 dex / 设置-关于已同步）。"
    "缺口同往常：本机 adb 恒空、无模拟器，真机冒烟未做。APK 与页面预览图已发群。"
)

payload = {"msg_type": "text", "content": {"text": TEXT}}
req = urllib.request.Request(
    HOOK,
    data=json.dumps(payload, ensure_ascii=False).encode("utf-8"),
    headers={"Content-Type": "application/json; charset=utf-8"},
)
with urllib.request.urlopen(req, timeout=20) as resp:
    print(resp.read().decode("utf-8"))
