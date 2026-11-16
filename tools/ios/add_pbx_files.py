"""给手写 pbxproj 加 4 个 Swift 文件（按已占用 ID 动态分配，避免与 Info.plist / app 的 F13/F14 撞车）。

用法：先 `git checkout -- ios/JZMusicHelper.xcodeproj/project.pbxproj`，再跑本脚本。
"""
import re
import sys
from pathlib import Path

PBX = Path("ios/JZMusicHelper.xcodeproj/project.pbxproj")
NEW_FILES = ["SearchRanker.swift", "NameMatch.swift", "StudioPick.swift", "KuwoParser.swift"]

src = PBX.read_text(encoding="utf-8")

# 1) 收集已用 ID，按前缀取最大序号
ids = set(re.findall(r"\b([BFG][0-9A-F]{23})\b", src))


def next_ids(prefix: str, count: int) -> list[str]:
    used = sorted(int(i[1:], 16) for i in ids if i.startswith(prefix))
    start = (max(used) + 1) if used else 1
    out = []
    for k in range(count):
        cand = f"{prefix}{start + k:023X}"
        assert len(cand) == 24, cand
        assert cand not in ids, f"ID 冲突 {cand}"
        out.append(cand)
    return out


b_ids = next_ids("B", len(NEW_FILES))
f_ids = next_ids("F", len(NEW_FILES))
print("build ids:", b_ids)
print("file  ids:", f_ids)

# 2) PBXBuildFile
build_lines = "".join(
    f"\t\t{b} /* {n} in Sources */ = {{isa = PBXBuildFile; fileRef = {f} /* {n} */; }};\n"
    for b, f, n in zip(b_ids, f_ids, NEW_FILES)
)
marker = "/* End PBXBuildFile section */"
assert src.count(marker) == 1
src = src.replace(marker, build_lines + marker)

# 3) PBXFileReference
ref_lines = "".join(
    f"\t\t{f} /* {n} */ = {{isa = PBXFileReference; lastKnownFileType = sourcecode.swift; "
    f'path = {n}; sourceTree = "<group>"; }};\n'
    for f, n in zip(f_ids, NEW_FILES)
)
marker = "/* End PBXFileReference section */"
assert src.count(marker) == 1
src = src.replace(marker, ref_lines + marker)

# 4) Services group children（锚点：HistoryStore.swift 那行）
anchor = "\t\t\t\tF0000000000000000000000B /* HistoryStore.swift */,\n"
assert src.count(anchor) == 1, src.count(anchor)
group_lines = "".join(f"\t\t\t\t{f} /* {n} */,\n" for f, n in zip(f_ids, NEW_FILES))
src = src.replace(anchor, anchor + group_lines)

# 5) Sources build phase（锚点：SettingsView.swift in Sources 那行）
anchor = "\t\t\t\tB00000000000000000000011 /* SettingsView.swift in Sources */,\n"
assert src.count(anchor) == 1, src.count(anchor)
phase_lines = "".join(f"\t\t\t\t{b} /* {n} in Sources */,\n" for b, n in zip(b_ids, NEW_FILES))
src = src.replace(anchor, anchor + phase_lines)

# 6) 自检：ID 不得重复
all_ids = re.findall(r"\b([BFG][0-9A-F]{23})\b", src)
dups = {i for i in all_ids if all_ids.count(i) > 1}
defined = set(re.findall(r"\b([BF][0-9A-F]{23}) /\*", src))
# 只检查"定义行"重复（引用行会自然重复出现）
defs = re.findall(r"^\t\t([BF][0-9A-F]{23}) /\*", src, flags=re.M)
dupdefs = {i for i in defs if defs.count(i) > 1}
print("定义行数:", len(defs), "重复定义:", dupdefs or "无")

PBX.write_text(src, encoding="utf-8")
print("写入完成")
if dupdefs:
    sys.exit(1)
