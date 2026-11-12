# -*- coding: utf-8 -*-
import io, os, re, sys

ROOT = r"C:\Users\17948\DoubaoWork\chats\2026-10-22\new-chat-1\JZMusicHelperAndroid"
GRADLE = os.path.join(ROOT, r"app\build.gradle.kts")
SETTINGS = os.path.join(ROOT, r"app\src\main\java\com\jz\musichelper\ui\SettingsScreen.kt")

NEW = (
    "v2.1.65：①下载列表瘦身——每首歌下面那两行校验文字（所选/实得、体积复核说明）全部撤掉，"
    "这些留成后端记录（DownloadItem.note 只落库不显示），行内只在歌名后面保留一个档位标签（无损/320k/128k）；"
    "②修掉「大部分歌 320k/128k 反而找不到」的编排缺陷：跨源候选原先是「同平台优先」，"
    "而 QQ 与酷我的取流后端给不出 320k/128k，这些候选排在队首只会白耗单条 12s 的超时，"
    "把整轮 40s 预算吃光，真正能出 320k 的网易候选根本轮不到——现在改为「能出目标档的平台优先（网易前置）」，"
    "无损档仍按同平台优先；③妖狐那条恒给无损的通用兜底，在 320k/128k 且已有其它音源时不再空等 12s。"
)

txt = io.open(GRADLE, encoding="utf-8").read()
txt2 = re.sub(r"versionCode\s*=\s*122", "versionCode = 123", txt, count=1)
txt2 = txt2.replace('versionName = "2.1.64"', 'versionName = "2.1.65"', 1)
io.open(GRADLE, "w", encoding="utf-8").write(txt2)
print("gradle:", re.search(r"versionCode\s*=\s*\d+", txt2).group(0),
      re.search(r'versionName\s*=\s*"[^"]+"', txt2).group(0))

st = io.open(SETTINGS, encoding="utf-8").read()
st2 = st.replace('Text("JZ的音乐助手 v2.1.64"', 'Text("JZ的音乐助手 v2.1.65"', 1)
idx = st2.find('"v2.1.64：')
if idx < 0:
    print("ERROR: anchor not found"); sys.exit(1)
st2 = st2[:idx] + '"' + NEW + st2[idx + 1:]
io.open(SETTINGS, "w", encoding="utf-8").write(st2)
print("settings head:", st2[st2.find("JZ的音乐助手"):st2.find("JZ的音乐助手") + 40])
print("new para inserted:", "v2.1.65：" in st2 and NEW[:20] in st2)
