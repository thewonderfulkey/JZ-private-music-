# -*- coding: utf-8 -*-
"""版本号 +1（gradle 拼文件名 + pbxproj 包内版本，两处都要改）。"""
import io
import re
import sys

g = 'android/app/build.gradle.kts'
s = io.open(g, encoding='utf-8').read()
code = int(re.search(r'versionCode = (\d+)', s).group(1))
name = re.search(r'versionName = "([\d.]+)"', s).group(1)
parts = name.split('.')
parts[-1] = str(int(parts[-1]) + 1)
new = '.'.join(parts)
s = s.replace(f'versionCode = {code}', f'versionCode = {code + 1}')
s = s.replace(f'versionName = "{name}"', f'versionName = "{new}"')
io.open(g, 'w', encoding='utf-8', newline='').write(s)

p = 'ios/JZMusicHelper.xcodeproj/project.pbxproj'
t = io.open(p, encoding='utf-8').read()
t = t.replace(f'CURRENT_PROJECT_VERSION = {code};', f'CURRENT_PROJECT_VERSION = {code + 1};')
t = t.replace(f'MARKETING_VERSION = {name};', f'MARKETING_VERSION = {new};')
io.open(p, 'w', encoding='utf-8', newline='').write(t)
print(f'{name}/{code} → {new}/{code + 1}')
