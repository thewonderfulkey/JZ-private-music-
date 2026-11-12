# -*- coding: utf-8 -*-
"""v2.1.66：① 关于页换成精简声明；② 设置页底部预留 60dp，避免最后内容被播放悬浮栏挡住。"""
import io, re, sys

SET = r"C:\Users\17948\DoubaoWork\chats\2026-10-22\new-chat-1\JZMusicHelperAndroid\app\src\main\java\com\jz\musichelper\ui\SettingsScreen.kt"
st = io.open(SET, encoding="utf-8").read()

# ① 关于：把那一大段版本史换成「本版更新 + 三条声明」
start = st.find('"v2.1.65：①下载列表瘦身')
end = st.find('fontSize = 12.sp', start)
if start < 0 or end < 0:
    print("ERR anchor"); sys.exit(1)
# 结束位置往后挪到该 Text 调用的闭合括号
end2 = st.find(')', end) + 1
new_block = '''Text("本版更新", fontSize = 12.sp, color = p.text3)
            Spacer(Modifier.height(3.dp))
            Text(
                "下载列表只在歌名后保留档位标签（无损 / 320k / 128k），校验记录留在后台；" +
                    "换源顺序改为「能出该档的音源优先」，320k / 128k 不再空等。",
                fontSize = 12.sp,
                color = p.text2
            )
            Spacer(Modifier.height(10.dp))
            Text("声明", fontSize = 12.sp, color = p.text3)
            Spacer(Modifier.height(3.dp))
            Text(
                "1. 音乐源为酷我 / QQ / 网易等第三方接口的聚合结果，仅供个人学习与测试，请支持正版音乐。\\n" +
                    "2. 本应用不存储、不传播任何音频文件，仅提供检索、试听与本地缓存。\\n" +
                    "3. 曲库版权与接口可用性随时变化，个别歌曲缺少某档音质属正常现象。",
                fontSize = 12.sp,
                color = p.text2,
                lineHeight = 18.sp
            )'''
st = st[:start] + new_block + st[end2:]

# ② 底部预留：设置页是 verticalScroll，同其他页 LazyColumn 的 60dp 口径
st = st.replace(".padding(horizontal = 18.dp)\n    ) {",
                ".padding(start = 18.dp, end = 18.dp, bottom = 60.dp)   // v2.1.66：底部预留 60dp，末行不再被播放悬浮栏挡住\n    ) {", 1)

io.open(SET, "w", encoding="utf-8").write(st)
print("about replaced:", "本版更新" in st, "| 声明" in st)
print("bottom pad:", "bottom = 60.dp" in st)
print("old history gone:", "v2.1.64：下载链路两条补齐" not in st)
