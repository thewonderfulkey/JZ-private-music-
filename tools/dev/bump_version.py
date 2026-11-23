# -*- coding: utf-8 -*-
"""把版本号从 2.4.90 / 268 提到 2.4.91 / 269（两处：gradle 拼文件名 + pbxproj 包内）。"""
import io

g = 'android/app/build.gradle.kts'
s = io.open(g, encoding='utf-8').read()
s = s.replace('versionCode = 268', 'versionCode = 269')
s = s.replace('versionName = "2.4.90"', 'versionName = "2.4.91"')
io.open(g, 'w', encoding='utf-8', newline='').write(s)

p = 'ios/JZMusicHelper.xcodeproj/project.pbxproj'
s = io.open(p, encoding='utf-8').read()
s = s.replace('CURRENT_PROJECT_VERSION = 268;', 'CURRENT_PROJECT_VERSION = 269;')
s = s.replace('MARKETING_VERSION = 2.4.90;', 'MARKETING_VERSION = 2.4.91;')
io.open(p, 'w', encoding='utf-8', newline='').write(s)
print('bumped to 2.4.91 / 269')
