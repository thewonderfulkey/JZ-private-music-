"""从手写 project.pbxproj 里移除一个 Swift 文件的全部登记（幂等）。

删文件比加文件麻烦：pbxproj 里有 4 处引用——PBXBuildFile、PBXFileReference、
所属 group 的 children、以及 target 的 PBXSourcesBuildPhase。任何一处漏掉，
要么编译报 "Build input file cannot be found"，要么留下悬空引用（check_pbxproj 会报）。

用法（仓库根目录）：
    python tools/ios/remove_pbx_file.py Views HotChartView.swift
"""
from __future__ import annotations

import re
import sys
from pathlib import Path

PBX = Path("ios/JZMusicHelper.xcodeproj/project.pbxproj")


def main(argv: list[str]) -> int:
    if len(argv) != 3:
        print(__doc__)
        return 2
    name = argv[2]
    text = PBX.read_text(encoding="utf-8")

    # 找这个文件对应的 fileRef id（PBXFileReference 那一行的 id）
    ref = re.search(r"([0-9A-F]{24}) /\* " + re.escape(name) + r" \*/ = \{isa = PBXFileReference", text)
    if not ref:
        print(f"未登记（或已移除）：{name}")
        return 0
    ref_id = ref.group(1)

    lines = text.splitlines(keepends=True)
    kept: list[str] = []
    removed = 0
    for line in lines:
        # 1) PBXFileReference 本身  2) PBXBuildFile（fileRef 指向它）
        # 3) group children 那一行   4) Sources build phase 那一行（注释里带文件名 + in Sources）
        if (
            f"{ref_id} /* {name} */ = {{isa = PBXFileReference" in line
            or (f"fileRef = {ref_id}" in line and "isa = PBXBuildFile" in line)
            or re.match(r"\s*" + ref_id + r" /\* " + re.escape(name) + r" \*/,\s*$", line)
            or (f"/* {name} in Sources */," in line)
        ):
            removed += 1
            continue
        kept.append(line)

    PBX.write_text("".join(kept), encoding="utf-8")
    print(f"已移除 {name}（{removed} 处引用，fileRef={ref_id}）")
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))
