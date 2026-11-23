# -*- coding: utf-8 -*-
"""把一个新 .swift 文件登记进手写的 pbxproj（PBXBuildFile + PBXFileReference + group + Sources）。"""
import io
import re
import sys

NAME = sys.argv[1] if len(sys.argv) > 1 else 'DurationTruth.swift'
GROUP_HINT = sys.argv[2] if len(sys.argv) > 2 else 'StorageAudit.swift'

path = 'ios/JZMusicHelper.xcodeproj/project.pbxproj'
s = io.open(path, encoding='utf-8').read()

if NAME in s:
    print(f'{NAME} 已经在工程里了，跳过')
    sys.exit(0)

fids = sorted(set(re.findall(r'\bF[0-9A-F]{23}\b', s)))
bids = sorted(set(re.findall(r'\bB[0-9A-F]{23}\b', s)))
new_f = 'F%023X' % (int(fids[-1][1:], 16) + 1)
new_b = 'B%023X' % (int(bids[-1][1:], 16) + 1)

# 1) PBXBuildFile
anchor = re.search(r'\t\t' + bids[-1] + r' /\*.*?\*/ = \{isa = PBXBuildFile;[^\n]*\n', s)
build_line = (f'\t\t{new_b} /* {NAME} in Sources */ = {{isa = PBXBuildFile; '
              f'fileRef = {new_f} /* {NAME} */; }};\n')
s = s[:anchor.end()] + build_line + s[anchor.end():]

# 2) PBXFileReference
anchor = re.search(r'\t\t' + fids[-1] + r' /\*.*?\*/ = \{isa = PBXFileReference;[^\n]*\n', s)
ref_line = (f'\t\t{new_f} /* {NAME} */ = {{isa = PBXFileReference; lastKnownFileType = '
            f'sourcecode.swift; path = {NAME}; sourceTree = "<group>"; }};\n')
s = s[:anchor.end()] + ref_line + s[anchor.end():]

# 3) 分组：挂在同名邻居（GROUP_HINT）那一行后面
m = re.search(r'(\t+)[FB][0-9A-F]{23} /\* ' + re.escape(GROUP_HINT) + r' \*/,\n', s)
assert m, '找不到邻居文件所在的 group'
s = s[:m.end()] + f'{m.group(1)}{new_f} /* {NAME} */,\n' + s[m.end():]

# 4) Sources 阶段
m = re.search(r'(\t+)[FB][0-9A-F]{23} /\* ' + re.escape(GROUP_HINT) + r' in Sources \*/,\n', s)
assert m, '找不到 Sources 里的邻居'
s = s[:m.end()] + f'{m.group(1)}{new_b} /* {NAME} in Sources */,\n' + s[m.end():]

io.open(path, 'w', encoding='utf-8', newline='').write(s)
print(f'{NAME} 已登记：fileRef={new_f} buildFile={new_b}')
