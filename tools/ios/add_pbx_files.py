"""把 Swift 文件登记进手写的 project.pbxproj（幂等，自动分配未占用 ID）。

为什么需要脚本：这个工程是手写 pbxproj（没有用 Xcode 生成），ID 必须唯一。
硬编码 ID 会撞车——历史上 `F…13` 是 Info.plist、`F…14` 是 .app，
撞了之后的报错是 "Build input file cannot be found: ios/JZMusicHelper/Xxx.swift"，很难一眼看出原因。

用法（在仓库根目录）：
    python tools/ios/add_pbx_files.py Services AudioPlayer.swift NowPlayingCenter.swift
    python tools/ios/add_pbx_files.py Views MiniPlayerBar.swift NowPlayingView.swift
也可以一次给多个分组：
    python tools/ios/add_pbx_files.py Services A.swift B.swift Views C.swift
分组名对应 pbxproj 里已有 PBXGroup 的注释名（Services / Views / Models）。
脚本对已登记的文件会跳过，可以反复执行。
"""
from __future__ import annotations

import re
import sys
from pathlib import Path

PBX = Path("ios/JZMusicHelper.xcodeproj/project.pbxproj")


def main(argv: list[str]) -> int:
    if len(argv) < 3:
        print(__doc__)
        return 2

    # 解析 "分组 文件 文件 ... 分组 文件 ..."
    groups: dict[str, list[str]] = {}
    current: str | None = None
    for token in argv[1:]:
        if token.endswith(".swift"):
            if current is None:
                print(f"❌ 文件 {token} 前面没有分组名")
                return 2
            groups.setdefault(current, []).append(token)
        else:
            current = token
            groups.setdefault(current, [])

    src = PBX.read_text(encoding="utf-8")
    existing_refs = set(re.findall(r"/\* ([A-Za-z0-9_]+\.swift) \*/ = \{isa = PBXFileReference", src))

    todo: dict[str, list[str]] = {}
    for group, files in groups.items():
        missing = [f for f in files if f not in existing_refs]
        if missing:
            todo[group] = missing
    if not todo:
        print("全部已登记，无需改动")
        return 0

    def next_id(prefix: str) -> str:
        used = {int(m, 16) for m in re.findall(rf"\b{prefix}([0-9A-F]{{23}})\b", src)}
        candidate = (max(used) + 1) if used else 1
        while f"{prefix}{candidate:023X}" in src:
            candidate += 1
        return f"{prefix}{candidate:023X}"

    build_lines = ""
    ref_lines = ""
    group_lines: dict[str, str] = {}
    phase_lines = ""

    for group, files in todo.items():
        for name in files:
            b_id, f_id = next_id("B"), next_id("F")
            build_lines += (
                f"\t\t{b_id} /* {name} in Sources */ = "
                f"{{isa = PBXBuildFile; fileRef = {f_id} /* {name} */; }};\n"
            )
            ref_lines += (
                f"\t\t{f_id} /* {name} */ = {{isa = PBXFileReference; "
                f'lastKnownFileType = sourcecode.swift; path = {name}; sourceTree = "<group>"; }};\n'
            )
            group_lines.setdefault(group, "")
            group_lines[group] += f"\t\t\t\t{f_id} /* {name} */,\n"
            phase_lines += f"\t\t\t\t{b_id} /* {name} in Sources */,\n"
            # 立刻把新 ID 写进 src 的临时视图，避免 next_id 重复分配
            src = src + f"\n/* reserved {b_id} {f_id} */"

    # 1) PBXBuildFile / PBXFileReference：插在各自 section 结束前
    for marker, lines in (
        ("/* End PBXBuildFile section */", build_lines),
        ("/* End PBXFileReference section */", ref_lines),
    ):
        assert src.count(marker) == 1, f"{marker} 出现 {src.count(marker)} 次"
        src = src.replace(marker, lines + marker)

    # 2) 分组 children：在该组 children 列表的收尾 ");" 前插入
    for group, lines in group_lines.items():
        pattern = re.compile(
            rf"(/\* {re.escape(group)} \*/ = \{{\s*\n\s*isa = PBXGroup;\s*\n\s*children = \(\n)(.*?)(\t\t\t\);)",
            re.S,
        )
        m = pattern.search(src)
        if not m:
            print(f"❌ 找不到分组 {group}")
            return 1
        src = src[: m.end(2)] + lines + src[m.end(2):]

    # 3) Sources build phase：插在 files = ( ... ) 收尾前
    pattern = re.compile(r"(PBXSourcesBuildPhase;.*?files = \(\n)(.*?)(\t\t\t\);)", re.S)
    m = pattern.search(src)
    if not m:
        print("❌ 找不到 PBXSourcesBuildPhase")
        return 1
    src = src[: m.end(2)] + phase_lines + src[m.end(2):]

    # 去掉临时占位注释
    src = re.sub(r"\n/\* reserved [BF][0-9A-F]{23} [BF][0-9A-F]{23} \*/", "", src)

    # 自检：定义行不得重复
    defs = re.findall(r"^\t\t([BF][0-9A-F]{23}) /\*", src, flags=re.M)
    dup = {i for i in defs if defs.count(i) > 1}
    if dup:
        print(f"❌ ID 重复：{dup}")
        return 1

    PBX.write_text(src, encoding="utf-8")
    for group, files in todo.items():
        print(f"✓ {group}: {', '.join(files)}")
    print(f"定义行 {len(defs)}，无重复")
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))
