# -*- coding: utf-8 -*-
import io

B = r'C:\Users\17948\DoubaoWork\chats\2026-10-22\new-chat-1\JZMusicHelperAndroid'
edits = []

def patch(path, old, new, label):
    s = open(path, encoding='utf-8').read()
    assert old in s, "MISS " + label
    s = s.replace(old, new)
    open(path, 'w', encoding='utf-8', newline='').write(s)
    edits.append(label)

# 1) 版本号
patch(B + r'\app\build.gradle.kts', 'versionCode = 109', 'versionCode = 110', 'versionCode')
patch(B + r'\app\build.gradle.kts', 'versionName = "2.1.51"', 'versionName = "2.1.52"', 'versionName')

# 2) 窗口纸色与新画卷一致（消除冷启动到 Compose 首帧的一线色缝）
patch(B + r'\app\src\main\res\values\colors.xml', '<color name="jz_paper">#F7F5F0</color>',
      '<color name="jz_paper">#FAF5EC</color>', 'jz_paper')

# 3) 关于页文案
patch(B + r'\app\src\main\java\com\jz\musichelper\ui\SettingsScreen.kt',
      '"JZ的音乐助手 v2.1.51"', '"JZ的音乐助手 v2.1.52"', 'about_version')

old_note = ('"v2.1.51：开场动画时长对齐网易云——纯开屏固定 4s，且改为从首帧真正上屏才开始计时'
            '（上一版计时起点过早，实机只看到约 0.5s）。4s 内重排节拍：画卷极缓推近、四字题名 0.9s 起逐字上浮、'
            '副题与朱印 2.35s 落下，墨线匀速走到 96%，首页真就绪才补满并收束进首页。"')
new_note = ('"v2.1.52：开场动画按《开场动画预览-v53》整体重做（高山流水，知音难寻）——'
            '山自左以湿边前缘长出来（脊上三株墨树随山成形、各自轻摇），三羽淡墨横过雾带，飞瀑两层错速水痕向下淌、'
            '瀑底水面横纹横向游走，落水处水雾与涟漪荡开，水声化作墨音符自瀑底升起；末段墨浸透纸背、墨满收束，'
            '待首页画出首帧再墨退。总时长约 5s（4.6s 起退场），跳过按钮随时可用。"')
patch(B + r'\app\src\main\java\com\jz\musichelper\ui\SettingsScreen.kt', old_note, new_note, 'about_note')

open(r'C:\Users\17948\DoubaoWork\chats\2026-10-22\new-chat-1\_tmp_build\edit_v2152.txt', 'w',
     encoding='utf-8').write("OK\n" + "\n".join(edits))
